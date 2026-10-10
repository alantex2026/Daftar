//  EditorController+Images.swift
//  Inline images: inserting, galleries, sizing, alignment and snapping.

import AppKit
import UniformTypeIdentifiers

/// The "Default image size" setting: how big a newly inserted picture is,
/// relative to its own size. (The picture's right-click Size menu uses
/// `ImageSizePreset`, which is relative to the page instead.)
enum InsertedImageSize: String, CaseIterable, Sendable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: return 0.5
        case .medium: return 1.0
        case .large: return 1.5
        }
    }

    var title: String {
        switch self {
        case .small: return String(localized: "Small (50%)")
        case .medium: return String(localized: "Medium (100%)")
        case .large: return String(localized: "Large (150%)")
        }
    }
}

extension EditorController {
    // MARK: - Images

    /// Preset display widths for an inline image, as a fraction of the
    /// text container's usable width. Offered on an image's right-click
    /// menu, and what a manual resize drag snaps to when it lands close
    /// to one - so a page of photos stays tidy instead of every image
    /// sitting at whatever arbitrary width it was dropped in at.
    enum ImageSizePreset: String, CaseIterable {
        case small, medium, large, fullWidth, original

        nonisolated var widthFraction: CGFloat? {
            switch self {
            case .small: return 0.25
            case .medium: return 0.5
            case .large: return 0.75
            case .fullWidth: return 1.0
            case .original: return nil
            }
        }

        var title: String {
            switch self {
            case .small: return String(localized: "Small")
            case .medium: return String(localized: "Medium")
            case .large: return String(localized: "Large")
            case .fullWidth: return String(localized: "Full Width")
            case .original: return String(localized: "Original Size")
            }
        }

        /// The width this preset resolves to for an image of `naturalWidth`
        /// in a container of `containerWidth`. Small/Medium/Large stay
        /// capped at the image's natural size, since scaling a fractional
        /// "aesthetic" preset past that would just blur the image for no
        /// benefit - but Full Width and Original are explicit, literal
        /// requests, so both bypass that cap: Full Width always reaches
        /// the container's edge, even for a small image.
        nonisolated func resolvedWidth(containerWidth: CGFloat, naturalWidth: CGFloat) -> CGFloat {
            guard let fraction = widthFraction else { return naturalWidth }
            if case .fullWidth = self { return containerWidth }
            return min(containerWidth * fraction, naturalWidth)
        }
    }

    /// How close (in points) a manual resize drag has to land to a preset
    /// width before it snaps to it exactly.
    nonisolated static let imageSnapTolerance: CGFloat = 14

    /// The nearest size preset to `width` in a container of `containerWidth`,
    /// if it's within `imageSnapTolerance` of one - `nil` if it's already
    /// there or too far from any of them to snap.
    nonisolated static func nearestSnapWidth(to width: CGFloat, containerWidth: CGFloat, tolerance: CGFloat = imageSnapTolerance) -> CGFloat? {
        guard containerWidth > 0 else { return nil }
        let candidates = [0.25, 0.5, 0.75, 1.0].map { $0 * containerWidth }
        guard let nearest = candidates.min(by: { abs($0 - width) < abs($1 - width) }) else { return nil }
        let delta = abs(nearest - width)
        guard delta > 0.5, delta <= tolerance else { return nil }
        return nearest
    }

    /// Marks a run inserted by `insertFileAttachment` - a plain `.link`
    /// attribute, the same technique `audioActionURL` uses, since it's an
    /// ordinary `NSAttributedString.Key` that survives an RTFD round-trip
    /// (a custom `NSTextAttachment` subclass wouldn't: RTFD decoding
    /// reconstructs attachments as plain `NSTextAttachment`s).
    nonisolated static let fileAttachmentURL = DaftarLink.file.url

    /// True for attachments that hold image data (from `insertImage`/
    /// `insertImages`), as opposed to the audio-recording icon or a
    /// generic file attachment (`insertFileAttachment`) - both of which
    /// are also plain `NSTextAttachment`s but shouldn't get the image
    /// size/alignment context menu. A file attachment's extension can
    /// still be an image type (e.g. a `.png` attached as a file rather
    /// than inserted as a picture), so the `.link` marker is checked
    /// first and wins over the extension guess.
    nonisolated static func isImageAttachment(_ attachment: NSTextAttachment, at index: Int, in storage: NSTextStorage) -> Bool {
        if index < storage.length, let link = storage.attribute(.link, at: index, effectiveRange: nil) as? URL,
           link == fileAttachmentURL {
            return false
        }
        guard let filename = attachment.fileWrapper?.preferredFilename,
              let type = UTType(filenameExtension: (filename as NSString).pathExtension) else { return false }
        return type.conforms(to: .image)
    }


