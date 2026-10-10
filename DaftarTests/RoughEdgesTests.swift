import XCTest
import SwiftData
import AppKit
@testable import Daftar

/// Renaming, sidebar counts, the sync typing pause, tab names and the
/// single decode on page open.
@MainActor
final class RoughEdgesTests: XCTestCase {
    private func context() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        return context
    }

    func testRenameKeepsTheOldNameForBlankOrUnchangedInput() {
        XCTAssertEqual(RenameField.resolvedName(draft: "  Projects  ", original: "Work"), "Projects")
        XCTAssertNil(RenameField.resolvedName(draft: "", original: "Work"), "an empty name keeps the old one")
        XCTAssertNil(RenameField.resolvedName(draft: " \n ", original: "Work"))
        XCTAssertNil(RenameField.resolvedName(draft: "Work", original: "Work"), "no change, nothing saved")
    }

    func testSidebarCountsEachSectionOnceIncludingNestedOnesAndSkippingTrash() throws {
        let context = try context()
        let notebook = Notebook(name: "N"); context.insert(notebook)
        let group = NoteSection(name: "Group", isGroup: true); context.insert(group); group.notebook = notebook
        let inner = NoteSection(name: "Inner"); context.insert(inner); inner.notebook = notebook; inner.parent = group
        for title in ["a", "b"] { let page = Page(title: title); context.insert(page); page.section = inner }
        let trashed = Page(title: "gone"); context.insert(trashed); trashed.section = inner; trashed.deletedAt = Date()
        var counts: [ObjectIdentifier: Int] = [:]
        XCTAssertEqual(SidebarView.countPages(in: group, into: &counts), 2)
        XCTAssertEqual(counts[ObjectIdentifier(inner)], 2)
        XCTAssertEqual(counts[ObjectIdentifier(group)], group.totalPageCount, "matches the model's own count")
    }

    func testTimerSyncWaitsForTypingToPauseButNotForever() {
        let start = Date()
        var waiting: Date?
        XCTAssertTrue(FolderSync.shouldWaitForPause(now: start, lastSave: start.addingTimeInterval(-2), waitingSince: &waiting),
                      "saved 2 s ago: still typing, wait")
        XCTAssertFalse(FolderSync.shouldWaitForPause(now: start.addingTimeInterval(30), lastSave: start, waitingSince: &waiting),
                       "quiet for 30 s: sync")
        XCTAssertNil(waiting)

        // Typing nonstop: saves keep arriving, but sync still runs after two minutes.
        var now = start
        var ranAt: Date?
        while ranAt == nil, now < start.addingTimeInterval(300) {
            if !FolderSync.shouldWaitForPause(now: now, lastSave: now.addingTimeInterval(-1), waitingSince: &waiting) { ranAt = now }
            now += 30
        }
        XCTAssertEqual(ranAt.map { $0.timeIntervalSince(start) } ?? -1, FolderSync.maxWait, accuracy: 0.1)
    }

    func testSameNamedTabsShowTheirNotebookAndEveryTabHasAPath() throws {
        let context = try context()
        let work = Notebook(name: "Work"), home = Notebook(name: "Home"); context.insert(work); context.insert(home)
        let a = NoteSection(name: "Ideas"); context.insert(a); a.notebook = work
        let b = NoteSection(name: "ideas"); context.insert(b); b.notebook = home
        let c = NoteSection(name: "Plans"); context.insert(c); c.notebook = home
        XCTAssertTrue(TabBarView.needsNotebookName(a, among: [a, b, c]))
        XCTAssertFalse(TabBarView.needsNotebookName(c, among: [a, b, c]))
        XCTAssertFalse(TabBarView.needsNotebookName(a, among: [a, c]))
        XCTAssertEqual(TabBarView.path(of: a), "Work \u{203A} Ideas")
    }

    func testPageOpenDecodesOnceAndNeverSharesADecodedCopy() throws {
        let context = try context()
        let page = Page(title: "P"); context.insert(page)
        let original = NSAttributedString(string: "hello")
        let data = try PageContentCodec.rtfd(original)
        page.contentData = data
        try PageContentCodec.validate(page)
        let first = try PageContentCodec.richTextForEditor(data)
        let second = try PageContentCodec.richTextForEditor(data)
        XCTAssertEqual(first.string, "hello")
        XCTAssertEqual(second.string, "hello")
        XCTAssertFalse(first === second, "a second editor gets its own copy")
    }

    func testSharedFileNamesAreSafeForAnyTitle() {
        let folder = FileManager.default.temporaryDirectory
        let url = SaveCoordinator.rescueURL(named: "Q3/Q4: plans?", extension: "pdf", in: folder)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL, "stays in the folder")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
    }
}
