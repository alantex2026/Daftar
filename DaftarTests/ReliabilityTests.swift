import XCTest
import AppKit
import SwiftData
@testable import Daftar

@MainActor
final class ReliabilityTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeNotebook(_ context: ModelContext) -> (Notebook, NoteSection) {
        let notebook = Notebook(name: "Notebook")
        context.insert(notebook)
        let section = NoteSection(name: "Section")
        context.insert(section)
        section.notebook = notebook
        return (notebook, section)
    }

    private func encode(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    private func attachment(_ bytes: Data) throws -> Data {
        let wrapper = FileWrapper(regularFileWithContents: bytes)
        wrapper.preferredFilename = "same.txt"
        return try encode(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    }

    func testGroupLockHidesDescendantsAndDeniedAuthenticationKeepsThemHidden() throws {
        let context = try makeContext()
        let (notebook, group) = makeNotebook(context)
        group.isGroup = true
        group.isLocked = true
        let child = NoteSection(name: "Child")
        context.insert(child)
        child.parent = group
        child.notebook = notebook
        let page = Page(title: "Secret")
        context.insert(page)
        page.section = child
        try context.save()
        let denied = SectionLockStore(authenticate: { _, completion in completion(false) })
        XCTAssertFalse(denied.isUnlocked(child))
        XCTAssertFalse(denied.canShow(page))
        denied.requestUnlock(child, reason: "test") { XCTAssertFalse($0) }
        XCTAssertFalse(denied.canShow(page))

        let allowed = SectionLockStore(authenticate: { _, completion in completion(true) })
        allowed.requestUnlock(child, reason: "test") { XCTAssertTrue($0) }
        XCTAssertTrue(allowed.canShow(page))
        allowed.lockNow(group)
        XCTAssertFalse(allowed.canShow(page))
    }

    func testLockedExportWritesNothingUntilAuthenticated() throws {
        let context = try makeContext()
        let (notebook, section) = makeNotebook(context)
        section.isLocked = true
        try context.save()
        let destination = try temporaryFolder()
        let locks = SectionLockStore(authenticate: { _, completion in completion(true) })
        XCTAssertThrowsError(try NotebookMarkdownIO.export(notebook, to: destination, locks: locks))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        locks.requestUnlock(section, reason: "test") { XCTAssertTrue($0) }
        let folder = try NotebookMarkdownIO.export(notebook, to: destination, locks: locks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(NotebookArchive.filename).path))
    }

    func testSiblingAttachmentsWithSameFilenameRemainDistinct() throws {
        let context = try makeContext()
        let (notebook, section) = makeNotebook(context)
        for (index, bytes) in [Data("first".utf8), Data("second".utf8)].enumerated() {
            let page = Page(title: "Page \(index)", sortIndex: index)
            context.insert(page)
            page.section = section
            page.contentData = try attachment(bytes)
        }
        let folder = try NotebookMarkdownIO.export(notebook, to: temporaryFolder(), locks: SectionLockStore())
        let assets = folder.appendingPathComponent("Section/assets")
        let urls = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 2)
        let contents = try Set(urls.map { try Data(contentsOf: $0) })
        XCTAssertEqual(contents, Set([Data("first".utf8), Data("second".utf8)]))
        let first = try String(contentsOf: folder.appendingPathComponent("Section/Page 0.md"), encoding: .utf8)
        let second = try String(contentsOf: folder.appendingPathComponent("Section/Page 1.md"), encoding: .utf8)
        XCTAssertTrue(first.contains("assets/same.txt"))
        XCTAssertTrue(second.contains("assets/same%202.txt"))
    }

    func testMovingGroupPreservesAllDescendantsAfterDeletingOriginalNotebook() throws {
        let context = try makeContext()
        let (old, group) = makeNotebook(context)
        group.isGroup = true
        let new = Notebook(name: "Destination")
        context.insert(new)
        let child = NoteSection(name: "Child", isGroup: true)
        context.insert(child)
        child.parent = group
        child.notebook = old
        let grandchild = NoteSection(name: "Trashed descendant")
        context.insert(grandchild)
        grandchild.parent = child
        grandchild.notebook = old
        grandchild.deletedAt = Date()
        let page = Page(title: "Keep me")
        context.insert(page)
        page.section = grandchild
        try context.save()
        group.move(to: new)
        try context.save()
        XCTAssertTrue(old.sections.isEmpty)
        XCTAssertTrue(child.notebook === new)
        XCTAssertTrue(grandchild.notebook === new)
        context.delete(old)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteSection>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Page>()).map(\.title), ["Keep me"])
    }

    func testArchiveRestoresHierarchySpreadsheetAttachmentsAndInternalLinks() throws {
        let context = try makeContext()
        let (notebook, group) = makeNotebook(context)
        group.isGroup = true
        let section = NoteSection(name: "Nested")
        context.insert(section)
        section.parent = group
        section.notebook = notebook
        let sheet = Page(title: "Budget", sortIndex: 0)
        context.insert(sheet)
        sheet.section = section
        sheet.kind = .spreadsheet
        let grid = SpreadsheetData(rows: 3, columns: 2, cells: ["A1": "12", "B1": "=A1*2"])
        sheet.spreadsheetData = try JSONEncoder().encode(grid)
        let child = Page(title: "Receipt")
        context.insert(child)
        child.parent = sheet
        child.section = section
        child.kind = .document
        child.contentData = try attachment(Data("receipt".utf8))
        let link = Page(title: "Index", sortIndex: 1)
        context.insert(link)
        link.section = section
        link.contentData = try encode(NSAttributedString(string: "Budget", attributes: [.link: "daftar://page/\(sheet.linkID.uuidString)"]))
        let folder = try NotebookMarkdownIO.export(notebook, to: temporaryFolder(), locks: SectionLockStore())
        let markdown = try String(contentsOf: folder.appendingPathComponent("Section/Nested/Budget/Budget.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("=A1*2"))
        let imported = try NotebookMarkdownIO.importFolder(folder, context: context)
        let importedGroup = try XCTUnwrap(imported.topLevelSections.first)
        XCTAssertTrue(importedGroup.isGroup)
        let importedSection = try XCTUnwrap(importedGroup.sortedChildren.first)
        XCTAssertEqual(importedSection.name, "Nested")
        XCTAssertTrue(importedSection.notebook === imported)
        let importedSheet = try XCTUnwrap(importedSection.rootPages.first)
        XCTAssertEqual(importedSheet.kind, .spreadsheet)
        XCTAssertEqual(try PageContentCodec.spreadsheet(importedSheet.spreadsheetData), grid)
        XCTAssertNotEqual(importedSheet.linkID, sheet.linkID)
        let importedChild = try XCTUnwrap(importedSheet.sortedChildren.first)
        XCTAssertEqual(importedChild.kind, .document)
        let text = try PageContentCodec.richText(importedChild.contentData)
        let file = try XCTUnwrap(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(file.fileWrapper?.regularFileContents, Data("receipt".utf8))
        XCTAssertEqual(importedSection.rootPages.last?.outgoingLinkIDs, [importedSheet.linkID])
    }

    func testCorruptExportFailsWithoutLeavingPartialNotebook() throws {
        let context = try makeContext()
        let (notebook, section) = makeNotebook(context)
        let page = Page(title: "Damaged")
        context.insert(page)
        page.section = section
        page.kind = .spreadsheet
        page.spreadsheetData = Data("bad JSON".utf8)
        let destination = try temporaryFolder()
        XCTAssertThrowsError(try NotebookMarkdownIO.export(notebook, to: destination, locks: SectionLockStore()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testSaveStateOnlySucceedsAfterCommitAndFailureCanBeRetried() {
        enum Failure: Error { case diskFull }
        let saver = SaveCoordinator()
        var fail = true
        var committed = false
        saver.schedule(delay: 30) {
            if fail { throw Failure.diskFull }
            committed = true
        }
        XCTAssertEqual(saver.state, .saving)
        XCTAssertFalse(saver.flush())
        XCTAssertFalse(committed)
        XCTAssertEqual(saver.state, .failed)
        fail = false
        XCTAssertTrue(saver.flush())
        XCTAssertTrue(committed)
        XCTAssertEqual(saver.state, .saved)
        XCTAssertNil(saver.errorMessage)
    }

    func testAutoSaveDelayLongerThanFiveSecondsIsHonored() {
        let saver = SaveCoordinator()
        var saved = false
        saver.schedule(delay: 6) { saved = true }
        let early = expectation(description: "not saved before the chosen delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) { XCTAssertFalse(saved); early.fulfill() }
        let late = expectation(description: "saved after the chosen delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) { XCTAssertTrue(saved); late.fulfill() }
        wait(for: [early, late], timeout: 8, enforceOrder: true)
    }

    func testTerminationFlushKeepsPendingEditsAliveAfterViewIsReleased() {
        var commits: [String] = []
        var saver: SaveCoordinator? = SaveCoordinator()
        saver?.schedule(delay: 30) { commits.append("latest edit") }
        saver = nil
        XCTAssertTrue(SaveCoordinator.flushAll())
        XCTAssertEqual(commits, ["latest edit"])
        XCTAssertTrue(SaveCoordinator.flushAll())
        XCTAssertEqual(commits.count, 1, "a flush must not replay a successful edit")
    }

    func testSaveFlushPersistsBeforeReopeningDiskStore() throws {
        let url = try temporaryFolder().appendingPathComponent("notes.store")
        let configuration = ModelConfiguration(url: url)
        let container = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let page = Page(title: "Quit immediately")
        context.insert(page)
        let saver = SaveCoordinator()
        saver.schedule(delay: 30) {
            page.contentData = try self.encode(NSAttributedString(string: "last keystroke"))
            page.plainText = "last keystroke"
            try context.save()
        }
        XCTAssertTrue(SaveCoordinator.flushAll())
        let reopened = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self, configurations: ModelConfiguration(url: url))
        let reopenedContext = ModelContext(reopened)
        let restored = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<Page>()).first)
        XCTAssertEqual(try PageContentCodec.richText(restored.contentData).string, "last keystroke")
    }

    func testCorruptDataIsPreservedAndResetRequiresSuccessfulBackup() throws {
        let context = try makeContext()
        for kind in [PageKind.document, .spreadsheet, .richText] {
            let page = Page(title: "Damaged")
            context.insert(page)
            page.kind = kind
            let bytes = Data([0x00, 0xff, 0x03])
            if kind == .spreadsheet { page.spreadsheetData = bytes }
            else { page.contentData = bytes }
            XCTAssertThrowsError(try PageContentCodec.validate(page))
            let destination = try temporaryFolder()
            XCTAssertThrowsError(try PageContentCodec.backUpAndReset(page, to: destination, context: context))
            XCTAssertEqual(kind == .spreadsheet ? page.spreadsheetData : page.contentData, bytes)
            let backup = destination.appendingPathComponent("original.data")
            try PageContentCodec.backUpAndReset(page, to: backup, context: context)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            XCTAssertNoThrow(try PageContentCodec.validate(page))
            XCTAssertNil(kind == .spreadsheet ? page.spreadsheetData : page.contentData)
        }
    }

    func testInvalidSpreadsheetDimensionsAndOverflowReferencesAreRejected() throws {
        let invalid = SpreadsheetData(rows: -1, columns: 8, cells: [:])
        XCTAssertThrowsError(try PageContentCodec.spreadsheet(JSONEncoder().encode(invalid)))
        XCTAssertNil(CellReference.parse(String(repeating: "Z", count: 100) + "1"))
    }

    func testWindowControllersEditOnlyTheirOwnTextViews() {
        let first = EditorController()
        let second = EditorController()
        let firstView = NSTextView()
        let secondView = NSTextView()
        firstView.string = "First"
        secondView.string = "Second"
        first.textView = firstView
        second.textView = secondView
        firstView.setSelectedRange(NSRange(location: 0, length: 5))
        secondView.setSelectedRange(NSRange(location: 0, length: 6))
        first.toggleBold()
        let firstFont = firstView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let secondFont = secondView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: firstFont ?? .systemFont(ofSize: 13)).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: secondFont ?? .systemFont(ofSize: 13)).contains(.boldFontMask))
        XCTAssertTrue(first.textView === firstView)
        XCTAssertTrue(second.textView === secondView)
    }
}
