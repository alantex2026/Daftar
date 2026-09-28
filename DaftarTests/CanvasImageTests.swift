import XCTest
import AppKit
import SwiftUI
import SwiftData
@testable import Daftar

@MainActor
final class CanvasImageTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    private func harness() -> (EditorController, DaftarTextView, ImageCanvas) {
        let storage = NSTextStorage()
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)); lm.addTextContainer(tc)
        let tv = DaftarTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: tc)
        tv.allowsUndo = true
        let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = tv; windows.append(window)
        let controller = EditorController(); controller.textView = tv; tv.controller = controller
        let canvas = ImageCanvas(host: tv, storage: storage, controller: controller) { [weak tv] in tv.map { [$0] } ?? [] }
        tv.imageCanvas = canvas
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); image.unlockFocus()
        controller.insertImage(data: image.tiffRepresentation!, filename: "sample.tiff")
        tv.setSelectedRange(NSRange(location: 0, length: 1)); canvas.sync()
        tv.undoManager?.removeAllActions()
        return (controller, tv, canvas)
    }

    func testFloatingPositionAndImageSurviveRTFDRoundTrip() throws {
        let (controller, tv, canvas) = harness()
        withExtendedLifetime(controller) {
            canvas.commit(range: NSRange(location: 0, length: 1), rect: NSRect(x: 245, y: 320, width: 160, height: 80))
        }
        let portable = CanvasImageLayout.portable(tv.textStorage!)
        let data = try portable.data(from: NSRange(location: 0, length: portable.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let restored = try PageContentCodec.richText(data)
        let layout = try XCTUnwrap(CanvasImageLayout(link: restored.attribute(.link, at: 0, effectiveRange: nil)))
        XCTAssertEqual(layout.rect, NSRect(x: 245, y: 320, width: 160, height: 80))
        let attachment = try XCTUnwrap(restored.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(attachment.fileWrapper?.regularFileContents)))
        XCTAssertFalse(attachment.attachmentCell is CanvasImageCell)
    }

    func testUndoRestoresInlineImageAndRedoRestoresPosition() throws {
        let (controller, tv, canvas) = harness()
        let range = NSRange(location: 0, length: 1)
        tv.undoManager?.beginUndoGrouping()
        canvas.commit(range: range, rect: NSRect(x: 200, y: 250, width: 180, height: 90))
        tv.undoManager?.endUndoGrouping()
        tv.undoManager?.undo(); canvas.sync()
        XCTAssertNil(CanvasImageLayout(link: tv.textStorage!.attribute(.link, at: 0, effectiveRange: nil)))
        let restored = try XCTUnwrap(tv.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertFalse(restored.attachmentCell is CanvasImageCell)
        XCTAssertGreaterThan(restored.bounds.width, 0)
        tv.undoManager?.redo(); canvas.sync()
        XCTAssertEqual(CanvasImageLayout(link: tv.textStorage!.attribute(.link, at: 0, effectiveRange: nil))?.rect.minX, 200)
        withExtendedLifetime(controller) {}
    }

    func testResizeAnchorsOppositeCornerAndUsesVerticalDelta() {
        let original = NSRect(x: 200, y: 200, width: 200, height: 100)
        let resized = CanvasImageLayout.resized(original, handle: .topLeft, delta: NSPoint(x: -40, y: -20))
        XCTAssertEqual(resized.maxX, original.maxX)
        XCTAssertEqual(resized.maxY, original.maxY)
        XCTAssertEqual(resized.width / resized.height, 2)
        XCTAssertEqual(resized.width, 240)
        let vertical = CanvasImageLayout.resized(original, handle: .bottomRight, delta: NSPoint(x: 0, y: 50))
        XCTAssertGreaterThan(vertical.width, original.width)
    }

    func testDragAtTwoTimesZoomUsesStableCanvasCoordinates() throws {
        let (controller, tv, canvas) = harness()
        let scroll = NSScrollView(frame: tv.frame)
        scroll.documentView = tv
        windows[0].contentView = scroll
        scroll.allowsMagnification = true
        scroll.magnification = 2
        canvas.sync()
        let overlay = try XCTUnwrap(tv.subviews.compactMap { $0 as? ImageResizeHandlesView }.first)
        let original = overlay.frame.insetBy(dx: 8, dy: 8)
        let start = NSPoint(x: original.midX, y: original.midY)
        func event(_ type: NSEvent.EventType, dx: CGFloat, dy: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tv.convert(NSPoint(x: start.x + dx, y: start.y + dy), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: windows[0].windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: event(.leftMouseDown, dx: 0, dy: 0))
        overlay.mouseDragged(with: event(.leftMouseDragged, dx: 80, dy: 90))
        overlay.mouseDragged(with: event(.leftMouseDragged, dx: 120, dy: 150))
        overlay.mouseUp(with: event(.leftMouseUp, dx: 120, dy: 150))
        let layout = try XCTUnwrap(CanvasImageLayout(link: tv.textStorage!.attribute(.link, at: 0, effectiveRange: nil)))
        XCTAssertEqual(layout.rect.minX, original.minX + 120, accuracy: 0.5)
        XCTAssertEqual(layout.rect.minY, original.minY + 150, accuracy: 0.5)
        XCTAssertEqual(layout.rect.size, original.size)
        withExtendedLifetime(controller) {}
    }

    @MainActor
    func testActualSaveCallbackKeepsGeometryAndReturnToTextIsUndoable() throws {
        let (controller, tv, canvas) = harness()
        var saved: Data?
        let coordinator = RichTextEditor.Coordinator { data, _, _ in saved = data }
        coordinator.controller = controller; coordinator.imageCanvas = canvas
        tv.delegate = coordinator
        canvas.commit(range: NSRange(location: 0, length: 1), rect: NSRect(x: 160, y: 220, width: 200, height: 100))
        coordinator.flush()
        let decoded = try PageContentCodec.richText(XCTUnwrap(saved))
        XCTAssertEqual(CanvasImageLayout(link: decoded.attribute(.link, at: 0, effectiveRange: nil))?.rect.minY, 220)
        tv.undoManager?.removeAllActions()
        tv.undoManager?.beginUndoGrouping()
        canvas.returnToText(range: NSRange(location: 0, length: 1))
        tv.undoManager?.endUndoGrouping()
        XCTAssertNil(CanvasImageLayout(link: tv.textStorage!.attribute(.link, at: 0, effectiveRange: nil)))
        tv.undoManager?.undo(); canvas.sync()
        XCTAssertNotNil(CanvasImageLayout(link: tv.textStorage!.attribute(.link, at: 0, effectiveRange: nil)))
        coordinator.flush()
    }

    func testDocumentRetainsSheetOccupiedOnlyByFloatingImage() throws {
        let (controller, tv, _) = harness()
        let storage = NSTextStorage(attributedString: tv.textStorage!)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let pages = PaginatedPagesView(layoutManager: lm, textStorage: storage)
        windows[0].contentView = pages
        controller.textView = pages.pages[0]
        pages.configureImageCanvas(controller: controller)
        let canvas = try XCTUnwrap(pages.imageCanvas)
        canvas.commit(range: NSRange(location: 0, length: 1), rect: NSRect(x: 180, y: 900, width: 200, height: 100))
        pages.trimEmptyPages()
        XCTAssertEqual(pages.pages.count, 2)
        XCTAssertTrue(pages.pages.allSatisfy { !$0.usesRolloverButtonForSelection })
        XCTAssertTrue(pages.subviews.last is ImageResizeHandlesView, "New sheets must not cover image overlays")
        let rect = pages.imageRectOnSheet(NSRect(x: 50, y: 780, width: 200, height: 100))
        XCTAssertEqual(rect.maxY, 792)
        XCTAssertEqual(pages.rectForPage(2).minY, 820)
    }

    @MainActor
    func testHostedEditorReopensFloatingImageAndExtendsScrollableCanvas() throws {
        let (controller, source, canvas) = harness()
        canvas.commit(range: NSRange(location: 0, length: 1), rect: NSRect(x: 250, y: 800, width: 240, height: 120))
        let portable = CanvasImageLayout.portable(source.textStorage!)
        let data = try portable.data(from: NSRange(location: 0, length: portable.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let editor = RichTextEditor(initialData: data, controller: controller) { _, _, _ in }
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = hosting; windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let reopened = try XCTUnwrap(controller.textView as? DaftarTextView)
        XCTAssertFalse(reopened === source)
        XCTAssertFalse(reopened.usesRolloverButtonForSelection)
        let image = try XCTUnwrap(reopened.subviews.compactMap { $0 as? ImageResizeHandlesView }.first)
        XCTAssertEqual(image.frame.minY, 792)
        XCTAssertGreaterThanOrEqual(reopened.frame.height, 928)
        XCTAssertGreaterThan(reopened.frame.width, 490)
        reopened.setSelectedRange(NSRange(location: 0, length: 1))
        reopened.imageCanvas?.sync()
        let bitmap = try XCTUnwrap(reopened.bitmapImageRepForCachingDisplay(in: reopened.bounds))
        reopened.cacheDisplay(in: reopened.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Floating image restored on canvas"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForSave(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "Autosave should run without a manual flush")
    }

    @MainActor
    func testResizeGestureAutosavesToDiskAndReopensFinalImage() throws {
        let (controller, tv, canvas) = harness()
        let previousDelay = controller.autoSaveDelay
        controller.autoSaveDelay = 0.05
        defer { controller.autoSaveDelay = previousDelay }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.store")
        let container = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self, configurations: ModelConfiguration(url: url))
        let context = ModelContext(container); context.autosaveEnabled = false
        let page = Page(title: "Resized image"); context.insert(page)
        var saves = 0
        let coordinator = RichTextEditor.Coordinator { data, plain, links in
            try PageHistory.capture(page)
            page.contentData = data; page.plainText = plain; page.outgoingLinkIDs = links
            page.updatedAt = Date()
            try context.save()
            saves += 1
        }
        coordinator.controller = controller; coordinator.imageCanvas = canvas; tv.delegate = coordinator
        let image = try XCTUnwrap(tv.subviews.compactMap { $0 as? ImageResizeHandlesView }.first)
        let original = image.frame.insetBy(dx: 8, dy: 8)
        func event(_ type: NSEvent.EventType, _ dx: CGFloat, _ dy: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tv.convert(NSPoint(x: original.maxX + dx, y: original.maxY + dy), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: windows[0].windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        image.mouseDown(with: event(.leftMouseDown, 0, 0))
        image.mouseDragged(with: event(.leftMouseDragged, 40, 20))
        image.mouseDragged(with: event(.leftMouseDragged, 80, 40))
        let finalRect = image.frame.insetBy(dx: 8, dy: 8)
        image.mouseUp(with: event(.leftMouseUp, 80, 40))
        XCTAssertGreaterThan(finalRect.width, original.width)
        waitForSave { saves == 1 }
        XCTAssertEqual(controller.saveState, .saved)
        let reopened = try ModelContainer(for: Notebook.self, NoteSection.self, Page.self, configurations: ModelConfiguration(url: url))
        let restored = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<Page>()).first)
        let text = try PageContentCodec.richText(restored.contentData)
        XCTAssertEqual(CanvasImageLayout(link: text.attribute(.link, at: 0, effectiveRange: nil))?.rect, finalRect)
        let attachment = try XCTUnwrap(text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(attachment.fileWrapper?.regularFileContents)))
    }

    @MainActor
    func testPageSwitchFlushesLastImageEditWithoutUpdatingNewPageSaveState() throws {
        let (controller, tv, canvas) = harness()
        let delay = controller.autoSaveDelay; controller.autoSaveDelay = 30
        defer { controller.autoSaveDelay = delay }
        var saved: Data?
        let coordinator = RichTextEditor.Coordinator { data, _, _ in saved = data }
        coordinator.controller = controller; coordinator.imageCanvas = canvas; tv.delegate = coordinator
        let rect = NSRect(x: 120, y: 140, width: 320, height: 160)
        canvas.commit(range: NSRange(location: 0, length: 1), rect: rect)
        XCTAssertNil(saved)
        let nextPage = NSTextView(); controller.textView = nextPage; controller.saveState = .idle
        let scroll = NSScrollView(); scroll.documentView = tv
        RichTextEditor.dismantleNSView(scroll, coordinator: coordinator)
        let text = try PageContentCodec.richText(XCTUnwrap(saved))
        XCTAssertEqual(CanvasImageLayout(link: text.attribute(.link, at: 0, effectiveRange: nil))?.rect, rect)
        XCTAssertTrue(controller.textView === nextPage)
        XCTAssertEqual(controller.saveState, .idle)
    }

    @MainActor
    func testFailedImageAutosaveRetriesLatestEditAndAutosavesDeletionUndo() throws {
        let (controller, tv, canvas) = harness()
        let delay = controller.autoSaveDelay; controller.autoSaveDelay = 0.02
        defer { controller.autoSaveDelay = delay }
        var fail = true
        var saved: Data?
        let coordinator = RichTextEditor.Coordinator { data, _, _ in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            saved = data
        }
        coordinator.controller = controller; coordinator.imageCanvas = canvas; tv.delegate = coordinator
        let range = NSRange(location: 0, length: 1)
        canvas.commit(range: range, rect: NSRect(x: 10, y: 20, width: 300, height: 150))
        waitForSave { coordinator.autosaver.state == .failed }
        XCTAssertNil(saved)
        let latest = NSRect(x: 10, y: 20, width: 360, height: 180)
        canvas.commit(range: range, rect: latest)
        fail = false
        waitForSave { coordinator.autosaver.state == .saved }
        let text = try PageContentCodec.richText(XCTUnwrap(saved))
        XCTAssertEqual(CanvasImageLayout(link: text.attribute(.link, at: 0, effectiveRange: nil))?.rect, latest)
        tv.undoManager?.removeAllActions()
        tv.undoManager?.beginUndoGrouping(); canvas.delete(range: range); tv.undoManager?.endUndoGrouping()
        waitForSave { coordinator.autosaver.state == .saved }
        XCTAssertEqual(try PageContentCodec.richText(XCTUnwrap(saved)).length, 0)
        tv.undoManager?.undo()
        waitForSave { coordinator.autosaver.state == .saved }
        XCTAssertEqual(try PageContentCodec.richText(XCTUnwrap(saved)).length, 1)
    }

    @MainActor
    func testDocumentImageEditTriggersAutosaveTimer() throws {
        let (controller, source, _) = harness()
        let delay = controller.autoSaveDelay; controller.autoSaveDelay = 0.02
        defer { controller.autoSaveDelay = delay }
        let storage = NSTextStorage(attributedString: source.textStorage!)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let pages = PaginatedPagesView(layoutManager: lm, textStorage: storage)
        windows[0].contentView = pages
        controller.textView = pages.pages[0]; pages.configureImageCanvas(controller: controller)
        var saved: Data?
        let coordinator = PaginatedTextEditor.Coordinator { data, _, _ in saved = data }
        coordinator.controller = controller; coordinator.pagesView = pages
        pages.onTextChange = { coordinator.scheduleSave(storage: storage) }
        let rect = NSRect(x: 80, y: 100, width: 240, height: 120)
        pages.imageCanvas?.commit(range: NSRange(location: 0, length: 1), rect: rect)
        waitForSave { saved != nil }
        let text = try PageContentCodec.richText(XCTUnwrap(saved))
        XCTAssertEqual(CanvasImageLayout(link: text.attribute(.link, at: 0, effectiveRange: nil))?.rect, rect)
        XCTAssertEqual(controller.saveState, .saved)
        pages.onTextChange = nil
    }

    @MainActor
    func testClickToTypePlacesTextAtEmptyCanvasLocationAndAutosavesIndent() throws {
        let (controller, tv, canvas) = harness()
        tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
        tv.allowsCanvasTyping = true
        let delay = controller.autoSaveDelay; controller.autoSaveDelay = 0.02
        defer { controller.autoSaveDelay = delay }
        var saved: Data?
        let coordinator = RichTextEditor.Coordinator { data, _, _ in saved = data }
        coordinator.controller = controller; coordinator.imageCanvas = canvas; tv.delegate = coordinator
        XCTAssertTrue(tv.placeInsertionPointOnCanvas(at: NSPoint(x: 250, y: 240)))
        tv.insertText("Canvas note", replacementRange: tv.selectedRange())
        waitForSave { coordinator.autosaver.state == .saved }
        let restored = try PageContentCodec.richText(XCTUnwrap(saved))
        let range = (restored.string as NSString).range(of: "Canvas note")
        XCTAssertNotEqual(range.location, NSNotFound)
        let paragraph = try XCTUnwrap(restored.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.headIndent, 250 - tv.textContainerOrigin.x, accuracy: 1)
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let rect = tv.layoutManager!.boundingRect(forGlyphRange: tv.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tv.textContainer!)
        XCTAssertEqual(rect.minX + tv.textContainerOrigin.x, 250, accuracy: 8)
        XCTAssertEqual(rect.minY + tv.textContainerOrigin.y, 240, accuracy: 25)
    }

    func testCanvasTypingPreservesExistingTextAndSupportsEmptyLines() {
        let (controller, tv, _) = harness()
        tv.allowsCanvasTyping = true
        tv.textStorage?.setAttributedString(NSAttributedString(string: "Existing note 😀\n\nLast line", attributes: [.font: EditorController.defaultFont]))
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        XCTAssertFalse(tv.placeInsertionPointOnCanvas(at: NSPoint(x: tv.textContainerOrigin.x + 8, y: tv.textContainerOrigin.y + 5)))
        XCTAssertTrue(tv.placeInsertionPointOnCanvas(at: NSPoint(x: 180, y: 250)))
        tv.insertText("New text", replacementRange: tv.selectedRange())
        XCTAssertTrue(tv.string.hasPrefix("Existing note 😀\n\nLast line"))
        XCTAssertTrue(tv.string.hasSuffix("New text"))
        withExtendedLifetime(controller) {}
    }

    func testTypingToRightOfExistingLineUsesClickedHorizontalPosition() {
        let (controller, tv, _) = harness()
        tv.allowsCanvasTyping = true
        tv.textStorage?.setAttributedString(NSAttributedString(string: "Left 😀", attributes: [.font: EditorController.defaultFont]))
        XCTAssertTrue(tv.placeInsertionPointOnCanvas(at: NSPoint(x: 320, y: tv.textContainerOrigin.y + 5)))
        tv.insertText("Right", replacementRange: tv.selectedRange())
        XCTAssertTrue(tv.string.hasPrefix("Left 😀"))
        let range = (tv.string as NSString).range(of: "Right")
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let rect = tv.layoutManager!.boundingRect(forGlyphRange: tv.layoutManager!.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tv.textContainer!)
        XCTAssertEqual(rect.minX + tv.textContainerOrigin.x, 320, accuracy: 8)
        withExtendedLifetime(controller) {}
    }

    func testCanvasTypingDoesNotAffectDocumentPagesOrReadOnlyNotes() {
        let (controller, tv, _) = harness()
        let original = tv.string
        XCTAssertFalse(tv.placeInsertionPointOnCanvas(at: NSPoint(x: 100, y: 300)))
        tv.allowsCanvasTyping = true; tv.isEditable = false
        XCTAssertFalse(tv.placeInsertionPointOnCanvas(at: NSPoint(x: 100, y: 300)))
        XCTAssertEqual(tv.string, original)
        withExtendedLifetime(controller) {}
    }

    func testRejectsMalformedAndNonFiniteGeometry() {
        XCTAssertNil(CanvasImageLayout(link: "daftar-image://canvas?x=nan&y=0&w=200&h=100"))
        XCTAssertNil(CanvasImageLayout(link: "daftar-image://canvas?x=0&y=0&w=-2&h=100"))
        XCTAssertNil(CanvasImageLayout(link: "https://example.com"))
    }

    func testFloatingImageDoesNotReserveItsHeightInTextLayout() throws {
        let (controller, tv, canvas) = harness()
        canvas.commit(range: NSRange(location: 0, length: 1), rect: NSRect(x: 300, y: 400, width: 200, height: 100))
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
        XCTAssertLessThan(used.height, 60)
        XCTAssertEqual(tv.subviews.compactMap { $0 as? ImageResizeHandlesView }.first?.frame.minY, 392)
        withExtendedLifetime(controller) {}
    }
}
