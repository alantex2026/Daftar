import XCTest
import AppKit
@testable import Daftar

/// Undo must stay within the open page. With one undo stack per window,
/// repeated Undo walked into pages that were already closed and autosaved
/// their undone (e.g. empty) text over the real content.
@MainActor
final class UndoIsolationTests: XCTestCase {
    private var window: NSWindow!
    private var container: NSView!
    private let controller = EditorController()

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); window.contentView = container
        controller.autoSaveDelay = 0.01
    }

    private func openPage(_ onSave: @escaping (String) -> Void) -> (DaftarTextView, RichTextEditor.Coordinator) {
        let storage = NSTextStorage(), lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 600, height: 1e7)); lm.addTextContainer(tc)
        let tv = DaftarTextView(frame: container.bounds, textContainer: tc)
        tv.allowsUndo = true
        let coordinator = RichTextEditor.Coordinator { _, plain, _ in onSave(plain) }
        coordinator.controller = controller; tv.delegate = coordinator; tv.controller = controller
        container.addSubview(tv); controller.textView = tv
        return (tv, coordinator)
    }

    private func type(_ tv: NSTextView, _ text: String) {
        tv.undoManager?.beginUndoGrouping()  // one user action = one undo step
        tv.insertText(text, replacementRange: tv.selectedRange())
        tv.undoManager?.endUndoGrouping()
        tv.breakUndoCoalescing()
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testRepeatedUndoNeverReachesAClosedPage() throws {
        var savesA: [String] = []
        var (a, coordinatorA): (DaftarTextView?, RichTextEditor.Coordinator?) = openPage { savesA.append($0) }
        let undoA = try XCTUnwrap(a?.undoManager)
        undoA.groupsByEvent = false
        type(a!, "page A first "); type(a!, "page A second")
        settle(); coordinatorA?.flush()
        let savedA = savesA.last
        XCTAssertEqual(savedA, "page A first page A second")

        // Switch pages the way SwiftUI does: flush, dismantle, open the next.
        RichTextEditor.dismantleNSView(NSScrollView(), coordinator: coordinatorA!)
        a?.removeFromSuperview(); a = nil; coordinatorA = nil
        let (b, coordinatorB) = openPage { _ in }
        let undoB = try XCTUnwrap(b.undoManager)
        XCTAssertFalse(undoB === undoA, "each page has its own undo history")
        undoB.groupsByEvent = false
        type(b, "B1 "); type(b, "B2")

        undoB.undo(); XCTAssertEqual(b.string, "B1 ")
        undoB.undo(); XCTAssertEqual(b.string, "")
        XCTAssertFalse(undoB.canUndo, "undo stops at the start of this page")
        settle()
        XCTAssertEqual(savesA.last, savedA, "page A was never touched or re-saved")
        XCTAssertEqual(savesA.count, 1)
        XCTAssertFalse(undoA.canUndo, "the closed page's undo steps were discarded")
        withExtendedLifetime(coordinatorB) {}
    }

    func testEditMenuUndoUsesThePagesHistory() throws {
        let (tv, coordinator) = openPage { _ in }
        window.makeFirstResponder(tv)
        tv.undoManager?.groupsByEvent = false
        type(tv, "hello")
        XCTAssertTrue(tv.undoManager === coordinator.undoManager)
        // What Edit > Undo (Cmd-Z) does: the window handles undo: using its
        // first responder's undo manager, which is this page's.
        XCTAssertTrue(window.firstResponder === tv)
        XCTAssertTrue(NSApp.sendAction(Selector(("undo:")), to: window, from: nil))
        XCTAssertEqual(tv.string, "")
    }

    func testDocumentPagesHaveTheirOwnHistoryToo() {
        let storage = NSTextStorage(), lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let pages = PaginatedPagesView(layoutManager: lm, textStorage: storage, pageSize: NSSize(width: 612, height: 792))
        container.addSubview(pages)
        let sheet = pages.pages[0]
        XCTAssertTrue(sheet.undoManager === pages.pageUndoManager)
        XCTAssertFalse(sheet.undoManager === window.undoManager)
    }
}
