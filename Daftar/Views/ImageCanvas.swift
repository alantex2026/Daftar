import AppKit

/// Owns image overlays in the same document coordinate space as the text.
@MainActor
final class ImageCanvas {
    weak var host: NSView?
    weak var controller: EditorController?
    let storage: NSTextStorage
    var textViews: () -> [NSTextView]
    private var views: [Int: ImageResizeHandlesView] = [:]
    private var imageCache: [ObjectIdentifier: (wrapper: FileWrapper, image: NSImage)] = [:]
    private var updating = false
    private var previewAttachment: (range: NSRange, attachment: NSTextAttachment)?
    var onExtentChange: ((CGFloat) -> Void)?
    var minimumWidth: CGFloat { views.values.filter(\.isFloating).map { $0.frame.maxX }.max() ?? 0 }
    var canEdit: Bool { (controller?.textView ?? textViews().first)?.isEditable == true }
    var extent: CGFloat { views.values.filter(\.isFloating).map { $0.frame.maxY }.max() ?? 0 }

    init(host: NSView, storage: NSTextStorage, controller: EditorController?, textViews: @escaping () -> [NSTextView]) {
        self.host = host; self.storage = storage; self.controller = controller; self.textViews = textViews
    }

    func sync() {
        guard !updating, let host else { return }
        updating = true
        defer { updating = false }
        var live = Set<Int>()
        var liveWrappers = Set<ObjectIdentifier>()
        let selected = (controller?.textView?.textStorage === storage ? controller?.textView?.selectedRange() : nil) ?? NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  EditorController.isImageAttachment(attachment, at: range.location, in: storage) else { return }
            let layout = CanvasImageLayout(link: storage.attribute(.link, at: range.location, effectiveRange: nil))
            let isSelected = selected == range
            guard layout != nil || isSelected, let wrapper = attachment.fileWrapper else { return }
            let wrapperID = ObjectIdentifier(wrapper)
            if imageCache[wrapperID] == nil {
                guard let data = wrapper.regularFileContents, let image = NSImage(data: data) else { return }
                imageCache[wrapperID] = (wrapper, image)
            }
            guard let image = imageCache[wrapperID]?.image else { return }
            liveWrappers.insert(wrapperID)
            let rect: NSRect
            if let layout {
                rect = layout.rect
                if !(attachment.attachmentCell is CanvasImageCell) {
                    attachment.attachmentCell = CanvasImageCell()
                    attachment.bounds = .zero
                    storage.layoutManagers.forEach { $0.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil) }
                }
            } else {
                guard let tv = textViews().first(where: { tv in
                    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return false }
                    return NSLocationInRange(range.location, lm.characterRange(forGlyphRange: lm.glyphRange(for: tc), actualGlyphRange: nil))
                }), let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                var inlineRect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
                inlineRect.origin.x += tv.textContainerOrigin.x
                inlineRect.origin.y += tv.textContainerOrigin.y
                rect = host.convert(inlineRect, from: tv)
            }
            live.insert(range.location)
            let view = views[range.location] ?? ImageResizeHandlesView(frame: .zero)
            if view.superview == nil { host.addSubview(view) }
            views[range.location] = view
            view.canvas = self; view.range = range; view.picture = image
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.image)
            view.setAccessibilityLabel(attachment.fileWrapper?.preferredFilename ?? "Image")
            view.setAccessibilityHelp("Click to select. Drag to move, or drag a handle to resize. Use arrow keys to move the selected image.")
            view.isFloating = layout != nil || view.isDragging; view.isSelected = isSelected
            if !view.isDragging { view.frame = rect.insetBy(dx: -8, dy: -8) }
            view.needsDisplay = true
            host.window?.invalidateCursorRects(for: view)
        }
        for key in Array(views.keys) where !live.contains(key) { views.removeValue(forKey: key)?.removeFromSuperview() }
        imageCache = imageCache.filter { liveWrappers.contains($0.key) }
        for tv in textViews() where CanvasImageLayout(link: tv.typingAttributes[.link]) != nil {
            var attributes = tv.typingAttributes
            attributes.removeValue(forKey: .link)
            tv.typingAttributes = attributes
        }
        onExtentChange?(extent)
    }

    func beginInlineDrag(range: NSRange, event: NSEvent) { views[range.location]?.mouseDown(with: event) }
    func dragInline(range: NSRange, event: NSEvent) { views[range.location]?.mouseDragged(with: event) }
    func endInlineDrag(range: NSRange, event: NSEvent) { views[range.location]?.mouseUp(with: event) }

    func select(_ range: NSRange) {
        guard let tv = controller?.textView ?? textViews().first, tv.isEditable else { return }
        controller?.textView = tv
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        sync()
    }

    func beginPreview(range: NSRange) {
        guard previewAttachment == nil, NSMaxRange(range) <= storage.length,
              CanvasImageLayout(link: storage.attribute(.link, at: range.location, effectiveRange: nil)) == nil,
              let original = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
        previewAttachment = (range, original)
        let hidden = NSTextAttachment(fileWrapper: original.fileWrapper)
        hidden.bounds = original.bounds
        let cell = ImageDragPreviewCell()
        cell.previewSize = original.bounds.size
        hidden.attachmentCell = cell
        storage.addAttribute(.attachment, value: hidden, range: range)
    }

    func endPreview() {
        guard let preview = previewAttachment else { return }
        previewAttachment = nil
        if NSMaxRange(preview.range) <= storage.length {
            storage.addAttribute(.attachment, value: preview.attachment, range: preview.range)
        }
    }

    func returnToText(range: NSRange) {
        guard canEdit, NSMaxRange(range) <= storage.length else { return }
        let content = NSMutableAttributedString(attributedString: CanvasImageLayout.portable(storage.attributedSubstring(from: range)))
        content.removeAttribute(.link, range: NSRange(location: 0, length: content.length))
        replace(range: range, with: content, action: "Place Image in Text")
    }

    /// Explicit attributed replacement avoids NSTextView inheriting a removed
    /// link from typing attributes, and keeps layout outside its editing batch.
    private func replace(range: NSRange, with content: NSAttributedString, action: String) {
        guard let tv = controller?.textView ?? textViews().first, tv.isEditable,
              NSMaxRange(range) <= storage.length,
              tv.shouldChangeText(in: range, replacementString: nil) else { return }
        let before = CanvasImageLayout.portable(storage.attributedSubstring(from: range))
        let afterRange = NSRange(location: range.location, length: content.length)
        tv.breakUndoCoalescing()
        tv.undoManager?.registerUndo(withTarget: self) { target in
            target.replace(range: afterRange, with: before, action: action)
        }
        tv.undoManager?.setActionName(action)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: content)
        storage.endEditing()
        tv.setSelectedRange(afterRange)
        tv.didChangeText()
        sync()
    }

    func delete(range: NSRange) {
        replace(range: range, with: NSAttributedString(string: ""), action: "Delete Image")
    }

    func commit(range: NSRange, rect: NSRect) {
        guard let tv = controller?.textView ?? textViews().first, tv.isEditable,
              NSMaxRange(range) <= storage.length else { return }
        var rect = rect
        rect.origin.x = min(90_000, max(0, rect.minX))
        rect.origin.y = min(90_000, max(0, rect.minY))
        guard rect.width > 0, rect.height > 0, rect.maxX <= 100_000, rect.maxY <= 100_000 else { return }
        if let pages = host as? PaginatedPagesView { rect = pages.imageRectOnSheet(rect) }
        let content = NSMutableAttributedString(attributedString: CanvasImageLayout.portable(storage.attributedSubstring(from: range)))
        content.addAttribute(.link, value: CanvasImageLayout(rect: rect).url, range: NSRange(location: 0, length: content.length))
        replace(range: range, with: content, action: "Move or Resize Image")
    }
}

