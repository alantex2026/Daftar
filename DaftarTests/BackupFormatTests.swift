import XCTest
import AppKit
import SwiftData
@testable import Daftar

@MainActor
final class BackupFormatTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Notebook.self, NoteSection.self, Page.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        context.autosaveEnabled = false
        return context
    }

    /// RTFD holding `text` and one 200 KB "photo" (identical bytes each time).
    private func rtfdWithPhoto(_ text: String) throws -> Data {
        let photo = FileWrapper(regularFileWithContents: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        photo.preferredFilename = "photo.jpg"
        let content = NSMutableAttributedString(string: text + "\n")
        content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: photo)))
        return try PageContentCodec.rtfd(content)
    }

    private func seededLibrary() throws -> (ModelContext, Page) {
        let context = try makeContext()
        let (_, section) = LibraryActions.addNotebook(after: [], context: context)
        let page = try XCTUnwrap(LibraryActions.addPage(to: section, under: nil, context: context))
        for version in 1...10 {  // ten revisions, all showing the same photo
            page.contentData = try rtfdWithPhoto("version \(version)")
            try PageHistory.capture(page, force: true)
        }
        try context.save()
        return (context, page)
    }

    private func url() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".daftarbackup")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBackupHoldsCurrentPagesWithoutHistory() throws {
        let (context, page) = try seededLibrary()
        XCTAssertEqual(try PageHistory.revisions(page).count, 10, "sanity: the page has history")
        let backup = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                               includeHistory: false)
        let file = url()
        try backup.write(to: file)
        let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, 250_000, "one photo, no history versions")

        let target = try makeContext()
        _ = try LibraryBackup.read(from: file).restore(context: target, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<Page>()).first)
        let before = try PageContentCodec.richText(page.contentData), after = try PageContentCodec.richText(restored.contentData)
        XCTAssertEqual(after.string, before.string)
        let photo = { (text: NSAttributedString) in (text.attribute(.attachment, at: text.length - 1, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper }
        XCTAssertEqual(photo(after)?.regularFileContents, photo(before)?.regularFileContents)
        XCTAssertEqual(photo(after)?.preferredFilename, "photo.jpg")
        XCTAssertEqual(try PageHistory.revisions(restored).count, 0, "restored pages start with fresh history")
    }

    func testHistoryIsLeftOutEvenFromCapturesThatHaveIt() throws {
        // Sync's recovery copies come from captures that include history.
        let (context, _) = try seededLibrary()
        let withHistory = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                                    structuredHistory: true)
        let file = url()
        try withHistory.write(to: file)
        let page = try XCTUnwrap(LibraryBackup.read(from: file).notebooks.first?.sections.first?.pages.first)
        XCTAssertNil(page.historyData)
        XCTAssertNil(page.history)
        XCTAssertNotNil(page.contentData)
    }

    func testDamagedBackupIsRefusedBeforeAnythingIsRestored() throws {
        let (context, _) = try seededLibrary()
        var file = try BackupFile(LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let key = try XCTUnwrap(file.files.keys.first)
        file.files[key]![0] ^= 0xFF  // one flipped byte
        XCTAssertThrowsError(try LibraryBackup.decode(file.encoded()))
    }

    func testFormatOneJSONBackupsStillRestore() throws {
        let (context, page) = try seededLibrary()
        let backup = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacy = try encoder.encode(backup)  // exactly what older versions wrote
        let read = try LibraryBackup.decode(legacy)
        XCTAssertEqual(read.notebooks, backup.notebooks)
        XCTAssertEqual(read.notebooks.first?.pageIDs, [page.linkID])
    }

    func testSyncCapturesWriteTheSameBackup() throws {
        let (context, _) = try seededLibrary()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let portable = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: defaults)
        let structured = try LibraryBackup.capture(context: context, locks: SectionLockStore(), defaults: defaults, structuredHistory: true)
        let a = url(), b = url()
        try portable.write(to: a); try structured.write(to: b)
        XCTAssertEqual(try LibraryBackup.read(from: a).notebooks, try LibraryBackup.read(from: b).notebooks, "same file either way")
    }
}
