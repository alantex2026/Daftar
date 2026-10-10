//  SearchHighlight.swift
//  Opening a page from search results highlights every match, the way
//  Safari's Find does, and scrolls to the first. The highlight is a
//  temporary layout attribute - never saved - and clears on the first edit.

import AppKit

@MainActor
enum SearchHighlight {
    private static var pending: (page: UUID, query: String)?

    /// Asks the editor for `page` to highlight `query`, whether it opens
    /// now or is already open.
    static func request(_ query: String, for page: UUID) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        pending = (page, query)
        NotificationCenter.default.post(name: .daftarHighlightSearch, object: page)
    }

    /// The query waiting for `page`, if any; taking it clears it.
    static func take(for page: UUID) -> String? {
        guard let pending, pending.page == page else { return nil }
        self.pending = nil
        return pending.query
    }

    /// Highlights every match and returns how many there were. `scroll`
    /// brings the first into view with the system find indicator.
    @discardableResult
    static func apply(_ query: String, to textView: NSTextView, scroll: Bool = true) -> Int {
        guard let layoutManager = textView.layoutManager else { return 0 }
        clear(in: textView)
        let ranges = SearchText.ranges(of: query, in: textView.string)
        for range in ranges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: range)
        }
        if scroll, let first = ranges.first {
            // The caret goes to the match too, so restoring focus on open
            // scrolls here rather than back to the last cursor position.
            textView.setSelectedRange(NSRange(location: first.location, length: 0))
            textView.scrollRangeToVisible(first)
            textView.showFindIndicator(for: first)
        }
        return ranges.count
    }

    static func clear(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
    }
}

extension Notification.Name {
    /// `object`: the link ID of the page whose editor should highlight.
    static let daftarHighlightSearch = Notification.Name("DaftarHighlightSearch")
}

extension SearchText {
    /// Every occurrence of `query` in `text`, as exact UTF-16 ranges for
    /// AppKit, using the same matching rules as `matches`.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        // Fold the text the way `fold` does, remembering where each folded
        // UTF-16 unit came from so ranges map back exactly.
        let alefVariants: Set<unichar> = [0x0622, 0x0623, 0x0625, 0x0671]
        var folded: [unichar] = [], origin: [Int] = []
        for (offset, unit) in text.utf16.enumerated() where unit != 0x0640 {  // tatweel
            folded.append(alefVariants.contains(unit) ? 0x0627 : unit)
            origin.append(offset)
        }
        let haystack = NSString(characters: folded, length: folded.count)
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var result: [NSRange] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(of: needle, options: options,
                                       range: NSRange(location: location, length: haystack.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            let start = origin[found.location], end = origin[NSMaxRange(found) - 1] + 1
            result.append(NSRange(location: start, length: end - start))
            location = NSMaxRange(found)
        }
        return result
    }
}
