//  ListEditing.swift
//  Lists that behave like lists: Return continues them, Return on an empty
//  item ends them, Tab / Shift-Tab change the nesting level, Backspace right
//  after a marker removes it, and numbered items renumber themselves.
//
//  Items stay plain text markers ("• ", "1. ", "☐ ", "☑ ") with one leading
//  tab per nesting level. RTFD drops NSTextList and heading levels, while
//  these markers survive saving, sync, search, history and Markdown.

import AppKit

/// One paragraph that starts with a list marker, optionally nested with
/// leading tabs.
struct ListLine: Equatable {
    enum Kind: Equatable {
        case bullet
        case numbered(Int)
        case checklist(checked: Bool)
    }

    static let bulletMarker = "\u{2022} "
    static let uncheckedMarker = "\u{2610} "
    static let checkedMarker = "\u{2611} "

    let kind: Kind
    /// Nesting depth: the number of leading tabs.
    let level: Int
    /// UTF-16 length of the leading tabs plus the marker - where the text starts.
    let markerLength: Int
    /// UTF-16 length of the digits of a numbered marker; 0 for other kinds.
    let digitsLength: Int
    /// The item's text, without tabs, marker or line break.
    let content: String

    /// `paragraph` may include its trailing line break.
    init?(_ paragraph: String) {
        var rest = Substring(paragraph)
        while let last = rest.last, last.isNewline { rest = rest.dropLast() }
        let level = rest.prefix { $0 == "\t" }.count
        rest = rest.dropFirst(level)
        let marker: String
        if rest.hasPrefix(Self.bulletMarker) {
            kind = .bullet; marker = Self.bulletMarker
        } else if rest.hasPrefix(Self.uncheckedMarker) {
            kind = .checklist(checked: false); marker = Self.uncheckedMarker
        } else if rest.hasPrefix(Self.checkedMarker) {
            kind = .checklist(checked: true); marker = Self.checkedMarker
        } else {
            // Up to three digits, so a line like "2024. was a year" isn't a list.
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...3).contains(digits.count), let number = Int(digits),
                  rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
            kind = .numbered(number); marker = digits + ". "
        }
        self.level = level
        markerLength = level + (marker as NSString).length
        if case .numbered = kind { digitsLength = (marker as NSString).length - 2 } else { digitsLength = 0 }
        content = String(rest.dropFirst(marker.count))
    }

    /// The marker the next item of this list starts with (same level).
    var nextItemMarker: String {
        let tabs = String(repeating: "\t", count: level)
        switch kind {
        case .bullet: return tabs + Self.bulletMarker
        case .numbered(let number): return tabs + "\(number + 1). "
        case .checklist: return tabs + Self.uncheckedMarker
        }
    }
}

extension DaftarTextView {
    // MARK: - Keyboard behavior

    /// Return inside a list item: start the next item, or end the list when
    /// the item is empty. Returns false to let AppKit insert a plain newline.
    func continueListOnNewline() -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let selection = selectedRange()
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        guard let item = ListLine(text.substring(with: paragraph)),
              selection.location >= paragraph.location + item.markerLength else { return false }

        if item.content.trimmingCharacters(in: .whitespaces).isEmpty, selection.length == 0 {
            // Empty item: step out one level, or leave the list entirely.
            if item.level > 0 { return changeListLevel(by: -1) }
            replaceListText(NSRange(location: paragraph.location, length: item.markerLength), with: "")
            setSelectedRange(NSRange(location: paragraph.location, length: 0))
            return true
        }

        insertText("\n" + item.nextItemMarker, replacementRange: selection)
        if case .checklist = item.kind {
            // A new item starts unchecked: drop the strikethrough a checked
            // line hands to its successor, and make its box clickable.
            let newParagraph = (storage.string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
            storage.removeAttribute(.strikethroughStyle, range: newParagraph)
            typingAttributes[.strikethroughStyle] = nil
            EditorController.markChecklistGlyphs(in: newParagraph, storage: storage)
        }
        renumberLists()
        return true
    }

