import XCTest
import AppKit
import SwiftData
@testable import Daftar

@MainActor
final class ArchitectureTests: XCTestCase {
    private func context() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        return context
    }

    func testDaftarLinkRoundTripsEveryScheme() {
        let id = UUID()
        for link in [DaftarLink.page(id), .checklistToggle, .audio(id), .image, .file] {
            XCTAssertEqual(DaftarLink(link.url), link)
            XCTAssertEqual(DaftarLink(link.url.absoluteString), link, "AppKit may store links as String")
        }
        XCTAssertNil(DaftarLink(URL(string: "https://example.com")))
        XCTAssertNil(DaftarLink("daftar://page/not-a-uuid"))
    }

    func testPageLinksAreFoundAndRemapped() throws {
        let old = UUID(), new = UUID(), other = UUID()
        let text = NSMutableAttributedString(string: "ab c")
        text.addAttribute(.link, value: DaftarLink.page(old).url, range: NSRange(location: 0, length: 1))
        text.addAttribute(.link, value: DaftarLink.page(other).url.absoluteString, range: NSRange(location: 1, length: 1))
        text.addAttribute(.link, value: DaftarLink.checklistToggle.url, range: NSRange(location: 3, length: 1))
        XCTAssertEqual(Set(text.linkedPageIDs), [old, other])
        text.remapPageLinks([old: new])
        XCTAssertEqual(Set(text.linkedPageIDs), [new, other])
        let data = try PageContentCodec.rtfd(text)
        XCTAssertEqual(Set(try PageContentCodec.richText(PageContentCodec.remapLinks(data, ids: [new: old])).linkedPageIDs), [old, other])
    }

    func testHistoryCaptureSkipsDecodingInsideCoalescingWindow() throws {
        let page = Page(title: "Busy page")
        let start = Date()
        try PageHistory.capture(page, force: true, now: start)
        XCTAssertEqual(page.historyCapturedAt, start)
        // Unreadable history proves the fast path never decodes it.
        let original = page.historyData
        page.historyData = Data("not json".utf8)
        page.title = "Edited"
        XCTAssertNoThrow(try PageHistory.capture(page, now: start.addingTimeInterval(30)))
        page.historyData = original
        // After the window a new revision is captured again.
        try PageHistory.capture(page, now: start.addingTimeInterval(61))
        XCTAssertEqual(try PageHistory.revisions(page).count, 2)
        XCTAssertEqual(page.historyCapturedAt, start.addingTimeInterval(61))
    }

    func testHistoryWithoutTimestampStillCoalesces() throws {
        // Pages restored from backups or sync arrive without `historyCapturedAt`.
        let page = Page(title: "Restored")
        try PageHistory.capture(page, force: true)
        page.historyCapturedAt = nil
        page.title = "Changed"
        try PageHistory.capture(page)
        XCTAssertEqual(try PageHistory.revisions(page).count, 1, "still inside the window")
        XCTAssertNotNil(page.historyCapturedAt, "the slow path records the timestamp for next time")
    }

    func testSaveRichTextStoresContentLinksAndHistory() throws {
        let context = try context()
        let page = Page(title: "Note"); context.insert(page)
        page.contentData = try PageContentCodec.rtfd(NSAttributedString(string: "before"))
        let target = UUID()
        let data = try PageContentCodec.rtfd(NSAttributedString(string: "after"))
        try page.saveRichText(data, plainText: "after", links: [target], in: context)
        XCTAssertEqual(page.contentData, data)
        XCTAssertEqual(page.plainText, "after")
        XCTAssertEqual(page.outgoingLinkIDs, [target])
        XCTAssertEqual(try PageContentCodec.richText(PageHistory.revisions(page).first?.contentData).string, "before")
    }

    func testLinkRouterHandlesLinksForBothEditors() {
        let controller = EditorController()
        var opened: UUID?
        controller.onNavigateToLink = { opened = $0 }
        let router = EditorLinkRouter()
        router.controller = controller
        let textView = NSTextView()
        let id = UUID()
        XCTAssertTrue(router.handle(DaftarLink.page(id).url, at: 0, in: textView))
        XCTAssertEqual(opened, id)
        XCTAssertTrue(router.handle(DaftarLink.image.url.absoluteString, at: 0, in: textView))
        XCTAssertFalse(router.handle(URL(string: "https://example.com")!, at: 0, in: textView))
    }

    func testEditorFollowsSettingsChangedElsewhere() {
        let controller = EditorController()
        let previous = UserDefaults.standard.object(forKey: AppSettings.autoSaveDelay)
        defer { UserDefaults.standard.set(previous, forKey: AppSettings.autoSaveDelay) }
        UserDefaults.standard.set(7.5, forKey: AppSettings.autoSaveDelay)
        let updated = expectation(description: "delay mirrored")
        DispatchQueue.main.async { if controller.autoSaveDelay == 7.5 { updated.fulfill() } }
        wait(for: [updated], timeout: 2)
    }

    // MARK: - Page payload

    func testPayloadIsCreatedOnWriteAndDeletedWithPage() throws {
        let context = try context()
        let page = Page(title: "Payload")
        context.insert(page)
        XCTAssertNil(page.payload)
        page.contentData = Data("rtfd".utf8)
        XCTAssertEqual(page.payload?.contentData, Data("rtfd".utf8))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PagePayload>()), 1)
        context.delete(page)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PagePayload>()), 0, "payload cascades with its page")
    }

    func testLegacyColumnsAreReadAndMovedWithoutLosingFields() throws {
        let context = try context()
        let page = Page(title: "Old store")
        page.legacyContentData = Data("content".utf8)
        page.legacyHistoryData = Data("history".utf8)
        context.insert(page)
        XCTAssertEqual(page.contentData, Data("content".utf8), "unmigrated pages still read")
        // Writing one field must carry the others into the payload.
        page.historyData = Data("new history".utf8)
        XCTAssertEqual(page.contentData, Data("content".utf8))
        XCTAssertNil(page.legacyContentData)
        let other = Page(title: "Also old")
        other.legacySpreadsheetData = Data("sheet".utf8)
        context.insert(other)
        try context.save()
        XCTAssertEqual(try PagePayload.migrateLegacyColumns(context: context), 1)
        XCTAssertEqual(other.spreadsheetData, Data("sheet".utf8))
        XCTAssertNil(other.legacySpreadsheetData)
        XCTAssertEqual(try PagePayload.migrateLegacyColumns(context: context), 0)
    }

    // MARK: - Library actions

    private func seededSection(_ context: ModelContext) -> NoteSection {
        let (_, section) = LibraryActions.addNotebook(after: [], context: context)
        return section
    }

    func testDuplicatedSubpageStaysAmongItsSiblings() throws {
        let context = try context(), section = seededSection(context)
        let parent = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: context))
        let child = try XCTUnwrap(LibraryActions.addPage(to: section, under: parent, context: context))
        _ = LibraryActions.addPage(to: section, under: nil, context: context)
        let copy = LibraryActions.duplicate(child, context: context)
        XCTAssertTrue(copy.parent === parent)
        XCTAssertEqual(copy.sortIndex, 1, "next index among the parent's children, not among root pages")
        XCTAssertEqual(copy.title, "Untitled copy")
    }

    func testRestoringAPageRestoresEveryTrashedAncestor() throws {
        let context = try context(), section = seededSection(context)
        let parent = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: context))
        let child = try XCTUnwrap(LibraryActions.addPage(to: section, under: parent, context: context))
        LibraryActions.trash(child); LibraryActions.trash(parent); LibraryActions.trash(section)
        section.notebook.map(LibraryActions.trash)
        LibraryActions.restore(child)
        XCTAssertFalse(child.isTrashed)
        XCTAssertNil(parent.deletedAt); XCTAssertNil(section.deletedAt); XCTAssertNil(section.notebook?.deletedAt)
    }

    func testReorderOnlyAffectsSiblings() throws {
        let context = try context(), section = seededSection(context)
        let pages = (0..<3).compactMap { _ in LibraryActions.addPage(to: section, under: nil, context: context) }
        LibraryActions.reorderPages(moving: pages[2], to: pages[0])
        XCTAssertEqual(section.rootPages.map(\.persistentModelID), [pages[2], pages[0], pages[1]].map(\.persistentModelID))
        let child = try XCTUnwrap(LibraryActions.addPage(to: section, under: pages[0], context: context))
        LibraryActions.reorderPages(moving: child, to: pages[1])
        XCTAssertTrue(child.parent === pages[0], "dragging never reparents")
    }

    // MARK: - Sync reconciliation

    func testSyncUpdatesExistingModelsInPlace() async throws {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shared) }
        func sync() throws -> FolderSync {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            return FolderSync(defaults: UserDefaults(suiteName: UUID().uuidString)!, localDirectory: folder)
        }
        let a = try sync(), b = try sync(), locks = SectionLockStore()
        let aContext = try context(), bContext = try context()
        let section = seededSection(aContext)
        let page = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: aContext))
        let untouched = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: aContext))
        page.contentData = try PageContentCodec.rtfd(NSAttributedString(string: "v1"))
        try aContext.save()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        let bPage = try XCTUnwrap(bContext.fetch(FetchDescriptor<Page>()).first { $0.linkID == page.linkID })
        bPage.section?.isExpanded = false  // local-only UI state
        try bContext.save()

        page.contentData = try PageContentCodec.rtfd(NSAttributedString(string: "v2"))
        try aContext.save()
        try await a.synchronize(folder: shared, context: aContext, locks: locks)
        var reloaded: Set<UUID>?
        let observer = NotificationCenter.default.addObserver(forName: .daftarReloadEditors, object: nil, queue: nil) { reloaded = $0.object as? Set<UUID> }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await b.synchronize(folder: shared, context: bContext, locks: locks)
        let after = try XCTUnwrap(bContext.fetch(FetchDescriptor<Page>()).first { $0.linkID == page.linkID })
        XCTAssertTrue(after === bPage, "the same model object is updated, not replaced")
        XCTAssertFalse(bPage.isDeleted)
        XCTAssertEqual(try PageContentCodec.richText(bPage.contentData).string, "v2")
        XCTAssertEqual(bPage.section?.isExpanded, false, "local UI state survives a sync")
        XCTAssertEqual(reloaded, [page.linkID], "only the changed page's editor reloads")
        XCTAssertFalse(reloaded?.contains(untouched.linkID) ?? true)
    }

    // MARK: - Save encoding

    func testPortableCopyEncodesFreshWrappersWithSameContents() throws {
        let wrapper = FileWrapper(regularFileWithContents: Data(repeating: 9, count: 50_000))
        wrapper.preferredFilename = "picture.png"
        let decoded = try PageContentCodec.richText(PageContentCodec.rtfd(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))))
        let portable = CanvasImageLayout.portable(decoded)
        let attachment = try XCTUnwrap(portable.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let original = try XCTUnwrap(decoded.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertFalse(attachment.fileWrapper === original.fileWrapper)
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "picture.png")
        let reread = try PageContentCodec.richText(PageContentCodec.rtfd(portable))
        let final = try XCTUnwrap(reread.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(final.fileWrapper?.regularFileContents, wrapper.regularFileContents)
    }

    // MARK: - History rows

    func testEachRevisionIsARowAndOldOnesArePruned() throws {
        let context = try context()
        let page = Page(title: "v0"); context.insert(page)
        for index in 1...(PageHistory.limit + 5) {
            page.title = "v\(index)"
            try PageHistory.capture(page, force: true)
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PageRevisionEntry>()), PageHistory.limit, "pruned rows are deleted")
        XCTAssertEqual(try PageHistory.revisions(page).first?.title, "v\(PageHistory.limit + 5)")
        // The portable JSON round-trips to the same revisions and is deterministic.
        let json = try XCTUnwrap(page.historyData)
        let copy = Page(title: "copy"); context.insert(copy)
        copy.historyData = json
        XCTAssertEqual(try PageHistory.revisions(copy), try PageHistory.revisions(page))
        XCTAssertEqual(copy.historyData, json)
        XCTAssertTrue(PageHistory.hasSameRevisions(copy, as: json))
    }

    func testHistoryJSONIsConvertedToRowsOnce() throws {
        let context = try context()
        let revision = PageRevision(id: UUID(), capturedAt: Date(), title: "old", kind: 0, contentData: nil, spreadsheetData: nil,
                                    plainText: "", outgoingLinkIDs: [], customTags: [], tagRaw: 0, paperSize: "letter")
        let payload = PagePayload()
        payload.legacyHistoryData = try JSONEncoder().encode([revision])
        let page = Page(title: "p"); page.payload = payload
        context.insert(page)
        try context.save()
        XCTAssertEqual(try PageHistory.revisions(page), [revision], "readable before conversion")
        XCTAssertEqual(try PagePayload.migrateHistoryToRevisions(context: context), 1)
        XCTAssertNil(payload.legacyHistoryData)
        XCTAssertEqual(payload.revisionEntries.count, 1)
        XCTAssertEqual(try PagePayload.migrateHistoryToRevisions(context: context), 0)
    }

    func testSyncManifestIsTheSameFromRowsOrFromJSON() throws {
        let context = try context(), section = seededSection(context)
        let page = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: context))
        page.contentData = Data(repeating: 1, count: 10_000)
        try PageHistory.capture(page, force: true)
        page.contentData = Data(repeating: 2, count: 10_000)
        try PageHistory.capture(page, force: true)
        let notebook = try XCTUnwrap(section.notebook)
        let structured = NotebookArchive(notebook, includeTrash: true, structuredHistory: true)
        let portable = NotebookArchive(notebook, includeTrash: true)
        XCTAssertNotNil(structured.sections[0].pages[0].history)
        XCTAssertEqual(try structured.withPortableHistory(), portable, "backups written from sync captures are ordinary backups")
        var a: [String: Data] = [:], b: [String: Data] = [:]
        XCTAssertEqual(SyncBlobs.dehydrate(structured, store: &a), SyncBlobs.dehydrate(portable, store: &b))
        XCTAssertEqual(a, b)
    }
}
