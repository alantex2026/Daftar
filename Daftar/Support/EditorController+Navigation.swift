//  EditorController+Navigation.swift
//  Table of contents and links between pages.

import AppKit

extension EditorController {
    // MARK: - Table of Contents

    struct HeadingItem: Identifiable {
        let id = UUID()
        let range: NSRange
        let text: String
        let level: Int   // 1 = Heading 1, 2 = Heading 2, 3 = Heading 3
    }

    /// Scans the page for paragraphs styled as one of the built-in headings
    /// (see `TextStyle.headingLevel`). A heuristic, not a stored outline - cheap
    /// enough to run on demand when the Table of Contents is opened, no
    /// need to keep it up to date on every keystroke.
    func headings() -> [HeadingItem] {
        guard let storage = textView?.textStorage, storage.length > 0 else { return [] }
        var result: [HeadingItem] = []
        let full = NSRange(location: 0, length: storage.length)
        (storage.string as NSString).enumerateSubstrings(in: full, options: .byParagraphs) { substring, subRange, _, _ in
            guard let substring, subRange.location < storage.length else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let font = (storage.attribute(.font, at: subRange.location, effectiveRange: nil) as? NSFont) ?? Self.defaultFont
            guard let level = TextStyle.headingLevel(of: font) else { return }
            result.append(HeadingItem(range: subRange, text: trimmed, level: level))
        }
        return result
    }

    /// Scrolls to and places the cursor at the start of a heading.
    func goTo(_ heading: HeadingItem) {
        guard let tv = textView else { return }
        tv.scrollRangeToVisible(heading.range)
        tv.setSelectedRange(NSRange(location: heading.range.location, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - Page links (internal linking)


    /// Inserts a clickable link to another page at the cursor, styled the
    /// same way `applyLink` styles a web link.
    func insertPageLink(to page: Page) {
        let url = DaftarLink.page(page.linkID).url
        var attrs = textView?.typingAttributes ?? [:]
        attrs[.link] = url
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        insert(NSAttributedString(string: page.displayTitle, attributes: attrs))
    }
}
