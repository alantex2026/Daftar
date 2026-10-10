//  EditorController+Lists.swift
//  Bulleted, numbered and checklist lines. Markers and nesting are parsed by
//  `ListLine`; typing behavior (Return, Tab, Backspace) lives in ListEditing.swift.

import AppKit

extension EditorController {
    // MARK: - Simple bullet / numbered lists

    func toggleBullet(numbered: Bool = false) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = currentParagraphRange()
        let text = (storage.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")

        // Pressing the button again on lines that are already this kind of
        // list turns them back into plain text, keeping their indentation.
        let items = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(ListLine.init)
        let allSameKind = !items.isEmpty && items.allSatisfy { item in
            switch item?.kind {
            case .bullet?: return !numbered
            case .numbered?: return numbered
            default: return false
            }
        }

        // Every new numbered item starts as "1."; `renumberLists` then counts
        // each nesting level separately.
        let rebuilt = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let (tabs, bareLine) = Self.splitListLine(line)
            if allSameKind { return tabs + bareLine }
            return tabs + (numbered ? "1. " : ListLine.bulletMarker) + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
        (tv as? DaftarTextView)?.renumberLists()
    }

    /// A line's leading tabs (its nesting) and its text without any list marker.
    private static func splitListLine(_ line: String) -> (tabs: String, text: String) {
        if let item = ListLine(line) { return (String(repeating: "\t", count: item.level), item.content) }
        let tabs = String(line.prefix { $0 == "\t" })
        return (tabs, String(line.dropFirst(tabs.count)))
    }

    // MARK: - Checklists

    nonisolated private static let checklistToggleURL = DaftarLink.checklistToggle.url

    /// If `line` is a checklist item, whether it's checked and the text after
    /// the marker. Otherwise nil. Static (like the glyph marker below) so
    /// RichTextEditor can call it too, when it re-marks checklist glyphs
    /// clickable right after loading a page.
    nonisolated static func checklistContent(of line: String) -> (checked: Bool, text: String)? {
        guard let item = ListLine(line), case .checklist(let checked) = item.kind else { return nil }
        return (checked, item.content)
    }

    /// Marks every checklist glyph in `range` as a clickable link, so
    /// clicking it can flip checked state via the same link-click
    /// mechanism page links use (see RichTextEditor.Coordinator). Only run
    /// when checklist lines are created or a page is loaded - not on every
    /// keystroke, which a full-document scan would be too costly for.
    nonisolated static func markChecklistGlyphs(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let nsString = storage.string as NSString
        nsString.enumerateSubstrings(in: range, options: .byParagraphs) { substring, subRange, _, _ in
            guard let substring, subRange.length > 0, let item = ListLine(substring),
                  case .checklist = item.kind else { return }
            storage.addAttribute(.link, value: checklistToggleURL, range: NSRange(location: subRange.location + item.level, length: 1))
        }
    }

    /// Converts the current line(s) to checklist items, or - if every
    /// selected line already is one - back to plain text. Mirrors
    /// `toggleBullet`'s on/off contract exactly, for the same reason: one
    /// button, press again to undo.
    func toggleChecklist() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = currentParagraphRange()
        let text = (storage.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")

        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allAlreadyChecklist = !nonBlank.isEmpty && nonBlank.allSatisfy { Self.checklistContent(of: $0) != nil }

        let rebuilt = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let (tabs, bareLine) = Self.splitListLine(line)
            return allAlreadyChecklist ? tabs + bareLine : tabs + ListLine.uncheckedMarker + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
        Self.markChecklistGlyphs(in: NSRange(location: range.location, length: (rebuilt as NSString).length), storage: storage)
        (tv as? DaftarTextView)?.renumberLists()
    }

    /// Flips one checklist line's checked state - called when its glyph is
    /// clicked. Also strikes through (or un-strikes) the item's text,
    /// without touching any other formatting already on that line.
    func toggleChecklistItem(at charIndex: Int) {
        guard let tv = textView, let storage = tv.textStorage,
              charIndex >= 0, charIndex < storage.length else { return }
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        let line = (storage.string as NSString).substring(with: lineRange)
        guard let item = ListLine(line), case .checklist(let checked) = item.kind else { return }

        let glyphLocation = lineRange.location + item.level
        let textLength = (item.content as NSString).length
        let newGlyph = checked ? "\u{2610}" : "\u{2611}"

        guard tv.shouldChangeText(in: lineRange, replacementString: nil) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: glyphLocation, length: 1), with: newGlyph)
        storage.addAttribute(.link, value: Self.checklistToggleURL, range: NSRange(location: glyphLocation, length: 1))
        if textLength > 0 {
            let textRange = NSRange(location: lineRange.location + item.markerLength, length: textLength)
            storage.addAttribute(.strikethroughStyle,
                                 value: checked ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: textRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }
}
