import AppKit

/// Geometry lives on the image's RTFD link attribute so it travels with the
/// existing attachment through backups, history, duplication and folder sync.
/// The image bytes remain a standard attachment, readable by other editors.
struct CanvasImageLayout: Equatable {
    var rect: NSRect

    init(rect: NSRect) { self.rect = rect }

    init?(link: Any?) {
        let raw = (link as? URL)?.absoluteString ?? link as? String
        guard let raw, let url = URLComponents(string: raw), url.scheme == "daftar-image",
              url.host == "canvas", let items = url.queryItems else { return nil }
        func number(_ name: String) -> Double? {
            guard let value = items.first(where: { $0.name == name })?.value,
                  let number = Double(value), number.isFinite else { return nil }
            return number
        }
        guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"),
              x >= 0, y >= 0, w >= 1, h >= 1, x + w <= 100_000, y + h <= 100_000 else { return nil }
        rect = NSRect(x: x, y: y, width: w, height: h)
    }

    var url: URL {
        var url = URLComponents()
        url.scheme = "daftar-image"; url.host = "canvas"
        url.queryItems = [("x", rect.minX), ("y", rect.minY), ("w", rect.width), ("h", rect.height)].map {
            URLQueryItem(name: $0.0, value: String(Double($0.1)))
        }
        return url.url!
    }

    /// Export normal attachment cells rather than the invisible editing cells.
    static func portable(_ source: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: source)
        source.enumerateAttribute(.attachment, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let layout = Self(link: source.attribute(.link, at: range.location, effectiveRange: nil))
            let replacement = NSTextAttachment(fileWrapper: attachment.fileWrapper.map(fastWrapper))
            replacement.bounds = layout.map { NSRect(origin: .zero, size: $0.rect.size) } ?? attachment.bounds
            copy.addAttribute(.attachment, value: replacement, range: range)
        }
        return copy
    }

    /// File wrappers that came out of a decoded RTFD cost ~120 ms each to
    /// write back out, every save, regardless of size (measured on real
    /// pages: 250 ms per autosave for two images). A fresh wrapper around the
    /// same bytes and name encodes in under a millisecond. Contents are
    /// shared copy-on-write, so this doesn't duplicate image data.
    private static func fastWrapper(_ wrapper: FileWrapper) -> FileWrapper {
        guard wrapper.isRegularFile, let contents = wrapper.regularFileContents else { return wrapper }
        let fresh = FileWrapper(regularFileWithContents: contents)
        fresh.preferredFilename = wrapper.preferredFilename ?? wrapper.filename ?? "Attachment"
        return fresh
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var unit: NSPoint {
            switch self {
            case .topLeft: return NSPoint(x: 0, y: 0)
            case .top: return NSPoint(x: 0.5, y: 0)
            case .topRight: return NSPoint(x: 1, y: 0)
            case .right: return NSPoint(x: 1, y: 0.5)
            case .bottomRight: return NSPoint(x: 1, y: 1)
            case .bottom: return NSPoint(x: 0.5, y: 1)
            case .bottomLeft: return NSPoint(x: 0, y: 1)
            case .left: return NSPoint(x: 0, y: 0.5)
            }
        }
    }

    /// Aspect-preserving resize, anchored at the opposite handle. Deltas are
    /// measured in canvas coordinates, independent of zoom and the moving view.
    static func resized(_ start: NSRect, handle: Handle, delta: NSPoint) -> NSRect {
        let u = handle.unit
        let sx: CGFloat = u.x == 0 ? -1 : 1
        let sy: CGFloat = u.y == 0 ? -1 : 1
        let aspect = start.width / max(1, start.height)
        let change: CGFloat
        if u.x == 0.5 { change = sy * delta.y * aspect }
        else if u.y == 0.5 { change = sx * delta.x }
        else { change = (sx * delta.x + sy * delta.y / aspect) / (1 + 1 / (aspect * aspect)) }
        let width = min(10_000, max(max(24, 24 * aspect), start.width + change))
        let height = width / aspect
        return NSRect(x: max(0, start.minX + (start.width - width) * (1 - u.x)),
                      y: max(0, start.minY + (start.height - height) * (1 - u.y)),
                      width: width, height: height)
    }
}

