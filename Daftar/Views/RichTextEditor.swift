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
    /// Mouse-down that placed a canvas caret; replayed if it turns into a drag.
    private var canvasCaretMouseDown: NSEvent?
    /// Caret shown at an empty canvas spot that has not been typed into yet.
    var pendingCanvasPlacement: CanvasPlacement?
    /// True while text arrives from a paste or drop (both read the pasteboard
    /// through `readSelection`), so only that text has its colour normalized -
    /// typed text keeps the colour chosen in the toolbar.
    private(set) var isReadingPasteboard = false

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isReadingPasteboard = true
        defer { isReadingPasteboard = false }
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
        canvasCaretMouseDown = nil
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
            canvasCaretMouseDown = event
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let down = canvasCaretMouseDown {
            let start = convert(down.locationInWindow, from: nil)
            let now = convert(event.locationInWindow, from: nil)
            guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
            // A real drag from empty paper: select text as usual. AppKit's
            // mouseDown runs its own tracking loop for the rest of the drag.
            canvasCaretMouseDown = nil
            clearPendingCanvasPlacement()
            super.mouseDown(with: down)
            return
        }
        if let range = imageDragRange { imageCanvas?.dragInline(range: range, event: event); return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if canvasCaretMouseDown != nil { canvasCaretMouseDown = nil; return }
        if let range = imageDragRange {
            imageCanvas?.endInlineDrag(range: range, event: event)
            imageDragRange = nil
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: - Caret beside pictures

    /// Next to an inline picture the line is as tall as the picture, and AppKit
    /// sizes the caret to the whole line: a tall bar flashing beside the image.
    /// Draw it at text height on the baseline instead, as Pages and Notes do.
    /// (A subclass overriding this also keeps AppKit on this drawing path.)
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if var pending = pendingCanvasCaretRect {
            // A caret placed on empty paper is drawn where it was clicked.
            pending.size.width = rect.width
            super.drawInsertionPoint(in: pending, color: color, turnedOn: flag)
            return
        }
        super.drawInsertionPoint(in: textHeightCaret(rect), color: color, turnedOn: flag)
    }

    // MARK: - Theme

    /// Selection and caret colors from the current color theme.
    func applyTheme() {
        selectedTextAttributes[.backgroundColor] = AppTheme.textSelection
        insertionPointColor = AppTheme.caret ?? .textColor
        // Image selection handles are drawn in the accent color.
        subviews.forEach { $0.needsDisplay = true }
    }

    // MARK: - Pending canvas caret

    /// Any selection change other than placing the caret abandons it.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if let placement = pendingCanvasPlacement,
           ranges.count != 1 || ranges[0].rangeValue != NSRange(location: placement.anchor, length: 0) {
            clearPendingCanvasPlacement()
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { clearPendingCanvasPlacement() }
        return resigned
    }

    /// Edits that did not go through the hooks below (toolbar, undo, …)
    /// make the pending placement stale.
    override func didChangeText() {
        clearPendingCanvasPlacement()
        super.didChangeText()
    }

    /// The replacement range for the first edit at a pending caret: the
    /// placement is written into the note and the edit lands at the click.
    private func rangeAfterPlacingCanvasText(_ range: NSRange) -> NSRange {
        guard let placement = pendingCanvasPlacement else { return range }
        let atAnchor = range.location == NSNotFound || range == NSRange(location: placement.anchor, length: 0)
        guard atAnchor else { clearPendingCanvasPlacement(); return range }
        return materializePendingCanvasPlacement() && range.location != NSNotFound ? selectedRange() : range
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: rangeAfterPlacingCanvasText(replacementRange))
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: rangeAfterPlacingCanvasText(replacementRange))
    }

    override func insertNewline(_ sender: Any?) {
        materializePendingCanvasPlacement()
        if continueListOnNewline() { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        // A tab placed on empty paper keeps its canvas meaning.
        if pendingCanvasPlacement == nil, changeListLevel(by: 1) { return }
        materializePendingCanvasPlacement()
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        // Shift-Tab outdents list items; elsewhere it keeps moving focus back.
        if pendingCanvasPlacement == nil, changeListLevel(by: -1) { return }
        super.insertBacktab(sender)
    }

    override func paste(_ sender: Any?) {
        materializePendingCanvasPlacement()
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        materializePendingCanvasPlacement()
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        materializePendingCanvasPlacement()
        super.pasteAsRichText(sender)
    }

    /// Deleting at a caret that was only shown would remove text the person
    /// can't see next to it, so it just cancels the placement.
    override func deleteBackward(_ sender: Any?) {
        if pendingCanvasPlacement != nil { clearPendingCanvasPlacement(); return }
        if removeListMarkerOnBackspace() { return }
        let joinsLines = deletionJoinsLines()
        super.deleteBackward(sender)
        if joinsLines { renumberLists() }
    }

    override func deleteForward(_ sender: Any?) {
        if pendingCanvasPlacement != nil { clearPendingCanvasPlacement(); return }
        super.deleteForward(sender)
    }

    /// `rect` shrunk to one line of the current font, kept at the bottom of the
    /// line where the text sits. Ordinary lines are left alone.
    func textHeightCaret(_ rect: NSRect) -> NSRect {
        let font = (typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        let lineHeight = ceil(layoutManager?.defaultLineHeight(for: font) ?? (font.ascender - font.descender + font.leading))
        guard rect.height > lineHeight * 1.5 else { return rect }
        // NSTextView is flipped: maxY is the bottom of the line.
        return NSRect(x: rect.minX, y: rect.maxY - lineHeight, width: rect.width, height: lineHeight)
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
    /// Read where the editor is created, so a theme change reaches updateNSView.
    var theme: ColorTheme = ThemeStore.shared.theme

    /// Called a moment after the user stops typing, so we can save. The
    /// third value is every other-page link found in the saved text, used
    /// to keep `Page.outgoingLinkIDs` (and so Linked Mentions) up to date.
    var onChange: (Data, String, [UUID]) throws -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onChange: onChange)
        coordinator.appliedTheme = theme
        return coordinator
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
        textView.applyTheme()

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
            textView.setSelectedRange(NSRange(location: min(SessionStore.latestCursor(pageID), textView.string.utf16.count), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        context.coordinator.textView = textView
        let coordinator = context.coordinator
        // Done a tick later so we never change SwiftUI state while it is drawing.
        DispatchQueue.main.async {
            controller.textView = textView
            controller.refreshCounts()
            controller.refreshState()
            controller.saveState = .idle
            coordinator.applyPendingSearchHighlight()
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
        if context.coordinator.appliedTheme != theme, let textView = scrollView.documentView as? DaftarTextView {
            context.coordinator.appliedTheme = theme
            textView.applyTheme()
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
        // The page is gone: its undo steps must not outlive it.
        coordinator.undoManager.removeAllActions()
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
        var appliedTheme: ColorTheme?
        let linkRouter = EditorLinkRouter()
        /// This page's own undo history. With the window's shared undo manager,
        /// undoing past this page's edits reached pages that were already closed
        /// and silently rewrote (and autosaved) their text.
        let undoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
        weak var textView: NSTextView?
        private var showsSearchHighlight = false
        private var highlightObserver: NSObjectProtocol?

        /// Highlights the search that opened this page (see `SearchHighlight`).
        func applyPendingSearchHighlight() {
            guard let pageID, let textView, let query = SearchHighlight.take(for: pageID) else { return }
            showsSearchHighlight = SearchHighlight.apply(query, to: textView) > 0
        }
        private var pendingEditLocation: Int?
        /// Set once `updateNSView` has successfully claimed first responder
        /// for a newly opened page, so we don't keep stealing focus back
        /// from e.g. the title field on every later SwiftUI update pass.
        var didFocusOnAppear = false

        init(onChange: @escaping (Data, String, [UUID]) throws -> Void) {
            autosaver = RichTextAutosaver(onChange: onChange)
            super.init()
            // A search result for the page that's already open.
            highlightObserver = NotificationCenter.default.addObserver(forName: .daftarHighlightSearch, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let id = note.object as? UUID, id == self.pageID else { return }
                    self.applyPendingSearchHighlight()
                }
            }
        }

        deinit {
            if let highlightObserver { NotificationCenter.default.removeObserver(highlightObserver) }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            linkRouter.handle(link, at: charIndex, in: textView)
        }

        /// Remember where a pasted or dropped edit is about to start, so
        /// `textDidChange` can tell exactly what text just landed.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let pasted = (textView as? DaftarTextView)?.isReadingPasteboard == true
            pendingEditLocation = pasted ? affectedCharRange.location : nil
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if showsSearchHighlight { SearchHighlight.clear(in: textView); showsSearchHighlight = false }
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
                SessionStore.rememberCursor(textView.selectedRange().location, id: pageID)
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
