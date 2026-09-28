//  RichTextEditor.swift
//
//  SwiftUI does not have a full rich-text editor yet, so we borrow the one
//  macOS already has (NSTextView) and wrap it so SwiftUI can use it.
//  `NSViewRepresentable` is the official bridge between AppKit and SwiftUI.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A text editor with image selection, positioning, and keyboard movement.
/// Images that arrive via paste or
/// drag-and-drop are routed through the same size-clamped, multi-file-aware
/// path as the toolbar's Insert Image button (`EditorController.insertImage`),
/// instead of AppKit's default handling - which drops an image in at its
/// full native pixel size, large enough to blow out the whole page's layout.
final class DaftarTextView: NSTextView {
    var allowsCanvasTyping = false
    weak var controller: EditorController?

    weak var imageCanvas: ImageCanvas?
    private var imageDragRange: NSRange?
    private var isPlacingCanvasCaret = false

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .fileURL:
            guard let items = pboard.pasteboardItems else { break }
            let imageURLs: [URL] = items.compactMap { item in
                guard let urlString = item.string(forType: .fileURL), let url = URL(string: urlString),
                      let uttype = UTType(filenameExtension: url.pathExtension), uttype.conforms(to: .image) else { return nil }
                return url
            }
            guard !imageURLs.isEmpty else { break }
            controller?.insertImages(from: imageURLs)
            return true
        case .tiff, .png:
            guard let data = pboard.data(forType: type), NSImage(data: data) != nil else { break }
            controller?.insertImage(data: data, filename: type == .png ? "Pasted Image.png" : "Pasted Image.tiff")
            return true
        default:
            break
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Clicking squarely on an inline image selects it as a one-character
    /// range (rather than just dropping the caret next to it), which is
    /// what lets `ImageResizeHandlesView` pick it up and show its resize
    /// handles.
    override func mouseDown(with event: NSEvent) {
        isPlacingCanvasCaret = false
        let point = convert(event.locationInWindow, from: nil)
        if let range = imageAttachmentRange(at: point) {
            controller?.textView = self
            imageDragRange = range
            setSelectedRange(range)
            window?.makeFirstResponder(self)
            imageCanvas?.sync()
            imageCanvas?.beginInlineDrag(range: range, event: event)
            return
        }
        imageDragRange = nil
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           placeInsertionPointOnCanvas(at: point) {
            isPlacingCanvasCaret = true
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isPlacingCanvasCaret { return }
        if let range = imageDragRange { imageCanvas?.dragInline(range: range, event: event); return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isPlacingCanvasCaret { isPlacingCanvasCaret = false; return }
        if let range = imageDragRange {
            imageCanvas?.endInlineDrag(range: range, event: event)
            imageDragRange = nil
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let range = selectedRange()
        if range.length == 1, let storage = textStorage, range.location < storage.length,
           var layout = CanvasImageLayout(link: storage.attribute(.link, at: range.location, effectiveRange: nil)) {
            if event.keyCode == 53 { setSelectedRange(NSRange(location: NSMaxRange(range), length: 0)); return }
            if (123...126).contains(event.keyCode), !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option) {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123: layout.rect.origin.x = max(0, layout.rect.minX - step)
                case 124: layout.rect.origin.x += step
                case 125: layout.rect.origin.y += step
                default: layout.rect.origin.y = max(0, layout.rect.minY - step)
                }
                imageCanvas?.commit(range: range, rect: layout.rect)
                return
            }
        }
        if event.keyCode == 123 || event.keyCode == 124,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           nudgeCanvasCaret(forward: event.keyCode == 124, large: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }

    private func imageAttachmentRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              container.size.width > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length,
              let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment,
              EditorController.isImageAttachment(attachment, at: charIndex, in: storage) else { return nil }
        var range = NSRange(location: 0, length: 0)
        _ = storage.attribute(.attachment, at: charIndex, effectiveRange: &range)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect.contains(point) ? range : nil
    }
}

struct RichTextEditor: NSViewRepresentable {

    /// The saved text of the page (RTFD data), loaded once when the view is created.
    let initialData: Data?

    /// Shared remote control used by the toolbar.
    @ObservedObject var controller: EditorController
    var pageID: UUID? = nil

