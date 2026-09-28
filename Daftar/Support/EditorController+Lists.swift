//  EditorController+Lists.swift
//  Bulleted, numbered and checklist lines.

import AppKit

extension EditorController {
    // MARK: - Simple bullet / numbered lists

    /// If `line` starts with a numbered-list marker ("1. "), the text after the marker. Otherwise nil.
    private func numberedListContent(of line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              line.distance(from: line.startIndex, to: dot) <= 2,
              Int(line[line.startIndex..<dot]) != nil,
              line.count > line.distance(from: line.startIndex, to: dot) + 1 else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    func toggleBullet(numbered: Bool = false) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = currentParagraphRange()
        let text = (storage.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")

        var counter = 1
        let rebuilt = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }

            // Strip whatever marker is already there, and remember whether it
            // was the SAME kind we were asked for (in which case we turn it off)
            // or the OTHER kind (in which case we convert it below).
            let bareLine: String
            let sameKindAlreadyApplied: Bool
            if line.hasPrefix("• ") {
                bareLine = String(line.dropFirst(2))
                sameKindAlreadyApplied = !numbered
            } else if let content = numberedListContent(of: line) {
                bareLine = content
                sameKindAlreadyApplied = numbered
            } else if let checklist = Self.checklistContent(of: line) {
                bareLine = checklist.text
                sameKindAlreadyApplied = false
            } else {
                bareLine = line
                sameKindAlreadyApplied = false
            }

            if sameKindAlreadyApplied { return bareLine }
            if numbered {
                let out = "\(counter). " + bareLine
                counter += 1
                return out
            }
            return "• " + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
    }

    // MARK: - Checklists

    nonisolated private static let checklistToggleURL = DaftarLink.checklistToggle.url

    /// If `line` starts with a checklist marker, whether it's checked and
    /// the text after the marker. Otherwise nil. Static (like the glyph
    /// marker below) so RichTextEditor can call it too, when it re-marks
    /// checklist glyphs clickable right after loading a page.
    nonisolated static func checklistContent(of line: String) -> (checked: Bool, text: String)? {
        if line.hasPrefix("\u{2610} ") { return (false, String(line.dropFirst(2))) }
        if line.hasPrefix("\u{2611} ") { return (true, String(line.dropFirst(2))) }
        return nil
    }

    /// Marks every checklist glyph in `range` as a clickable link, so
    /// Cmd-clicking it can flip checked state via the same link-click
    /// mechanism page links use (see RichTextEditor.Coordinator). Only run
    /// when checklist lines are created or a page is loaded - not on every
    /// keystroke, which a full-document scan would be too costly for.
    nonisolated static func markChecklistGlyphs(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let nsString = storage.string as NSString
        nsString.enumerateSubstrings(in: range, options: .byParagraphs) { substring, subRange, _, _ in
            guard let substring, subRange.length > 0, checklistContent(of: substring) != nil else { return }
            storage.addAttribute(.link, value: checklistToggleURL, range: NSRange(location: subRange.location, length: 1))
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
            if allAlreadyChecklist {
                return Self.checklistContent(of: line)?.text ?? line
            }
            let bareLine: String
            if let checklist = Self.checklistContent(of: line) {
                bareLine = checklist.text
            } else if line.hasPrefix("• ") {
                bareLine = String(line.dropFirst(2))
            } else if let numbered = numberedListContent(of: line) {
                bareLine = numbered
            } else {
                bareLine = line
            }
            return "\u{2610} " + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
        Self.markChecklistGlyphs(in: NSRange(location: range.location, length: (rebuilt as NSString).length), storage: storage)
    }

    /// Flips one checklist line's checked state - called when its glyph is
    /// Cmd-clicked. Also strikes through (or un-strikes) the item's text,
    /// without touching any other formatting already on that line.
    func toggleChecklistItem(at charIndex: Int) {
        guard let tv = textView, let storage = tv.textStorage,
              charIndex >= 0, charIndex < storage.length else { return }
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        let line = (storage.string as NSString).substring(with: lineRange)
        guard let content = Self.checklistContent(of: line) else { return }

        let hasTrailingNewline = line.hasSuffix("\n")
        let textLength = max(0, lineRange.length - 2 - (hasTrailingNewline ? 1 : 0))
        let newGlyph = content.checked ? "\u{2610}" : "\u{2611}"

        guard tv.shouldChangeText(in: lineRange, replacementString: nil) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: newGlyph)
        storage.addAttribute(.link, value: Self.checklistToggleURL, range: NSRange(location: lineRange.location, length: 1))
        if textLength > 0 {
            let textRange = NSRange(location: lineRange.location + 2, length: textLength)
            storage.addAttribute(.strikethroughStyle,
                                 value: content.checked ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: textRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }
}
