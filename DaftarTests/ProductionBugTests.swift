import XCTest
import AppKit
import SwiftData
@testable import Daftar

@MainActor
final class ProductionBugTests: XCTestCase {
    private func context() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        return context
    }

    /// Bug: unreadable history made every save of the page fail.
    func testDamagedHistoryNeverBlocksSavingContent() throws {
        let context = try context()
        let page = Page(title: "Damaged"); context.insert(page)
        let damaged = Data("{not a revision list".utf8)
        page.historyData = damaged
        try context.save()
        let text = try PageContentCodec.rtfd(NSAttributedString(string: "typed after damage"))
        XCTAssertNoThrow(try page.saveRichText(text, plainText: "typed after damage", links: [], in: context))
        XCTAssertEqual(page.contentData, text, "the edit is stored")
        XCTAssertEqual(page.payload?.damagedHistory, [damaged], "damaged history bytes are preserved, never overwritten")
        XCTAssertNil(page.payload?.legacyHistoryData)
        XCTAssertEqual(try PageHistory.revisions(page).count, 1, "history continues with new revisions")
    }

    /// Bug: the cached history JSON outlived a rollback, so backups and sync
    /// could export history the database no longer has.
    func testHistoryJSONFollowsRollback() throws {
        let context = try context()
        let page = Page(title: "v1"); context.insert(page)
        try PageHistory.capture(page, force: true)
        try context.save()
        let saved = try XCTUnwrap(page.historyData)
        page.title = "v2"
        try PageHistory.capture(page, force: true)
        XCTAssertNotEqual(page.historyData, saved)   // caches the unsaved state
        context.rollback()
        XCTAssertEqual(try PageHistory.revisions(page).count, 1)
        XCTAssertEqual(page.historyData, saved, "exported history must match what's stored")
    }

    /// Bug: when saving kept failing, quitting was impossible and a force quit
    /// lost the typing. Pending edits must be recoverable as files.
    func testPersistentSaveFailureCanStillRescueTyping() throws {
        enum DiskFull: Error { case full }
        let storage = NSTextStorage(string: "Meeting notes: ship on Friday\nsecond line")
        var diskFull = true
        let autosaver = RichTextAutosaver { _, _, _ in if diskFull { throw DiskFull.full } }
        // Failed saves stay pending app-wide by design; clear ours for other tests.
        defer { diskFull = false; XCTAssertTrue(SaveCoordinator.flushAll()) }
        autosaver.schedule(storage, controller: nil) { _ in true }
        XCTAssertFalse(autosaver.flush())
        XCTAssertFalse(SaveCoordinator.flushAll(), "quit is refused while the edit is unsaved")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try SaveCoordinator.rescueAll(to: folder)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent == "Meeting notes ship on Friday.rtfd" })
        let rescued = try NSAttributedString(url: file, options: [:], documentAttributes: nil)
        XCTAssertEqual(rescued.string, storage.string)
    }

    func testEveryDistinctDamagedHistoryCopyIsKept() throws {
        let context = try context()
        let page = Page(title: "twice"); context.insert(page)
        page.historyData = Data("first damage".utf8)
        try PageHistory.capture(page, force: true)
        page.historyData = Data("second damage".utf8)   // e.g. arrives again from elsewhere
        try PageHistory.capture(page, force: true)
        XCTAssertEqual(page.payload?.damagedHistory, [Data("first damage".utf8), Data("second damage".utf8)])
    }

    func testSpreadsheetRescueIsValidCSV() {
        var sheet = SpreadsheetData.empty
        sheet.rows = 2; sheet.columns = 2
        sheet.cells = ["A1": "Item", "B1": "Note, with comma", "A2": "=SUM(1,2)", "B2": "say \"hi\"\nnext"]
        XCTAssertEqual(sheet.csv, "Item,\"Note, with comma\"\r\n\"=SUM(1,2)\",\"say \"\"hi\"\"\nnext\"")
    }

    func testStaleCursorPositionsArePruned() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let kept = UUID(), gone = UUID()
        SessionStore.saveCursor(5, id: kept, defaults: defaults)
        SessionStore.saveCursor(9, id: gone, defaults: defaults)
        defaults.set(1, forKey: "cursor.not-a-page")  // unrelated keys are left alone
        XCTAssertEqual(SessionStore.pruneCursors(keeping: [kept], defaults: defaults), 1)
        XCTAssertEqual(SessionStore.cursor(kept, defaults: defaults), 5)
        XCTAssertNil(defaults.object(forKey: "cursor." + gone.uuidString))
        XCTAssertNotNil(defaults.object(forKey: "cursor.not-a-page"))
    }

    func testLockedSectionsPauseSyncVisibly() async throws {
        let context = try context()
        let notebook = Notebook(name: "N"); context.insert(notebook)
        let section = NoteSection(name: "Secret"); section.notebook = notebook; section.isLocked = true
        context.insert(section)
        try context.save()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let sync = FolderSync(defaults: defaults, localDirectory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sync.chooseFolder(folder)
        let locks = SectionLockStore { _, done in done(false) }  // FolderSync holds it weakly
        sync.attach(context: context, locks: locks)
        sync.syncNow()
        for _ in 0..<50 where sync.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(sync.needsAttention, sync.status)
        XCTAssertTrue(sync.status.hasPrefix("Sync paused"))
        sync.disable()
        withExtendedLifetime(locks) {}
    }
}