    /// Called a moment after the user stops typing, so we can save. The
    /// third value is every other-page link found in the saved text, used
    /// to keep `Page.outgoingLinkIDs` (and so Linked Mentions) up to date.
    var onChange: (Data, String, [UUID]) throws -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    // Build the real macOS view.
    func makeNSView(context: Context) -> NSScrollView {
        PerfLog.mark("RichTextEditor.makeNSView START")
        defer { PerfLog.mark("RichTextEditor.makeNSView END") }
        // Built by hand (rather than the NSTextView.scrollableTextView()
        // convenience) so the document view can be our DaftarTextView
        // subclass, which is what lets paste/drag-drop route images
        // through EditorController's size-clamped insert path.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = DaftarTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.controller = controller
        textView.allowsCanvasTyping = true

        let canvas = ImageCanvas(host: textView, storage: textStorage, controller: controller) { [weak textView] in
            textView.map { [$0] } ?? []
        }
        context.coordinator.imageCanvas = canvas
        textView.imageCanvas = canvas
        canvas.onExtentChange = { [weak textView] _ in textView?.updateCanvasExtent() }

        let scrollView = NoteCanvasScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.importsGraphics = true
        // Off: ImageResizeHandlesView replaces AppKit's single built-in
        // resize handle with a full 8-handle selection UI.
        textView.allowsImageEditing = false
        // Disable the macOS image-extension rollover button (including Markup).
        textView.usesRolloverButtonForSelection = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = controller.spellCheckOn
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 46, height: 20)
        textView.font = EditorController.defaultFont
        textView.textColor = NSColor.textColor
        textView.typingAttributes = [
            .font: EditorController.defaultFont,
            .foregroundColor: NSColor.textColor
        ]