    /// Inserts every image at the cursor, each on its own line, ready to
    /// be independently resized/aligned/reordered.
    func insertImages(from urls: [URL]) {
        for (index, url) in urls.enumerated() {
            if index > 0 { insert(NSAttributedString(string: "\n")) }
            insertImage(from: url)
        }
    }

    /// How many columns a gallery of `count` photos lays out in - roughly
    /// square, but never more than 3 wide so cells stay big enough to be
    /// worth looking at.
    nonisolated static func galleryColumns(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        if count == 4 { return 2 }
        return min(3, count)
    }

    /// Inserts several images at once as one bordered grid block - a
    /// gallery - instead of stacking them as separate lines, so a set of
    /// related photos reads as one unit. Built on the same NSTextTable
    /// machinery as `insertTable`, so each photo is still an ordinary
    /// image attachment underneath: click to select, drag its handles to
    /// resize, right-click for size/alignment/remove all work exactly as
    /// they do for a normal inline image, just inside a grid cell.
    func insertImageGallery(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard urls.count > 1 else { insertImage(from: urls[0]); return }

        let columns = Self.galleryColumns(for: urls.count)
        let rows = Int(ceil(Double(urls.count) / Double(columns)))

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = true

        let containerWidth = textView?.textContainer?.size.width ?? 520
        let cellWidth = max(80, containerWidth / CGFloat(columns) - CGFloat(columns + 1) * 6)
        let font = (textView?.typingAttributes[.font] as? NSFont) ?? Self.defaultFont

        let result = NSMutableAttributedString()
        var index = 0
        for row in 0..<rows {
            for column in 0..<columns {
                defer { index += 1 }
                guard index < urls.count,
                      let original = try? Data(contentsOf: urls[index]),
                      let image = NSImage(data: original) else { continue }
                let wrapper = Self.storedImageWrapper(original, filename: urls[index].lastPathComponent)

                let block = NSTextTableBlock(table: table,
                                             startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.alignment = .center

                let attachment = NSTextAttachment(fileWrapper: wrapper)
                var size = image.size
                if size.width > cellWidth {
                    size = NSSize(width: cellWidth, height: size.height * cellWidth / size.width)
                }
                let cell = NSMutableAttributedString(attributedString: InlineImageSize.attributedString(for: attachment, size: size, image: image))
                cell.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        insert(result)
    }

    func insertImage(from url: URL) {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            errorMessage = "Couldn't insert \u{201C}\(url.lastPathComponent)\u{201D}."
            return
        }
        insertImageAttachment(wrapper: Self.storedImageWrapper(data, filename: url.lastPathComponent), image: image)
    }

    /// For images that arrive as raw bytes rather than a file on disk -
    /// a pasted screenshot, or one dragged in without a backing file URL.
    func insertImage(data: Data, filename: String) {
        guard let image = NSImage(data: data) else { return }
        insertImageAttachment(wrapper: Self.storedImageWrapper(data, filename: filename), image: image)
    }

    /// The bytes actually stored for an inserted image, after the "Compress
    /// new pictures" setting. Display size still comes from the original.
    nonisolated static func storedImageWrapper(_ data: Data, filename: String,
                                               compression: ImageCompression = AppSettings.imageCompression) -> FileWrapper {
        let stored = compression.apply(to: data, filename: filename)
        let wrapper = FileWrapper(regularFileWithContents: stored.data)
        wrapper.preferredFilename = stored.filename
        return wrapper
    }

    /// Every single-image insert (toolbar, paste, drag and drop) lands here,
    /// scaled by the "Default image size" setting.
    private func insertImageAttachment(wrapper: FileWrapper, image: NSImage) {
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let size = Self.insertedImageSize(for: image.size, containerWidth: textView?.textContainer?.size.width ?? 0,
                                          size: AppSettings.imageSize)
        insert(InlineImageSize.attributedString(for: attachment, size: size, image: image))
    }

    /// The size a newly inserted image gets: its own size scaled by `size`,
    /// but never wider than the page, which would force sideways scrolling.
    /// Before layout the container can be 0 wide; 520pt stands in until then.
    nonisolated static func insertedImageSize(for natural: NSSize, containerWidth: CGFloat, size: InsertedImageSize) -> NSSize {
        guard natural.width > 0, natural.height > 0 else { return natural }
        let pageWidth = containerWidth > 0 ? containerWidth : 520
        let width = min(natural.width * size.scale, pageWidth)
        return NSSize(width: width, height: natural.height * width / natural.width)
    }

    /// Sets an image to one of the standard preset widths (its own line's
    /// alignment decides where it sits within that width).
    func setImageSize(at range: NSRange, to preset: ImageSizePreset) {
        guard let storage = textView?.textStorage, NSMaxRange(range) <= storage.length,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data),
              image.size.width > 0 else { return }
        let containerWidth = textView?.textContainer?.size.width ?? attachment.bounds.width
        let width = preset.resolvedWidth(containerWidth: containerWidth, naturalWidth: image.size.width)
        applyImageWidth(width, naturalSize: image.size, attachment: attachment, range: range)
    }

    /// Sets the alignment of the paragraph (line) an image sits on -
    /// images are inline, so this is how you move one to the left,
    /// center, or right of the page.
    func setImageAlignment(at range: NSRange, to alignment: NSTextAlignment) {
        guard let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: range)
        edit(paragraphRange) { storage in
            let style = (storage.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        }
    }

    func removeImage(at range: NSRange) {
        guard let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
        if let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment {
            knownImageWidths.removeValue(forKey: ObjectIdentifier(attachment))
        }
        edit(range) { storage in storage.deleteCharacters(in: range) }
    }

    /// Live width for an image as the user drags one of its selection
    /// handles - clamped to a sensible minimum and to the image's own
    /// natural size, and snapped to the nearest size preset once the drag
    /// lands within `imageSnapTolerance` of one (same snap the menu's
    /// presets and a stray drag both already use).
    func resizeImage(attachment: NSTextAttachment, range: NSRange, toWidth width: CGFloat, naturalSize: NSSize) {
        guard naturalSize.width > 0 else { return }
        let containerWidth = textView?.textContainer?.size.width ?? width
        // Floor only - dragging outward is allowed to grow an image past
        // its native pixel width (it'll just soften), same as any other
        // rich text editor. An upper bound still guards against a runaway
        // drag delta producing an absurd size.
        let upperBound = max(containerWidth, naturalSize.width) * 3
        let clamped = min(max(width, 40), upperBound)
        let target = Self.nearestSnapWidth(to: clamped, containerWidth: containerWidth) ?? clamped
        applyImageWidth(target, naturalSize: naturalSize, attachment: attachment, range: range)
    }

    private func applyImageWidth(_ width: CGFloat, naturalSize: NSSize, attachment: NSTextAttachment, range: NSRange) {
        guard naturalSize.width > 0 else { return }
        let height = naturalSize.height * width / naturalSize.width
        if let tv = textView as? DaftarTextView, let storage = tv.textStorage,
           var layout = CanvasImageLayout(link: storage.attribute(.link, at: range.location, effectiveRange: nil)) {
            layout.rect.size = NSSize(width: width, height: height)
            tv.imageCanvas?.commit(range: range, rect: layout.rect)
            return
        }
        edit(range) { storage in
            let size = NSSize(width: width, height: height)
            InlineImageSize.applyCell(to: attachment, size: size)
            storage.addAttribute(.link, value: InlineImageSize.url(for: size), range: range)
        }
        knownImageWidths[ObjectIdentifier(attachment)] = width
    }

    /// Called after every edit, as a safety net for any bounds change that
    /// didn't already go through `resizeImage` - snaps a width that lands
    /// within `imageSnapTolerance` of a size preset to that exact value.
    func snapRecentlyResizedImages() {
        guard !isApplyingImageSnap, let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return }
        let containerWidth = tv.textContainer?.size.width ?? 0
        guard containerWidth > 0 else { return }

        var pending: [(attachment: NSTextAttachment, range: NSRange, width: CGFloat, naturalSize: NSSize)] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  Self.isImageAttachment(attachment, at: range.location, in: storage) else { return }
            guard CanvasImageLayout(link: storage.attribute(.link, at: range.location, effectiveRange: nil)) == nil else { return }
            let id = ObjectIdentifier(attachment)
            let currentWidth = attachment.bounds.width
            defer { knownImageWidths[id] = currentWidth }
            guard let previousWidth = knownImageWidths[id], abs(currentWidth - previousWidth) > 0.5,
                  let target = Self.nearestSnapWidth(to: currentWidth, containerWidth: containerWidth),
                  let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data),
                  image.size.width > 0 else { return }
            pending.append((attachment, range, target, image.size))
        }

        guard !pending.isEmpty else { return }
        isApplyingImageSnap = true
        for resize in pending {
            let size = NSSize(width: resize.width, height: resize.naturalSize.height * resize.width / resize.naturalSize.width)
            InlineImageSize.applyCell(to: resize.attachment, size: size)
            storage.addAttribute(.link, value: InlineImageSize.url(for: size), range: resize.range)
            knownImageWidths[ObjectIdentifier(resize.attachment)] = resize.width
        }
        isApplyingImageSnap = false
    }
}
