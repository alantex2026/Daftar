//  PaginatedPagesViewTests.swift
//  Exercises the actual TextKit pagination logic - the highest-risk new
//  code in the Document page type - against a real (off-screen)
//  NSLayoutManager, the same way PaginatedTextEditor wires it up.

import XCTest
import AppKit
@testable import Daftar

/// Stands in for `PaginatedTextEditor.Coordinator`, which is private to
/// that file - forwards the layout manager's completion callback to the
/// pages view exactly the same way.
private final class SpyLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    weak var pagesView: PaginatedPagesView?

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        pagesView?.layoutManagerDidCompleteLayout(for: textContainer, atEnd: layoutFinishedFlag)
    }
}

final class PaginatedPagesViewTests: XCTestCase {

    /// Keeps the offscreen windows created below alive for the duration of
    /// the test run - NSWindow doesn't retain itself, and a deallocated
    /// window pulls its content view (and our pages view) down with it.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// Real production code always hosts `PaginatedPagesView` inside a
    /// window (via the app's real NSScrollView/NSWindow). Forcing heavy
    /// text layout on layer-backed views that were never added to any
    /// window - as a bare, unhosted `PaginatedPagesView` would be here -
    /// isn't a scenario the real app ever hits, and reproduced a crash
    /// in this test harness that a real window doesn't. An offscreen,
    /// never-ordered-front window keeps the test both safe and honest
    /// about the actual code path.
    private func makeHarness() -> (pagesView: PaginatedPagesView, layoutManager: NSLayoutManager, storage: NSTextStorage, delegate: SpyLayoutDelegate) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let delegate = SpyLayoutDelegate()
        layoutManager.delegate = delegate
        textStorage.addLayoutManager(layoutManager)

        let pagesView = PaginatedPagesView(layoutManager: layoutManager, textStorage: textStorage)
        delegate.pagesView = pagesView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                               styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = pagesView
        windows.append(window)

        return (pagesView, layoutManager, textStorage, delegate)
    }

    /// Repeatedly asks the layout manager to finish laying out whatever
    /// the current last page is - each completion may itself grow another
    /// page, so this loops until the page count stops changing. Page
    /// growth itself is deferred to the next run loop turn (see
    /// `PaginatedPagesView.layoutManagerDidCompleteLayout`), so each
    /// iteration briefly runs the run loop to let a pending add happen.
    private func forceFullLayout(_ pagesView: PaginatedPagesView, _ layoutManager: NSLayoutManager) {
        var previousCount = -1
        var iterations = 0
        while pagesView.pages.count != previousCount, iterations < 50 {
            previousCount = pagesView.pages.count
            if let container = pagesView.pages.last?.textContainer {
                layoutManager.ensureLayout(for: container)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            iterations += 1
        }
    }

    func testStartsWithExactlyOnePage() {
        let (pagesView, _, _, _) = makeHarness()
        XCTAssertEqual(pagesView.pages.count, 1)
    }

    func testShortTextStaysOnOnePage() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Just a short note.")
        forceFullLayout(pagesView, layoutManager)
        XCTAssertEqual(pagesView.pages.count, 1)
    }

    func testOverflowingTextGrowsAdditionalPages() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        // A US Letter page's content area is 792 - 2*72 = 648pt tall; at
        // the default font size that's nowhere near enough for 200 lines.
        let longText = Array(repeating: "This is a line of sample text meant to overflow one page.\n", count: 200).joined()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: longText)

        forceFullLayout(pagesView, layoutManager)

        XCTAssertGreaterThan(pagesView.pages.count, 1, "200 lines of text should overflow a single Letter-sized page")
    }

    func testAllPagesShareTheSameUnderlyingTextStorage() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        let longText = Array(repeating: "Line.\n", count: 400).joined()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: longText)
        forceFullLayout(pagesView, layoutManager)

        guard pagesView.pages.count > 1 else {
            XCTFail("expected more than one page for this test to be meaningful")
            return
        }
        // Every page's own .textStorage should be the identical shared
        // object - this is what lets word count/formatting commands work
        // no matter which page's NSTextView currently has focus.
        for page in pagesView.pages {
            XCTAssertTrue(page.textStorage === storage)
        }
    }

    func testPagesAreStackedVerticallyWithAGap() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        let longText = Array(repeating: "Line.\n", count: 400).joined()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: longText)
        forceFullLayout(pagesView, layoutManager)

        guard pagesView.pages.count > 1 else {
            XCTFail("expected more than one page for this test to be meaningful")
            return
        }
        let first = pagesView.pages[0].frame
        let second = pagesView.pages[1].frame
        XCTAssertEqual(second.origin.y, first.maxY + PaginatedTextEditor.pageGap, accuracy: 0.5)
    }
    func testShrinkingDocumentRemovesTrailingEmptyPages() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: String(repeating: "Line.\n", count: 400))
        forceFullLayout(pagesView, layoutManager)
        XCTAssertGreaterThan(pagesView.pages.count, 1)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "Short")
        pagesView.trimEmptyPages()
        forceFullLayout(pagesView, layoutManager)
        XCTAssertEqual(pagesView.pages.count, 1)
    }

    func testPaperSizeChangesKeepTextAndFormatting() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        let font = NSFont.boldSystemFont(ofSize: 24)
        storage.setAttributedString(NSAttributedString(string: "Heading", attributes: [.font: font]))
        pagesView.setPageSize(PaginatedTextEditor.size(for: "a4"))
        forceFullLayout(pagesView, layoutManager)
        XCTAssertEqual(pagesView.pages.first?.frame.width ?? 0, 595.28, accuracy: 0.01)
        XCTAssertEqual(storage.string, "Heading")
        XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
    }

    func testCursorRestoresOnLaterPageAndPrintingIncludesEveryPage() {
        let (pagesView, layoutManager, storage, _) = makeHarness()
        let text = String(repeating: "Line.\n", count: 400)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        pagesView.requestCursorRestore(text.utf16.count - 4)
        forceFullLayout(pagesView, layoutManager)
        XCTAssertNotNil(pagesView.restoredCursorView, "Cursor should resolve after layout across \(pagesView.pages.count) pages")
        XCTAssertFalse(pagesView.restoredCursorView === pagesView.pages.first)
        XCTAssertEqual(pagesView.restoredCursorView?.selectedRange().location, text.utf16.count - 4)
        var range = NSRange()
        XCTAssertTrue(pagesView.knowsPageRange(&range))
        XCTAssertEqual(range.length, pagesView.pages.count)
        XCTAssertEqual(pagesView.rectForPage(range.length), pagesView.pages.last?.frame)
    }

}