        // Full inline Writing Tools (proofread, rewrite, summarize), preserving
        // rich text formatting rather than flattening rewrites to plain text.
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table]
        }

        // Load the saved text of this page.
        var loadFailed = false
        if let data = initialData {
            PerfLog.measure("  RTFD decode (\(data.count) bytes)") {
                do {
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.rtfd],
                        documentAttributes: nil)
                    textView.textStorage?.setAttributedString(attributed)
                } catch {
                    loadFailed = true
                }
            }
        }
        canvas.sync()
        // Self-healing: makes checklist glyphs clickable even if they got
        // there some other way than EditorController.toggleChecklist - a
        // Markdown import, or content from before this feature existed.
        if let storage = textView.textStorage, storage.length > 0 {
            EditorController.markChecklistGlyphs(in: NSRange(location: 0, length: storage.length), storage: storage)
        }

        textView.isEditable = !loadFailed
        context.coordinator.controller = controller
        context.coordinator.pageID = pageID
        if let pageID {
            textView.setSelectedRange(NSRange(location: min(SessionStore.cursor(pageID), textView.string.utf16.count), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        // Done a tick later so we never change SwiftUI state while it is drawing.
        DispatchQueue.main.async {
            controller.textView = textView
            controller.refreshCounts()
            controller.refreshState()
            controller.saveState = .idle
            if loadFailed {
                controller.errorMessage = "This page's saved content couldn't be read. It may be damaged."
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if abs(scrollView.magnification - CGFloat(controller.zoom)) > 0.001 {
            scrollView.magnification = CGFloat(controller.zoom)
        }
        if let textView = scrollView.documentView as? NSTextView,
           controller.textView !== textView {
            controller.textView = textView
        }
        // Keeps the resize handles tracking their image through anything
        // that reflows the text without also changing the selection or
        // editing it directly - a window resize being the main case.
        if let textView = scrollView.documentView as? NSTextView {
            context.coordinator.updateImageHandles(in: textView)
        }
        // Without this, opening a page never gives the text view first
        // responder status - the very first keystroke or paste lands on
        // whatever previously held focus (e.g. a sidebar row) and is
        // silently dropped, only working on a second attempt once the
        // user's own click has fixed it up. A single attempt right after
        // makeNSView isn't reliable because the scroll view isn't always
        // attached to a window yet at that point (it depends on SwiftUI's
        // transition/animation timing) - so keep retrying on every update
        // pass, which fires again as soon as the view is actually in a
        // window, until it succeeds once.
        if !context.coordinator.didFocusOnAppear,
           let window = scrollView.window,
           let textView = scrollView.documentView as? NSTextView {
            context.coordinator.didFocusOnAppear = true
            window.makeFirstResponder(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    /// Called when the view goes away (for example when you switch pages).
    /// We save straight away so nothing is lost.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        PerfLog.measure("RichTextEditor.dismantleNSView (flush)") { coordinator.flush() }
        if coordinator.controller?.textView === nsView.documentView {
            coordinator.controller?.textView = nil
        }
    }

    // MARK: - Coordinator: listens to the text view

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let autosaver: RichTextAutosaver
        weak var controller: EditorController? { didSet { linkRouter.controller = controller } }
        var pageID: UUID?
        var imageCanvas: ImageCanvas?
        let linkRouter = EditorLinkRouter()
        private var pendingEditLocation: Int?
        /// Set once `updateNSView` has successfully claimed first responder
        /// for a newly opened page, so we don't keep stealing focus back
        /// from e.g. the title field on every later SwiftUI update pass.
        var didFocusOnAppear = false

        init(onChange: @escaping (Data, String, [UUID]) throws -> Void) {
            autosaver = RichTextAutosaver(onChange: onChange)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            linkRouter.handle(link, at: charIndex, in: textView)
        }

        /// Remember where an edit (typed or pasted) is about to start, so
        /// `textDidChange` can tell exactly what text just landed.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            pendingEditLocation = affectedCharRange.location
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            normalizeColorOfLastEdit(in: textView)
            controller?.snapRecentlyResizedImages()
            updateImageHandles(in: textView)
            controller?.scheduleCountsRefresh()
            controller?.saveState = .saving
            scheduleSave(for: textView)
        }

        // MARK: - Image resize handles

        /// Shows (and positions) the resize handles over the selected
        /// image, or hides them if the selection isn't a single image -
        /// called after every selection change, edit, and SwiftUI update
        /// pass so the handles never drift from the image they belong to.
        func updateImageHandles(in textView: NSTextView) {
            imageCanvas?.sync()
        }

        // MARK: - Image context menu

        /// Right-clicking an inline image adds Size, Alignment, and Remove
        /// actions ahead of the standard text menu.
        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length else { return menu }
            var range = NSRange(location: charIndex, length: 1)
            guard let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: &range) as? NSTextAttachment,
                  EditorController.isImageAttachment(attachment, at: charIndex, in: storage) else { return menu }

            menu.insertItem(.separator(), at: 0)

            let removeItem = NSMenuItem(title: String(localized: "Remove Image"), action: #selector(removeImage(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = range
            menu.insertItem(removeItem, at: 0)

            let alignMenu = NSMenu()
            for (title, alignment) in [(String(localized: "Left"), NSTextAlignment.left),
                                        (String(localized: "Center"), .center),
                                        (String(localized: "Right"), .right)] {
                let item = NSMenuItem(title: title, action: #selector(setImageAlignment(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (range, alignment)
                alignMenu.addItem(item)
            }
            let alignItem = NSMenuItem(title: String(localized: "Alignment"), action: nil, keyEquivalent: "")
            alignItem.submenu = alignMenu
            menu.insertItem(alignItem, at: 0)

            let sizeMenu = NSMenu()
            for preset in EditorController.ImageSizePreset.allCases {
                let item = NSMenuItem(title: preset.title, action: #selector(setImageSize(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (range, preset)
                sizeMenu.addItem(item)
            }
            let sizeItem = NSMenuItem(title: String(localized: "Image Size"), action: nil, keyEquivalent: "")
            sizeItem.submenu = sizeMenu
            menu.insertItem(sizeItem, at: 0)

            return menu
        }

        @objc private func setImageSize(_ sender: NSMenuItem) {
            guard let (range, preset) = sender.representedObject as? (NSRange, EditorController.ImageSizePreset) else { return }
            controller?.setImageSize(at: range, to: preset)
        }

        @objc private func setImageAlignment(_ sender: NSMenuItem) {
            guard let (range, alignment) = sender.representedObject as? (NSRange, NSTextAlignment) else { return }
            controller?.setImageAlignment(at: range, to: alignment)
        }

        @objc private func removeImage(_ sender: NSMenuItem) {
            guard let range = sender.representedObject as? NSRange else { return }
            controller?.removeImage(at: range)
        }

        /// Text pasted from another app brings its own color along (almost
        /// always a literal black) instead of adapting to the editor's
        /// theme the way typed text does. Force whatever was just inserted
        /// to the same adaptive color typing already uses.
        private func normalizeColorOfLastEdit(in textView: NSTextView) {
            guard let storage = textView.textStorage,
                  let start = pendingEditLocation else { return }
            pendingEditLocation = nil
            let end = textView.selectedRange().location
            guard end > start, end <= storage.length else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                  range: NSRange(location: start, length: end - start))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let pageID, let textView = notification.object as? NSTextView {
                SessionStore.saveCursor(textView.selectedRange().location, id: pageID)
            }
            controller?.refreshState()
            if let textView = notification.object as? NSTextView {
                updateImageHandles(in: textView)
            }
        }

        /// Wait `controller.autoSaveDelay` seconds after the last keystroke, then save once.
        private func scheduleSave(for textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            autosaver.schedule(storage, controller: controller) { [weak textView] in $0.textView === textView }
        }

        func flush() {
            autosaver.flush()
        }
    }
}