final class ImageResizeHandlesView: NSView {
    weak var canvas: ImageCanvas?
    var range = NSRange(location: 0, length: 1)
    var picture: NSImage?
    var isFloating = false
    var isSelected = false
    private var dragStart: (point: NSPoint, rect: NSRect, handle: CanvasImageLayout.Handle?)?
    private(set) var isDragging = false
    override var isFlipped: Bool { true }
    private var imageRect: NSRect { bounds.insetBy(dx: 8, dy: 8) }

    private func handleRect(_ handle: CanvasImageLayout.Handle) -> NSRect {
        let u = handle.unit, r = imageRect
        return NSRect(x: r.minX + u.x * r.width - 4, y: r.minY + u.y * r.height - 4, width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isFloating { picture?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        guard isSelected, NSGraphicsContext.current?.isDrawingToScreen != false else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: imageRect); outline.lineWidth = 1; outline.stroke()
        for handle in CanvasImageLayout.Handle.allCases {
            let rect = handleRect(handle)
            NSColor.white.setFill(); NSBezierPath(rect: rect).fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if imageRect.contains(local) { return self }
        if isSelected && CanvasImageLayout.Handle.allCases.contains(where: { handleRect($0).insetBy(dx: -5, dy: -5).contains(local) }) { return self }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: isDragging ? .closedHand : .openHand)
        guard isSelected else { return }
        for handle in CanvasImageLayout.Handle.allCases {
            let u = handle.unit
            let cursor: NSCursor
            if u.x == 0.5 { cursor = .resizeUpDown }
            else if u.y == 0.5 { cursor = .resizeLeftRight }
            else {
                let symbol = u.x == u.y ? "arrow.up.left.and.arrow.down.right" : "arrow.up.right.and.arrow.down.left"
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Resize image") ?? NSImage()
                cursor = NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
            }
            addCursorRect(handleRect(handle).insetBy(dx: -5, dy: -5), cursor: cursor)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        canvas?.select(range)
        let menu = NSMenu()
        for preset in EditorController.ImageSizePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = preset; menu.addItem(item)
        }
        if !isFloating {
            menu.addItem(.separator())
            for (title, alignment) in [("Align Left", NSTextAlignment.left), ("Align Center", .center), ("Align Right", .right)] {
                let item = NSMenuItem(title: title, action: #selector(alignImage(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = alignment; menu.addItem(item)
            }
        }
        if isFloating {
            menu.addItem(.separator())
            let inline = NSMenuItem(title: "Place in Text", action: #selector(placeInText), keyEquivalent: "")
            inline.target = self; menu.addItem(inline)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Delete Image", action: #selector(deleteImage), keyEquivalent: "")
        remove.target = self; menu.addItem(remove)
        return menu
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? EditorController.ImageSizePreset else { return }
        canvas?.controller?.setImageSize(at: range, to: preset)
        canvas?.sync()
    }
    @objc private func alignImage(_ sender: NSMenuItem) {
        guard let alignment = sender.representedObject as? NSTextAlignment else { return }
        canvas?.controller?.setImageAlignment(at: range, to: alignment)
        canvas?.sync()
    }
    @objc private func placeInText() { canvas?.returnToText(range: range) }
    @objc private func deleteImage() {
        canvas?.delete(range: range)
    }

    override func mouseDown(with event: NSEvent) {
        guard canvas?.canEdit == true, let host = canvas?.host else { return }
        let local = convert(event.locationInWindow, from: nil)
        let handle = isSelected ? CanvasImageLayout.Handle.allCases.first { handleRect($0).insetBy(dx: -5, dy: -5).contains(local) } : nil
        canvas?.select(range)
        dragStart = (host.convert(event.locationInWindow, from: nil), frame.insetBy(dx: 8, dy: 8), handle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let host = canvas?.host else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: point.x - start.point.x, y: point.y - start.point.y)
        guard isDragging || hypot(delta.x, delta.y) >= 3 else { return }
        if !isDragging { canvas?.beginPreview(range: range) }
        isDragging = true
        let rect: NSRect
        if let handle = start.handle {
            var resized = CanvasImageLayout.resized(start.rect, handle: handle, delta: delta)
            if resized.width > host.bounds.width {
                resized.size.height *= host.bounds.width / resized.width
                resized.size.width = host.bounds.width
            }
            resized.origin.x = min(resized.minX, max(0, host.bounds.width - resized.width))
            rect = resized
        }
        else {
            rect = NSRect(x: min(max(0, host.bounds.width - start.rect.width), max(0, start.rect.minX + delta.x)),
                          y: min(90_000, max(0, start.rect.minY + delta.y)), width: start.rect.width, height: start.rect.height)
        }
        frame = rect.insetBy(dx: -8, dy: -8)
        // Draw a live preview even while the original attachment is still inline.
        isFloating = true
        needsDisplay = true
        canvas?.onExtentChange?(frame.maxY)
        host.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let changed = isDragging
        dragStart = nil; isDragging = false
        canvas?.endPreview()
        if changed { canvas?.commit(range: range, rect: frame.insetBy(dx: 8, dy: 8)) }
        canvas?.sync()
    }
}

private final class ImageDragPreviewCell: NSTextAttachmentCell {
    var previewSize: NSSize = .zero
    override func cellSize() -> NSSize { previewSize }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}