/// Floating pictures don't occupy a text line. Only this runtime cell is hidden;
/// the portable RTFD representation keeps an ordinary, full-size image cell.
final class CanvasImageCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize { .zero }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}

/// Display size of an inline (flowing with the text) picture.
///
/// TextKit 1 lays an attachment out at its cell's size - the picture's natural
/// size - and ignores `NSTextAttachment.bounds`, which RTFD doesn't save
/// either. So resizing an inline picture used to change nothing visible until
/// a handle drag turned it into a positioned picture. The size is kept on the
/// picture's link attribute (saved with the page, like `CanvasImageLayout`)
/// and applied as a cell of exactly that size.
enum InlineImageSize {
    static func url(for size: NSSize) -> URL {
        var url = URLComponents()
        url.scheme = "daftar-image"; url.host = "inline"
        url.queryItems = [URLQueryItem(name: "w", value: String(Double(size.width))),
                          URLQueryItem(name: "h", value: String(Double(size.height)))]
        return url.url!
    }

    static func size(from link: Any?) -> NSSize? {
        let raw = (link as? URL)?.absoluteString ?? link as? String
        guard let raw, let url = URLComponents(string: raw), url.scheme == "daftar-image", url.host == "inline",
              let items = url.queryItems,
              let w = items.first(where: { $0.name == "w" })?.value.flatMap(Double.init),
              let h = items.first(where: { $0.name == "h" })?.value.flatMap(Double.init),
              w.isFinite, h.isFinite, (1...100_000).contains(w), (1...100_000).contains(h) else { return nil }
        return NSSize(width: w, height: h)
    }

    /// Gives `attachment` a cell drawing its picture at exactly `size`.
    static func applyCell(to attachment: NSTextAttachment, size: NSSize, image: NSImage? = nil) {
        guard let picture = image?.copy() as? NSImage
                ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) else { return }
        picture.size = size  // draws the full-resolution picture scaled into this size
        attachment.attachmentCell = SizedImageCell(imageCell: picture)
        attachment.bounds = NSRect(origin: .zero, size: size)
    }

    static func needsCell(_ attachment: NSTextAttachment, size: NSSize) -> Bool {
        guard let current = attachment.attachmentCell?.cellSize() else { return true }
        return abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5
    }

    /// A picture character carrying `size`, ready to insert. At its natural
    /// size a picture needs neither a link nor a special cell. `bounds` always
    /// holds the displayed size: resize handles and previews read it.
    static func attributedString(for attachment: NSTextAttachment, size: NSSize, image: NSImage) -> NSAttributedString {
        let natural = abs(image.size.width - size.width) <= 0.5 && abs(image.size.height - size.height) <= 0.5
        if natural { attachment.bounds = NSRect(origin: .zero, size: size) }
        else { applyCell(to: attachment, size: size, image: image) }
        let text = NSMutableAttributedString(attachment: attachment)
        if !natural { text.addAttribute(.link, value: url(for: size), range: NSRange(location: 0, length: text.length)) }
        return text
    }

    /// Undo (or anything else) removed the size: back to the natural-size cell.
    /// Returns true if the attachment changed.
    static func resetIfUnsized(_ attachment: NSTextAttachment) -> Bool {
        guard attachment.attachmentCell is SizedImageCell else { return false }
        attachment.attachmentCell = nil  // AppKit recreates its default, natural-size cell
        attachment.bounds = NSRect(origin: .zero, size: attachment.attachmentCell?.cellSize() ?? .zero)
        return true
    }
}

/// Marks cells created by `InlineImageSize`, so they can be told apart from
/// AppKit's default cell and from the canvas's hidden cell.
final class SizedImageCell: NSTextAttachmentCell {}
