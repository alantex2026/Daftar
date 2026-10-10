import XCTest
import AppKit
@testable import Daftar

@MainActor
final class ListEditingTests: XCTestCase {
    private func makeTextView(_ text: String = "") -> DaftarTextView {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let textView = DaftarTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        textView.isRichText = true
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        return textView
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Parsing

    func testListLineRecognizesMarkersAndNesting() {
        XCTAssertEqual(ListLine("\u{2022} milk")?.kind, .bullet)
        XCTAssertEqual(ListLine("\t\t12. step\n")?.kind, .numbered(12))
        XCTAssertEqual(ListLine("\t\t12. step\n")?.level, 2)
        XCTAssertEqual(ListLine("\t\t12. step\n")?.markerLength, 6)
        XCTAssertEqual(ListLine("\t\t12. step\n")?.content, "step")
        XCTAssertEqual(ListLine("\u{2611} done")?.kind, .checklist(checked: true))
        XCTAssertEqual(ListLine("1. ")?.content, "")
        XCTAssertNil(ListLine("2024. was a year"), "four digits isn't a list number")
        XCTAssertNil(ListLine("1.5 litres"))
        XCTAssertNil(ListLine("plain text"))
    }

    // MARK: Return

    func testReturnContinuesBulletsAndNumbers() {
        let bullets = makeTextView("\u{2022} one")
        bullets.insertNewline(nil); type("two", into: bullets)
        XCTAssertEqual(bullets.string, "\u{2022} one\n\u{2022} two")

        let numbers = makeTextView("1. one")
        numbers.insertNewline(nil); type("two", into: numbers)
        XCTAssertEqual(numbers.string, "1. one\n2. two")
    }

    func testReturnInTheMiddleOfANumberedListRenumbersTheRest() {
        let textView = makeTextView("1. one\n2. three")
        textView.setSelectedRange(NSRange(location: 6, length: 0))  // end of "one"
        textView.insertNewline(nil); type("two", into: textView)
        XCTAssertEqual(textView.string, "1. one\n2. two\n3. three")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        let textView = makeTextView("\u{2022} one")
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "\u{2022} one\n")
        type("after", into: textView)
        XCTAssertEqual(textView.string, "\u{2022} one\nafter")
    }

    func testReturnOnAnEmptyNestedItemOutdentsIt() {
        let textView = makeTextView("\u{2022} one\n\t\u{2022} ")
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "\u{2022} one\n\u{2022} ")
    }

    func testNewChecklistItemStartsUncheckedWithoutStrikethrough() {
        let textView = makeTextView("\u{2611} done")
        let storage = textView.textStorage!
        storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 2, length: 4))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertNewline(nil); type("next", into: textView)
        XCTAssertEqual(textView.string, "\u{2611} done\n\u{2610} next")
        let strike = storage.attribute(.strikethroughStyle, at: storage.length - 1, effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(strike, 0)
        XCTAssertNotNil(storage.attribute(.link, at: 7, effectiveRange: nil), "the new box is clickable")
    }

    // MARK: Tab, Shift-Tab, Backspace

    func testTabNestsAndShiftTabOutdentsWithRenumbering() {
        let textView = makeTextView("1. a\n2. b\n3. c")
        textView.setSelectedRange(NSRange(location: 9, length: 0))  // end of "b"
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "1. a\n\t2. b\n2. c", "the nested item keeps its number; the outer list continues")
        XCTAssertEqual(textView.selectedRange().location, 10, "the caret moves with the text")
        textView.insertBacktab(nil)
        XCTAssertEqual(textView.string, "1. a\n2. b\n3. c")
    }

    func testTabOutsideAListInsertsATab() {
        let textView = makeTextView("plain")
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "plain\t")
    }

    func testBackspaceAfterMarkerRemovesIt() {
        let textView = makeTextView("\u{2022} item")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "item")
    }

    func testDeletingAnItemRenumbersTheList() {
        let textView = makeTextView("1. a\n2. b\n3. c")
        textView.setSelectedRange(NSRange(location: 4, length: 5))  // "\n2. b"
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "1. a\n2. c")
    }

    func testListsAreUndoableAsEdits() {
        let textView = makeTextView("\u{2022} one")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let delegate = UndoDelegate(undo)
        textView.delegate = delegate
        textView.allowsUndo = true
        undo.beginUndoGrouping(); textView.insertNewline(nil); undo.endUndoGrouping()
        XCTAssertEqual(textView.string, "\u{2022} one\n\u{2022} ")
        undo.undo()
        XCTAssertEqual(textView.string, "\u{2022} one")
    }

    // MARK: Toolbar commands

    func testBulletToggleKeepsNestingAndNumberedToggleCounts() {
        let controller = EditorController()
        let textView = makeTextView("a\n\tb")
        controller.textView = textView
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        controller.toggleBullet(numbered: true)
        XCTAssertEqual(textView.string, "1. a\n\t1. b")
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        controller.toggleBullet(numbered: true)
        XCTAssertEqual(textView.string, "a\n\tb", "pressing again turns the list off")
    }

    // MARK: Headings

    func testHeadingsAreRecognizedByStyleEvenAfterSaving() throws {
        let heading = NSAttributedString(string: "Title", attributes: [.font: EditorController.TextStyle.heading2.font])
        let saved = try PageContentCodec.richText(PageContentCodec.rtfd(heading))
        let font = try XCTUnwrap(saved.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(EditorController.TextStyle.headingLevel(of: font), 2)
        XCTAssertEqual(EditorController.TextStyle.headingLevel(of: EditorController.TextStyle.heading3.font), 3)
        XCTAssertNil(EditorController.TextStyle.headingLevel(of: .systemFont(ofSize: 16)), "plain 16pt text isn't a heading")
        XCTAssertNil(EditorController.TextStyle.headingLevel(of: .boldSystemFont(ofSize: 24)), "only the heading sizes count")
    }

    func testApplyingAStyleKeepsItalics() {
        let controller = EditorController()
        let italic = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        let textView = makeTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(string: "word", attributes: [.font: italic]))
        controller.textView = textView
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        controller.applyStyle(.heading1)
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 26)
        XCTAssertTrue(NSFontManager.shared.traits(of: font!).contains(.italicFontMask))
    }

    // MARK: Markdown

    func testMarkdownExportWritesNestingAndChecklists() {
        let text = NSAttributedString(string: "\u{2022} top\n\t\u{2022} inner\n\u{2610} todo\n\u{2611} done\n\t2. second",
                                      attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, _ in nil })
        XCTAssertEqual(markdown, "- top\n  - inner\n- [ ] todo\n- [x] done\n  2. second\n")
    }

    func testMarkdownImportRestoresNestingAndChecklists() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "- top\n  - inner\n- [ ] todo\n- [x] done")
        XCTAssertEqual(attributed.string, "\u{2022} top\n\t\u{2022} inner\n\u{2610} todo\n\u{2611} done")
    }
}

/// Supplies a test-owned undo manager to a text view.
private final class UndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
