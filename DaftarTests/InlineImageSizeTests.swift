import XCTest
import AppKit
@testable import Daftar

/// Inline pictures must be *laid out* at the chosen size - checking
/// `attachment.bounds` alone is what let this bug through before.
@MainActor
final class InlineImageSizeTests: XCTestCase {
    private func png(_ w: Int, _ h: Int) -> Data {
        let image = NSImage(size: NSSize(width: w, height: h)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private struct Editor { let controller: EditorController; let textView: DaftarTextView; let canvas: ImageCanvas; let window: NSWindow }

    /// An editor like the app's: text view + image canvas, optionally opening saved RTFD.
    private func makeEditor(_ saved: Data? = nil) throws -> Editor {
        let storage = NSTextStorage(attributedString: try PageContentCodec.richText(saved))
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 800, height: 1e7)); lm.addTextContainer(tc)
        let tv = DaftarTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: tc)
        let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = tv
        let controller = EditorController(); controller.textView = tv; tv.controller = controller
        let canvas = ImageCanvas(host: tv, storage: storage, controller: controller) { [weak tv] in tv.map { [$0] } ?? [] }
        tv.imageCanvas = canvas
        canvas.sync()  // what the editor does after loading a page
        return Editor(controller: controller, textView: tv, canvas: canvas, window: window)
    }

    private func laidOut(_ tv: NSTextView, at index: Int = 0) -> NSSize {
        let lm = tv.layoutManager!, tc = tv.textContainer!; lm.ensureLayout(for: tc)
        return lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: tc).size
    }

    private func saved(_ tv: NSTextView) throws -> Data { try PageContentCodec.rtfd(CanvasImageLayout.portable(tv.textStorage!)) }

    func testMenuResizeShowsImmediatelyWithoutDragging() throws {
        let e = try makeEditor()
        e.controller.insertImage(data: png(400, 200), filename: "a.png")
        XCTAssertEqual(laidOut(e.textView).width, 400, accuracy: 0.5)
        e.controller.setImageSize(at: NSRange(location: 0, length: 1), to: .small)   // 25% of 800
        XCTAssertEqual(laidOut(e.textView).width, 200, accuracy: 0.5)
        XCTAssertEqual(laidOut(e.textView).height, 100, accuracy: 0.5)
        XCTAssertNil(CanvasImageLayout(link: e.textView.textStorage!.attribute(.link, at: 0, effectiveRange: nil)), "stays inline, not floated")
    }

    func testResizeWorksOnPicturesInAnOpenedPageAndIsSaved() throws {
        let first = try makeEditor()
        first.controller.insertImage(data: png(400, 200), filename: "a.png")
        let opened = try makeEditor(saved(first.textView))            // reopen the page
        opened.controller.setImageSize(at: NSRange(location: 0, length: 1), to: .small)
        XCTAssertEqual(laidOut(opened.textView).width, 200, accuracy: 0.5, "works before any drag")
        let reopened = try makeEditor(saved(opened.textView))          // reopen again
        XCTAssertEqual(laidOut(reopened.textView).width, 200, accuracy: 0.5, "size survives save and reopen")
    }

    func testDefaultInsertSizeIsActuallyShown() throws {
        let key = AppSettings.defaultImageSize
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(InsertedImageSize.small.rawValue, forKey: key)
        let e = try makeEditor()
        e.controller.insertImage(data: png(400, 200), filename: "a.png")
        XCTAssertEqual(laidOut(e.textView).width, 200, accuracy: 0.5, "Small (50%) of a 400 pt picture")
        XCTAssertEqual(laidOut(try makeEditor(saved(e.textView)).textView).width, 200, accuracy: 0.5)
    }

    func testTextTypedAfterAResizedPictureIsNotALink() throws {
        let e = try makeEditor()
        e.controller.insertImage(data: png(400, 200), filename: "a.png")
        e.controller.setImageSize(at: NSRange(location: 0, length: 1), to: .small)
        e.textView.setSelectedRange(NSRange(location: 1, length: 0))
        e.canvas.sync()
        e.textView.insertText("caption", replacementRange: e.textView.selectedRange())
        XCTAssertNil(e.textView.textStorage!.attribute(.link, at: 2, effectiveRange: nil))
    }

    func testUndoRestoresTheSizeOnScreen() throws {
        let e = try makeEditor()
        e.textView.allowsUndo = true
        e.controller.insertImage(data: png(400, 200), filename: "a.png")
        e.textView.undoManager?.removeAllActions()
        e.controller.setImageSize(at: NSRange(location: 0, length: 1), to: .small)
        XCTAssertEqual(laidOut(e.textView).width, 200, accuracy: 0.5)
        e.textView.undoManager?.undo()
        e.canvas.sync()
        XCTAssertEqual(laidOut(e.textView).width, 400, accuracy: 0.5)
    }

    func testSizeLinkRejectsNonsense() {
        XCTAssertEqual(InlineImageSize.size(from: InlineImageSize.url(for: NSSize(width: 120, height: 60))), NSSize(width: 120, height: 60))
        XCTAssertNil(InlineImageSize.size(from: "daftar-image://inline?w=0&h=10"))
        XCTAssertNil(InlineImageSize.size(from: "daftar-image://inline?w=nan&h=10"))
        XCTAssertNil(InlineImageSize.size(from: "daftar-image://canvas?x=0&y=0&w=10&h=10"))
        XCTAssertNil(CanvasImageLayout(link: InlineImageSize.url(for: NSSize(width: 10, height: 10))), "inline pictures never float")
    }

    func testCaretBesideAPictureIsTextHeight() throws {
        let e = try makeEditor()
        e.controller.insertImage(data: png(400, 300), filename: "a.png")
        let tv = e.textView
        let font = (tv.typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        let lineHeight = ceil(tv.layoutManager!.defaultLineHeight(for: font))
        // The rect AppKit hands us beside a 300 pt picture spans the whole line.
        let tall = NSRect(x: 402, y: 0, width: 1, height: 305)
        let caret = tv.textHeightCaret(tall)
        XCTAssertEqual(caret.height, lineHeight, accuracy: 0.5)
        XCTAssertEqual(caret.maxY, tall.maxY, accuracy: 0.5, "sits at the bottom, on the text's baseline")
        XCTAssertEqual(caret.minX, tall.minX)
        let normal = NSRect(x: 10, y: 320, width: 1, height: lineHeight)
        XCTAssertEqual(tv.textHeightCaret(normal), normal, "ordinary lines are untouched")
    }
}
