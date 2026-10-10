import Foundation

/// The app's internal link schemes, stored as `.link` attributes in page RTFD.
/// Every place that builds or recognizes one goes through here, so the
/// formats can't drift apart between the editors, export, backup and sync.
enum DaftarLink: Equatable {
    /// `daftar://page/<linkID>` - a link to another page.
    case page(UUID)
    /// `daftar://checklist-toggle` - a clickable checklist box.
    case checklistToggle
    /// `daftar-audio://<id>` - an audio recording chip.
    case audio(UUID)
    /// `daftar-image://canvas?...` - positioning data for a floating image (see `CanvasImageLayout`).
    case image
    /// `daftar-file://attachment` - a generic file attachment.
    case file

    /// Accepts a `.link` attribute value, which AppKit stores as URL or String.
    init?(_ value: Any?) {
        let raw = (value as? URL)?.absoluteString ?? value as? String
        guard let raw, let url = URL(string: raw) else { return nil }
        switch (url.scheme, url.host) {
        case ("daftar", "page"):
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .page(id)
        case ("daftar", "checklist-toggle"): self = .checklistToggle
        case ("daftar-audio", let host?):
            guard let id = UUID(uuidString: host) else { return nil }
            self = .audio(id)
        case ("daftar-image", _): self = .image
        case ("daftar-file", _): self = .file
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .page(let id): return URL(string: "daftar://page/\(id.uuidString)")!
        case .checklistToggle: return URL(string: "daftar://checklist-toggle")!
        case .audio(let id): return URL(string: "daftar-audio://\(id.uuidString)")!
        case .image: return URL(string: "daftar-image://canvas")!
        case .file: return URL(string: "daftar-file://attachment")!
        }
    }

    var pageID: UUID? {
        if case .page(let id) = self { return id }
        return nil
    }
}

extension NSAttributedString {
    /// Every page this text links to.
    var linkedPageIDs: [UUID] {
        var ids = Set<UUID>()
        enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, _, _ in
            if let id = DaftarLink(value)?.pageID { ids.insert(id) }
        }
        return Array(ids)
    }
}

extension NSMutableAttributedString {
    /// Points page links at new IDs (imports, restores and conflict copies).
    func remapPageLinks(_ ids: [UUID: UUID]) {
        enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let old = DaftarLink(value)?.pageID, let new = ids[old] {
                addAttribute(.link, value: DaftarLink.page(new).url.absoluteString, range: range)
            }
        }
    }
}
