import XCTest
import SwiftData
import AppKit
@testable import Daftar

@MainActor
final class FeatureTests: XCTestCase {
    private func context() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        return context
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() -> UserDefaults {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    @discardableResult
    private func seed(_ context: ModelContext, title: String = "Initial") throws -> Page {
        let notebook = Notebook(name: "Notes"); context.insert(notebook)
        let section = NoteSection(name: "Section"); context.insert(section); section.notebook = notebook
        let page = Page(title: title); context.insert(page); page.section = section
        page.contentData = try NSAttributedString(string: "Original").data(from: NSRange(location: 0, length: 8), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        page.plainText = "Original"
        try context.save()
        return page
    }
    private func notes(_ context: ModelContext) throws -> [Notebook] { try context.fetch(FetchDescriptor<Notebook>()) }
    private func pages(_ context: ModelContext) throws -> [Page] { try context.fetch(FetchDescriptor<Page>()) }

    func testHistoryRestoresContentAndKeepsTheVersionItReplaced() throws {
        let context = try context(), page = try seed(context)
        page.customTags = ["Planning"]
        try PageHistory.capture(page, force: true)
        let original = try XCTUnwrap(PageHistory.revisions(page).first)
        page.title = "Changed"; page.customTags = ["Other"]; page.kind = .spreadsheet
        page.spreadsheetData = try JSONEncoder().encode(SpreadsheetData.empty)
        try context.save()
        try PageHistory.restore(original, to: page, context: context)
        XCTAssertEqual(page.title, "Initial")
        XCTAssertEqual(page.customTags, ["Planning"])
        XCTAssertEqual(page.kind, .richText)
        XCTAssertEqual(try PageContentCodec.richText(page.contentData).string, "Original")
        XCTAssertTrue(try PageHistory.revisions(page).contains { $0.title == "Changed" && $0.kind == PageKind.spreadsheet.rawValue })
    }

    func testHistoryCoalescesEditsAndRetainsFiftyVersions() throws {
        let context = try context(), page = try seed(context)
        let now = Date()
        try PageHistory.capture(page, now: now)
        page.title = "Second"
        try PageHistory.capture(page, now: now.addingTimeInterval(5))
        XCTAssertEqual(try PageHistory.revisions(page).count, 1)
        for index in 0..<70 { page.title = "Version \(index)"; try PageHistory.capture(page, force: true) }
        XCTAssertEqual(try PageHistory.revisions(page).count, 50)
        XCTAssertEqual(try PageHistory.revisions(page).first?.title, "Version 69")
    }

    func testCorruptHistoryIsSetAsideWithoutOverwritingItsBytes() throws {
        let context = try context(), page = try seed(context)
        page.historyData = Data("damaged".utf8)
        XCTAssertThrowsError(try PageHistory.revisions(page), "still reported as unreadable")
        XCTAssertNoThrow(try PageHistory.capture(page, force: true), "but never blocks an edit")
        XCTAssertEqual(page.payload?.damagedHistory, [Data("damaged".utf8)])
        XCTAssertEqual(try PageHistory.revisions(page).count, 1)
    }

    func testCompleteBackupPreservesTrashHistoryIDsAndAttachments() throws {
        let source = try context(), page = try seed(source)
        page.customTags = ["Tax", "2026"]; page.paperSize = "a4"
        let wrapper = FileWrapper(regularFileWithContents: Data("receipt".utf8)); wrapper.preferredFilename = "receipt.txt"
        let text = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        page.contentData = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try PageHistory.capture(page, force: true)
        page.deletedAt = Date()
        let notebookID = try XCTUnwrap(page.section?.notebook?.stableID)
        let backup = try LibraryBackup.capture(context: source, locks: SectionLockStore(), defaults: defaults())
        let url = try folder().appendingPathComponent("all.daftarbackup")
        try backup.write(to: url)
        let target = try context()
        _ = try LibraryBackup.read(from: url).restore(context: target, defaults: defaults())
        let restored = try XCTUnwrap(pages(target).first)
        XCTAssertEqual(restored.linkID, page.linkID)
        XCTAssertEqual(restored.section?.notebook?.stableID, notebookID)
        XCTAssertEqual(restored.deletedAt, page.deletedAt)
        XCTAssertEqual(restored.contentData, page.contentData)
        XCTAssertNotNil(page.historyData)
        XCTAssertNil(restored.historyData, "backups don't include page history")
        XCTAssertEqual(restored.customTags, page.customTags)
        XCTAssertEqual(restored.paperSize, "a4")
    }

    func testBackupRestoreIntoExistingLibraryRemapsCrossNotebookLinks() throws {
        let source = try context(), first = try seed(source), second = try seed(source, title: "Target")
        let text = NSAttributedString(string: "target", attributes: [.link: "daftar://page/\(second.linkID.uuidString)"])
        first.contentData = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let backup = try LibraryBackup.capture(context: source, locks: SectionLockStore(), defaults: defaults())
        _ = try backup.restore(context: source, defaults: defaults())
        let all = try pages(source)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.linkID)).count, 4)
        let importedFirst = try XCTUnwrap(all.first { $0.title == "Initial" && $0.linkID != first.linkID })
        let importedSecond = try XCTUnwrap(all.first { $0.title == "Target" && $0.linkID != second.linkID })
        XCTAssertEqual(importedFirst.outgoingLinkIDs, [importedSecond.linkID])
    }

    func testUnsupportedBackupDoesNotChangeLibrary() throws {
        let context = try context(); try seed(context)
        var backup = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: defaults()); backup.formatVersion = 999
        XCTAssertThrowsError(try backup.restore(context: context, defaults: defaults()))
        XCTAssertEqual(try notes(context).count, 1)
    }

    func testSessionAndSavedSearchPersistence() throws {
        let defaults = defaults(), id = UUID(), pageID = UUID()
        let session = WindowSession(tabs: [id], section: id, page: pageID)
        SessionStore.save(session, id: "window1", defaults: defaults)
        XCTAssertEqual(SessionStore.load("window1", defaults: defaults), session)
        XCTAssertNil(SessionStore.load("window2", defaults: defaults))
        SessionStore.saveCursor(42, id: pageID, defaults: defaults)
        XCTAssertEqual(SessionStore.cursor(pageID, defaults: defaults), 42)
        let searches = [SavedSearch(name: "Tasks", query: "invoice", notebookID: id, tagRaw: 2, customTag: "Tax")]
        try SavedSearchStore.save(searches, defaults: defaults)
        XCTAssertEqual(SavedSearchStore.load(defaults: defaults), searches)
    }

    func testCSVRoundTripPreservesQuotesCommasNewlinesAndFormulas() throws {
        let rows = [["Name", "Details", "Value"], ["A, B", "He said \"Hi\"\nNext line", "=SUM(A1:A4)"], ["", "", ""]]
        let csv = SpreadsheetEditing.delimited(rows)
        XCTAssertEqual(try SpreadsheetEditing.parseDelimited(csv), rows)
        let sheet = try SpreadsheetEditing.importCSV(csv)
        XCTAssertEqual(sheet.cells["B2"], rows[1][1])
        XCTAssertEqual(sheet.cells["C2"], "=SUM(A1:A4)")
        XCTAssertEqual(try SpreadsheetEditing.parseDelimited(SpreadsheetEditing.exportCSV(sheet)), rows)
    }

    func testMalformedCSVAndOversizedPasteAreAtomic() throws {
        XCTAssertThrowsError(try SpreadsheetEditing.importCSV("\"unfinished"))
        var sheet = SpreadsheetData.empty
        let before = sheet
        XCTAssertThrowsError(try SpreadsheetEditing.paste([["a", "b"]], into: &sheet, at: "Z200"))
        XCTAssertEqual(sheet, before)
    }

    func testRangeCopyPasteAndRowDeletionUpdateReferences() throws {
        var sheet = SpreadsheetData(rows: 4, columns: 3, cells: ["A1": "10", "A2": "20", "A3": "30", "B4": "=A3+A1", "C4": "=A2"])
        let copied = SpreadsheetEditing.copy(sheet, range: try CellRange("A1:A3"))
        XCTAssertEqual(copied, [["10"], ["20"], ["30"]])
        try SpreadsheetEditing.paste([["new"]], into: &sheet, at: "C1")
        let result = try SpreadsheetEditing.deleteRows(1...1, from: sheet)
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.cells["A2"], "30")
        XCTAssertEqual(result.cells["B3"], "=A2+A1")
        XCTAssertEqual(result.cells["C3"], "=#REF!")
    }

    func testAggregateFormulasIgnoreBlankAndTextCellsInRanges() {
        let data = SpreadsheetData(rows: 8, columns: 5, cells: ["A1": "10", "A2": "20", "A3": "text",
            "B1": "=SUM(A1:A4)", "B2": "=AVERAGE(A1:A4)", "B3": "=MAX(A1:A4)",
            "B4": "=MIN(A1:A4)", "B5": "=COUNT(A1:A4)", "B6": "=SUM(A1:A2,5)*2", "B7": "=SUM(B7:B8)"])
        let values = FormulaEngine.evaluateAll(data)
        XCTAssertEqual(values["B1"], "30"); XCTAssertEqual(values["B2"], "15")
        XCTAssertEqual(values["B3"], "20"); XCTAssertEqual(values["B4"], "10")
        XCTAssertEqual(values["B5"], "2"); XCTAssertEqual(values["B6"], "70")
        XCTAssertEqual(values["B7"], "#REF!")
    }

    func testDuplicateMigrationIDsAreNormalized() throws {
        let context = try context(); try seed(context); try seed(context)
        let notebooks = try notes(context), sections = try context.fetch(FetchDescriptor<NoteSection>())
        notebooks[1].stableID = notebooks[0].stableID; sections[1].stableID = sections[0].stableID
        try LibraryIdentity.normalize(context: context)
        XCTAssertEqual(Set(notebooks.map(\.stableID)).count, 2)
        XCTAssertEqual(Set(sections.map(\.stableID)).count, 2)
    }

    func testSyncVectorConflictResolutionIsDeterministicAndPreservesBothVersions() throws {
        let context = try context(), page = try seed(context)
        let original = NotebookArchive(try XCTUnwrap(page.section?.notebook), includeTrash: true)
        var changed = original; changed.name = "Offline edit"
        let a = UUID().uuidString, b = UUID().uuidString
        let first = SyncRecord(clock: [a: 1], notebook: original), second = SyncRecord(clock: [b: 1], notebook: changed)
        let forward = try SyncRecord.merge(first, second), reverse = try SyncRecord.merge(second, first)
        XCTAssertEqual(forward.record, reverse.record)
        XCTAssertEqual(forward.conflict, reverse.conflict)
        XCTAssertNotNil(forward.conflict)
        XCTAssertNotEqual(forward.conflict?.stableID, original.stableID)
        XCTAssertTrue(forward.record.dominates(first)); XCTAssertTrue(forward.record.dominates(second))
        XCTAssertNil(try SyncRecord.merge(forward.record, first).conflict)
    }

    func testTwoDevicesSyncUpdatesOfflineConflictsAndDeletionWithoutDuplicates() async throws {
        let shared = try folder(), aContext = try context(), bContext = try context()
        try seed(aContext)
        let a = FolderSync(defaults: defaults(), localDirectory: try folder())
        let b = FolderSync(defaults: defaults(), localDirectory: try folder())
        let locks = SectionLockStore()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertEqual(try pages(bContext).map(\.title), ["Initial"])
        XCTAssertEqual(try pages(aContext).first?.linkID, try pages(bContext).first?.linkID)
        try XCTUnwrap(pages(aContext).first).title = "A offline"
        try XCTUnwrap(pages(bContext).first).title = "B offline"
        try aContext.save(); try bContext.save()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertEqual(try Set(pages(aContext).map(\.title)), ["A offline", "B offline"])
        XCTAssertEqual(try Set(pages(bContext).map(\.title)), ["A offline", "B offline"])
        XCTAssertEqual(try notes(aContext).count, 2)
        XCTAssertEqual(try notes(bContext).count, 2)
        // Repeated no-op sync must converge instead of manufacturing edits.
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertEqual(try notes(aContext).count, 2)
        let deletedID = try XCTUnwrap(notes(aContext).first).stableID
        aContext.delete(try XCTUnwrap(notes(aContext).first { $0.stableID == deletedID }))
        try aContext.save()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertFalse(try notes(bContext).contains { $0.stableID == deletedID })
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: b.recoveryDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(recoveryFiles.contains { $0.pathExtension == "daftarbackup" })
    }

    func testLockedLibraryCannotBePublishedToSyncFolder() async throws {
        let context = try context(), page = try seed(context), shared = try folder()
        page.section?.isLocked = true
        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        do {
            try await sync.synchronize(folder: shared, context: context, locks: SectionLockStore())
            XCTFail("Locked content must not be published")
        } catch { XCTAssertTrue(error is LibraryBackup.BackupError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
    }
    func testOneSyncAuthorizationPerLaunchSyncsLockedSectionsWithoutUnlockingThem() async throws {
        let context = try context(), page = try seed(context), shared = try folder()
        let section = try XCTUnwrap(page.section)
        section.isLocked = true
        var prompts = 0
        let locks = SectionLockStore { _, completion in prompts += 1; completion(true) }
        var results: [Bool] = []
        locks.authorizeSync(for: [section]) { results.append($0) }
        locks.authorizeSync(for: [section]) { results.append($0) }
        XCTAssertEqual(prompts, 1, "asked once per launch")
        XCTAssertEqual(results, [true, true])

        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await sync.synchronize(folder: shared, context: context, locks: locks)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
        XCTAssertFalse(locks.isUnlocked(section), "the section stays locked on screen")
        XCTAssertThrowsError(try LibraryBackup.capture(context: context, locks: locks, defaults: defaults()),
                             "the sync permission doesn't extend to backups")
    }

    func testDeclinedOrUnneededSyncAuthorization() {
        let locked = NoteSection(name: "Private"); locked.isLocked = true
        let open = NoteSection(name: "Open")
        var prompts = 0
        let locks = SectionLockStore { _, completion in prompts += 1; completion(false) }
        var allowed: Bool?
        locks.authorizeSync(for: [open]) { allowed = $0 }
        XCTAssertEqual(allowed, true); XCTAssertEqual(prompts, 0, "nothing locked: no prompt")
        locks.authorizeSync(for: [locked]) { allowed = $0 }
        XCTAssertEqual(allowed, false); XCTAssertFalse(locks.isSyncAuthorized)
        XCTAssertFalse(locks.canCapture([locked], forSync: true))
    }

    func testMissingSyncCheckpointPreservesUntrackedLocalEdits() async throws {
        let shared = try folder(), context = try context()
        let page = try seed(context)
        let preferences = defaults()
        let first = FolderSync(defaults: preferences, localDirectory: try folder())
        try await first.synchronize(folder: shared, context: context, locks: SectionLockStore())
        page.title = "Offline change without checkpoint"
        try context.save()
        let restarted = FolderSync(defaults: preferences, localDirectory: try folder())
        try await restarted.synchronize(folder: shared, context: context, locks: SectionLockStore())
        XCTAssertTrue(try pages(context).contains { $0.title == "Offline change without checkpoint" })
        XCTAssertTrue(try pages(context).contains { $0.title == "Initial" })
    }

    func testDamagedRemoteSyncFileDoesNotModifyLocalLibrary() async throws {
        let shared = try folder(), context = try context()
        try seed(context)
        let directory = shared.appendingPathComponent("Daftar Sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("remote.daftarsync"))
        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        do {
            try await sync.synchronize(folder: shared, context: context, locks: SectionLockStore())
            XCTFail("Invalid remote data must stop the merge")
        } catch { }
        XCTAssertEqual(try pages(context).map(\.title), ["Initial"])
    }


    func testUnchangedLibraryIsNotRepublishedToSyncFolder() async throws {
        let shared = try folder(), context = try context()
        let page = try seed(context)
        let locks = SectionLockStore()
        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        sync.attach(context: context, locks: locks)
        try await sync.synchronize(folder: shared, context: context, locks: locks)
        let files = try FileManager.default.contentsOfDirectory(at: shared.appendingPathComponent("Daftar Sync"), includingPropertiesForKeys: nil)
        let published = try XCTUnwrap(files.first { $0.pathExtension == "daftarsync" })
        func stamp() throws -> Date? { try published.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let first = try stamp()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await sync.synchronize(folder: shared, context: context, locks: locks)
        try await sync.synchronize(folder: shared, context: context, locks: locks, onlyIfChanged: true)
        XCTAssertEqual(try stamp(), first, "an unchanged library must not be uploaded again")
        page.title = "Edited"
        try context.save()
        try await sync.synchronize(folder: shared, context: context, locks: locks, onlyIfChanged: true)
        XCTAssertNotEqual(try stamp(), first, "a saved edit must be published by the periodic sync")
    }

    func testBackupLoadsAsynchronouslyAndRestores() async throws {
        let source = try context(), page = try seed(source)
        let url = try folder().appendingPathComponent("all.daftarbackup")
        try LibraryBackup.capture(context: source, locks: SectionLockStore(), defaults: defaults()).write(to: url)
        let target = try context()
        _ = try await LibraryBackup.load(from: url).restore(context: target, defaults: defaults())
        XCTAssertEqual(try pages(target).map(\.linkID), [page.linkID])
    }

    // MARK: Blob-based sync

    private func largeRTFD(_ text: String) throws -> Data {
        let body = String(repeating: text + " ", count: 2000)
        return try NSAttributedString(string: body).data(from: NSRange(location: 0, length: (body as NSString).length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }
    private func blobFiles(_ shared: URL) -> [String: Date] {
        SyncBlobs.inventory(in: shared.appendingPathComponent("Daftar Sync/blobs"))
    }
    private func manifestSize(_ shared: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: shared.appendingPathComponent("Daftar Sync"), includingPropertiesForKeys: [.fileSizeKey])
        return try files.filter { $0.pathExtension == "daftarsync" }.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }.reduce(0, +)
    }

    func testBlobRoundTripPreservesContentAndHistory() throws {
        let context = try context(), page = try seed(context)
        page.contentData = try largeRTFD("first")
        try PageHistory.capture(page, force: true)
        page.contentData = try largeRTFD("second")
        try PageHistory.capture(page, force: true)
        page.contentData = try largeRTFD("third")
        let archive = NotebookArchive(try XCTUnwrap(notes(context).first), includeTrash: true)
        var store: [String: Data] = [:]
        let slim = SyncBlobs.dehydrate(archive, store: &store)
        XCTAssertTrue(slim.hasBlobReferences)
        XCTAssertEqual(store.count, 3, "content plus two distinct revisions")
        XCTAssertEqual(SyncBlobs.dehydrate(archive, store: &store), slim, "dehydration must be deterministic")
        XCTAssertThrowsError(try slim.restore(context: try self.context()), "a manifest can't be restored without its payloads")
        let full = try SyncBlobs.hydrate(slim, blob: { try XCTUnwrap(store[$0]) })
        XCTAssertFalse(full.hasBlobReferences)
        let original = archive.sections[0].pages[0], restored = full.sections[0].pages[0]
        XCTAssertEqual(restored.contentData, original.contentData)
        XCTAssertEqual(try JSONDecoder().decode([PageRevision].self, from: XCTUnwrap(restored.historyData)),
                       try JSONDecoder().decode([PageRevision].self, from: XCTUnwrap(original.historyData)))
    }

    func testSyncUploadsOnlyChangedPayloadsAndKeepsManifestSmall() async throws {
        let shared = try folder(), aContext = try context(), bContext = try context()
        let page = try seed(aContext)
        page.contentData = try largeRTFD("hello"); page.plainText = "hello"
        try aContext.save()
        let locks = SectionLockStore()
        let a = FolderSync(defaults: defaults(), localDirectory: try folder())
        let b = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        let firstBlobs = blobFiles(shared)
        XCTAssertEqual(firstBlobs.count, 1)
        XCTAssertLessThan(try manifestSize(shared), 4096, "page content must not be inlined in the manifest")
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertEqual(try pages(bContext).first?.contentData, page.contentData)

        let edited = try XCTUnwrap(pages(bContext).first)
        edited.contentData = try largeRTFD("changed on B")
        try bContext.save()
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        let secondBlobs = blobFiles(shared)
        XCTAssertEqual(secondBlobs.count, 2, "one new payload for the edited page")
        XCTAssertEqual(secondBlobs[firstBlobs.keys.first!], firstBlobs.values.first!, "unchanged payloads are not rewritten")
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        XCTAssertEqual(try pages(aContext).first?.contentData, edited.contentData)
    }

    func testMissingPayloadLeavesLibraryUntouchedUntilItArrives() async throws {
        let shared = try folder(), aContext = try context(), bContext = try context()
        let page = try seed(aContext)
        page.contentData = try largeRTFD("pending download")
        try aContext.save()
        let locks = SectionLockStore()
        let a = FolderSync(defaults: defaults(), localDirectory: try folder())
        let b = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        let blobs = shared.appendingPathComponent("Daftar Sync/blobs")
        let parked = try folder().appendingPathComponent("blobs")
        try FileManager.default.moveItem(at: blobs, to: parked)
        do {
            try await b.synchronize(folder: shared, context: bContext, locks: locks)
            XCTFail("sync must wait for missing payloads")
        } catch { XCTAssertTrue(error is SyncBlobs.BlobError) }
        XCTAssertTrue(try notes(bContext).isEmpty)
        try FileManager.default.moveItem(at: parked, to: blobs)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        XCTAssertEqual(try pages(bContext).first?.contentData, page.contentData)
    }

    func testVersionOneSyncFileWithInlineContentIsStillRead() async throws {
        let shared = try folder(), source = try context(), target = try context()
        let page = try seed(source)
        page.contentData = try largeRTFD("legacy")
        try source.save()
        let notebook = NotebookArchive(try XCTUnwrap(notes(source).first), includeTrash: true)
        let device = UUID().uuidString
        var legacy = SyncEnvelope(deviceID: device)
        legacy.formatVersion = 1
        legacy.records[notebook.stableID!.uuidString] = SyncRecord(clock: [device: 1], notebook: notebook)
        let directory = shared.appendingPathComponent("Daftar Sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent(device + ".daftarsync"))
        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await sync.synchronize(folder: shared, context: target, locks: SectionLockStore())
        XCTAssertEqual(try pages(target).first?.contentData, page.contentData)
        XCTAssertEqual(blobFiles(shared).count, 1, "this device republishes the payload as a blob")
    }

    func testOfflineConflictWithLargeContentKeepsBothVersions() async throws {
        let shared = try folder(), aContext = try context(), bContext = try context()
        try seed(aContext)
        let locks = SectionLockStore()
        let a = FolderSync(defaults: defaults(), localDirectory: try folder())
        let b = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        try XCTUnwrap(pages(aContext).first).contentData = try largeRTFD("A version")
        try XCTUnwrap(pages(bContext).first).contentData = try largeRTFD("B version")
        try aContext.save(); try bContext.save()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        let texts = { (c: ModelContext) in try Set(self.pages(c).map { try PageContentCodec.richText($0.contentData).string.prefix(9) }) }
        XCTAssertEqual(try texts(aContext), ["A version", "B version"])
        XCTAssertEqual(try texts(bContext), ["A version", "B version"])
    }

    // MARK: - History stays on each Mac

    func testSyncDoesNotUploadHistoryAndKeepsEachMacsOwn() async throws {
        let shared = try folder(), aContext = try context(), bContext = try context()
        let page = try seed(aContext)
        for version in 1...5 {
            page.contentData = try largeRTFD("version \(version)")
            try PageHistory.capture(page, force: true)
        }
        try aContext.save()
        let locks = SectionLockStore()
        let a = FolderSync(defaults: defaults(), localDirectory: try folder())
        let b = FolderSync(defaults: defaults(), localDirectory: try folder())
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        XCTAssertEqual(blobFiles(shared).count, 1, "only the current page content, no history versions")
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        let bPage = try XCTUnwrap(pages(bContext).first)
        XCTAssertEqual(bPage.contentData, page.contentData)
        XCTAssertTrue(try PageHistory.revisions(bPage).isEmpty, "history isn't transferred")

        // Each Mac's own history survives edits arriving from the other.
        try PageHistory.capture(bPage, force: true)
        bPage.contentData = try largeRTFD("edited on B")
        try bContext.save()
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        XCTAssertEqual(try PageContentCodec.richText(page.contentData).string.prefix(11), "edited on B")
        XCTAssertEqual(try PageHistory.revisions(page).count, 5, "A's history untouched by B's edit")
        XCTAssertEqual(try PageHistory.revisions(bPage).count, 1)
    }

    func testOwnUnusedBlobsAreRemovedAtOnceButOtherMacsBlobsAreKept() async throws {
        let shared = try folder(), context = try context()
        let page = try seed(context)
        page.contentData = try largeRTFD("first")
        try context.save()
        let sync = FolderSync(defaults: defaults(), localDirectory: try folder())
        let locks = SectionLockStore()
        try await sync.synchronize(folder: shared, context: context, locks: locks)
        let first = Set(blobFiles(shared).keys)
        XCTAssertEqual(first.count, 1)

        // Another Mac (e.g. an older build) references a blob of its own.
        let blobs = shared.appendingPathComponent("Daftar Sync/blobs")
        let foreign = Data(repeating: 7, count: 10_000), foreignKey = SyncBlobs.hash(foreign)
        try FileManager.default.createDirectory(at: SyncBlobs.url(for: foreignKey, in: blobs).deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreign.write(to: SyncBlobs.url(for: foreignKey, in: blobs))
        var other = try JSONDecoder().decode(SyncEnvelope.self, from: Data(contentsOf: try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: shared.appendingPathComponent("Daftar Sync"), includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "daftarsync" })))
        other.deviceID = UUID().uuidString
        // Its own notebook (fresh IDs), whose only large payload is the foreign blob.
        let mine = try XCTUnwrap(other.records.values.compactMap(\.notebook).first)
        let theirs = try mine.conflictCopy(namespace: "other mac").mappingPages { page in
            page.contentBlob = nil
            page.contentData = try PageContentCodec.rtfd(NSAttributedString(string: "small"))
            page.historyBlob = foreignKey
        }
        other.records = [theirs.stableID!.uuidString: SyncRecord(clock: [other.deviceID: 1], notebook: theirs)]
        try JSONEncoder().encode(other).write(to: shared.appendingPathComponent("Daftar Sync/\(other.deviceID).daftarsync"))

        page.contentData = try largeRTFD("second")
        try context.save()
        try await sync.synchronize(folder: shared, context: context, locks: locks)
        let now = Set(blobFiles(shared).keys)
        XCTAssertTrue(first.isDisjoint(with: now), "this Mac's old content blob is removed right away")
        XCTAssertTrue(now.contains(foreignKey), "a blob another Mac still references is kept")
    }

    func testMoveOutPlacesPageDirectlyAfterItsFormerParent() throws {
        let context = try context(), first = try seed(context, title: "First")
        let section = try XCTUnwrap(first.section)
        let second = Page(title: "Second", sortIndex: 1); context.insert(second); second.section = section
        let child = Page(title: "Child", sortIndex: 0); context.insert(child); child.section = section; child.parent = first
        LibraryActions.moveOut(child)
        XCTAssertNil(child.parent)
        XCTAssertEqual(section.rootPages.map(\.title), ["First", "Child", "Second"])
    }

    func testMovingAPageToAnotherSectionTakesItsSubpagesAlong() throws {
        let context = try context(), page = try seed(context, title: "Parent")
        let child = Page(title: "Child"); context.insert(child); child.section = page.section; child.parent = page
        let trashedChild = Page(title: "Old"); context.insert(trashedChild); trashedChild.section = page.section
        trashedChild.parent = page; trashedChild.deletedAt = Date()
        let other = NoteSection(name: "Other"); context.insert(other); other.notebook = page.section?.notebook
        let existing = Page(title: "Existing", sortIndex: 0); context.insert(existing); existing.section = other

        LibraryActions.move(page, to: other)
        XCTAssertTrue(page.section === other && child.section === other && trashedChild.section === other,
                      "sub-pages, trashed ones included, move with their page")
        XCTAssertEqual(other.rootPages.map(\.title), ["Existing", "Parent"])
    }

    func testNestingAndPlacingAcrossSectionsRefusesCycles() throws {
        let context = try context(), a = try seed(context, title: "A")
        let other = NoteSection(name: "Other"); context.insert(other); other.notebook = a.section?.notebook
        let x = Page(title: "X", sortIndex: 0); context.insert(x); x.section = other
        let y = Page(title: "Y", sortIndex: 1); context.insert(y); y.section = other

        XCTAssertTrue(LibraryActions.place(a, beside: y))
        XCTAssertEqual(other.rootPages.map(\.title), ["X", "A", "Y"])
        XCTAssertTrue(LibraryActions.place(a, beside: y, after: true))
        XCTAssertEqual(other.rootPages.map(\.title), ["X", "Y", "A"])

        XCTAssertTrue(LibraryActions.nest(y, under: a))
        XCTAssertTrue(y.parent === a)
        XCTAssertFalse(LibraryActions.nest(a, under: y), "a page can't go inside its own sub-page")
        XCTAssertFalse(LibraryActions.place(a, beside: y), "nor beside its own sub-page")
        XCTAssertFalse(LibraryActions.nest(a, under: a))
        XCTAssertTrue(y.parent === a, "a refused move changes nothing")
    }

    func testDropZonesSplitARowIntoEdgesAndMiddle() {
        XCTAssertEqual(PageDropZone.zone(atY: 3, rowHeight: 39), .before)
        XCTAssertEqual(PageDropZone.zone(atY: 20, rowHeight: 39), .inside)
        XCTAssertEqual(PageDropZone.zone(atY: 36, rowHeight: 39), .after)
    }

    func testCursorPositionsAreBatchedAndWrittenOnFlush() {
        let defaults = defaults(), id = UUID()
        SessionStore.rememberCursor(7, id: id)
        XCTAssertEqual(SessionStore.latestCursor(id), 7, "a pending position is used before it's written")
        XCTAssertNil(defaults.object(forKey: "cursor." + id.uuidString))
        SessionStore.flushCursors(defaults: defaults)
        XCTAssertEqual(SessionStore.cursor(id, defaults: defaults), 7)
    }

    func testBacklinksReloadOnlyWhenAnotherPageSaves() throws {
        let context = try context(), page = try seed(context)
        let other = Page(title: "Other"); context.insert(other); other.section = page.section
        try context.save()
        func note(updated: [PersistentIdentifier]) -> Notification {
            Notification(name: ModelContext.didSave, object: context, userInfo: [
                ModelContext.NotificationKey.insertedIdentifiers.rawValue: [PersistentIdentifier](),
                ModelContext.NotificationKey.updatedIdentifiers.rawValue: updated,
                ModelContext.NotificationKey.deletedIdentifiers.rawValue: [PersistentIdentifier]()])
        }
        let id = page.persistentModelID
        XCTAssertFalse(BacklinksView.needsReload(after: note(updated: [id]), for: id), "autosaving this page")
        XCTAssertTrue(BacklinksView.needsReload(after: note(updated: [id, other.persistentModelID]), for: id))
        XCTAssertTrue(BacklinksView.needsReload(after: Notification(name: ModelContext.didSave), for: id), "no details")
    }

    func testTypedTextKeepsTheChosenColorWhilePastedTextIsNormalized() throws {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let textView = DaftarTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        textView.isRichText = true
        let coordinator = RichTextEditor.Coordinator(onChange: { _, _, _ in })
        textView.delegate = coordinator
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed]
        textView.insertText("red", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let pasted = NSAttributedString(string: "black", attributes: [.foregroundColor: NSColor.black])
        pasteboard.clearContents()
        pasteboard.setData(try pasted.data(from: NSRange(location: 0, length: pasted.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .rtf))
        XCTAssertEqual(storage.string, "redblack")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, .textColor)
    }
}