    /// Tab (+1) or Shift-Tab (-1) on list items in the selection. Returns
    /// false when no selected paragraph is a list item.
    @discardableResult
    func changeListLevel(by delta: Int) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let selection = selectedRange()
        let text = storage.string as NSString
        let selected = text.paragraphRange(for: selection)
        var paragraphs: [(range: NSRange, item: ListLine)] = []
        text.enumerateSubstrings(in: selected, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            if let item = ListLine(text.substring(with: range)) { paragraphs.append((range, item)) }
        }
        guard !paragraphs.isEmpty else { return false }

        var shiftBeforeCaret = 0, totalShift = 0
        for (range, item) in paragraphs.reversed() {
            if delta > 0 {
                replaceListText(NSRange(location: range.location, length: 0), with: "\t")
            } else if item.level > 0 {
                replaceListText(NSRange(location: range.location, length: 1), with: "")
            } else { continue }
            totalShift += delta
            if range.location <= selection.location { shiftBeforeCaret += delta }
        }
        if selection.length == 0 {
            setSelectedRange(NSRange(location: max(selected.location, selection.location + shiftBeforeCaret), length: 0))
        } else {
            setSelectedRange(NSRange(location: selected.location, length: max(0, selected.length + totalShift)))
        }
        renumberLists()
        return true
    }

    /// Backspace right after a marker removes the marker (or outdents a
    /// nested item) instead of deleting the space before the text.
    func removeListMarkerOnBackspace() -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        guard let item = ListLine(text.substring(with: paragraph)),
              selection.location == paragraph.location + item.markerLength else { return false }
        if item.level > 0 { return changeListLevel(by: -1) }
        replaceListText(NSRange(location: paragraph.location, length: item.markerLength), with: "")
        setSelectedRange(NSRange(location: paragraph.location, length: 0))
        renumberLists()
        return true
    }

    /// Whether the character before the caret (or the selection) contains a
    /// line break - deleting one can join or split numbered items.
    func deletionJoinsLines() -> Bool {
        guard let storage = textStorage else { return false }
        let selection = selectedRange()
        let text = storage.string as NSString
        let range = selection.length > 0 ? selection
            : NSRange(location: max(0, selection.location - 1), length: selection.location > 0 ? 1 : 0)
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        return text.substring(with: range).contains { $0.isNewline }
    }

    // MARK: - Numbering

    /// Renumbers every numbered list so each run counts up from its first
    /// item's number. Bullets, checklists and other text end a run at their
    /// level; deeper items don't interrupt the outer list.
    func renumberLists() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        var counters: [Int?] = []  // per level: last number used, nil = no run yet
        var edits: [(range: NSRange, number: String)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard let item = ListLine(text.substring(with: range)) else { counters = []; return }
            if counters.count > item.level + 1 { counters.removeLast(counters.count - item.level - 1) }
            while counters.count <= item.level { counters.append(nil) }
            guard case .numbered(let number) = item.kind else { counters[item.level] = nil; return }
            let wanted = counters[item.level].map { $0 + 1 } ?? number
            counters[item.level] = wanted
            if wanted != number {
                edits.append((NSRange(location: range.location + item.level, length: item.digitsLength), String(wanted)))
            }
        }
        guard !edits.isEmpty else { return }
        let selection = selectedRange()
        var shift = 0
        for edit in edits.reversed() {
            replaceListText(edit.range, with: edit.number)
            if edit.range.location < selection.location { shift += (edit.number as NSString).length - edit.range.length }
        }
        setSelectedRange(NSRange(location: min(storage.length, max(0, selection.location + shift)), length: selection.length))
    }

    /// One undoable replacement that keeps the surrounding formatting.
    private func replaceListText(_ range: NSRange, with string: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: string) else { return }
        var attributes = storage.length == 0 ? typingAttributes
            : storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
        attributes[.link] = nil
        attributes[.attachment] = nil
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attributes))
        didChangeText()
    }
}
