import AppKit

extension DaftarTextView {
    /// Places an ordinary rich-text paragraph at an empty canvas location.
    /// Using paragraph indentation and line breaks keeps text searchable,
    /// undoable, and compatible with RTFD, history, backups and export.
    @discardableResult
    func placeInsertionPointOnCanvas(at point: NSPoint) -> Bool {
        guard allowsCanvasTyping, isEditable, let storage = textStorage,
              let lm = layoutManager, let container = textContainer else { return false }
        lm.ensureLayout(for: container)
        let local = NSPoint(x: max(0, point.x - textContainerOrigin.x),
                            y: max(0, point.y - textContainerOrigin.y))
        let font = (typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        let lineHeight = max(1, lm.defaultLineHeight(for: font))
        let glyphs = lm.glyphRange(for: container)
        var emptyLine: NSRange?
        var occupiedLine: (range: NSRange, endX: CGFloat)?
        lm.enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, glyphRange, stop in
            guard local.y >= line.minY, local.y < line.maxY else { return }
            let characters = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let text = (storage.string as NSString).substring(with: characters)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyLine = characters
            } else if local.x > used.maxX + 12 {
                occupiedLine = (characters, used.maxX)
            }
            stop.pointee = true
        }
        var attributes = typingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .link)
        let style = NSMutableParagraphStyle()
        let x = min(local.x, max(0, container.size.width - 32))
        style.firstLineHeadIndent = x
        style.headIndent = x
        attributes[.paragraphStyle] = style
        attributes[.font] = font

        controller?.textView = self
        if let emptyLine {
            // Change only whitespace on this line, never existing note text.
            var end = NSMaxRange(emptyLine)
            let string = storage.string as NSString
            while end > emptyLine.location, (string.character(at: end - 1) == 10 || string.character(at: end - 1) == 13) { end -= 1 }
            // Keep the line break but give it the indent, so the caret is drawn
            // at the click point and arrow keys can nudge it from there.
            let terminator = string.substring(with: NSRange(location: end, length: NSMaxRange(emptyLine) - end))
            insertText(NSAttributedString(string: terminator, attributes: attributes), replacementRange: emptyLine)
            setSelectedRange(NSRange(location: emptyLine.location, length: 0))
            typingAttributes = attributes
        } else if let occupiedLine {
            let string = storage.string as NSString
            var end = NSMaxRange(occupiedLine.range)
            while end > occupiedLine.range.location, (string.character(at: end - 1) == 10 || string.character(at: end - 1) == 13) { end -= 1 }
            // Only append to the last visual line of a paragraph: inserting a
            // tab into a wrapped line would reflow existing words elsewhere.
            guard end == storage.length || string.character(at: end) == 10 || string.character(at: end) == 13 else { return false }
            let existing = (storage.attribute(.paragraphStyle, at: occupiedLine.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let preceding = NSRange(location: occupiedLine.range.location, length: end - occupiedLine.range.location)
            let lastTab = string.range(of: "\t", options: .backwards, range: preceding)
            var lastUsedStop: CGFloat = -1
            if lastTab.location != NSNotFound {
                let tabGlyphs = lm.glyphRange(forCharacterRange: lastTab, actualCharacterRange: nil)
                lastUsedStop = lm.boundingRect(forGlyphRange: tabGlyphs, in: container).maxX - container.lineFragmentPadding + 0.5
            }
            existing.tabStops = existing.tabStops.filter { $0.location <= lastUsedStop }
            existing.addTabStop(NSTextTab(textAlignment: .left, location: x))
            attributes[.paragraphStyle] = existing
            // AppKit takes tab stops from the beginning of the paragraph,
            // so update the paragraph as one undoable attributed replacement.
            let paragraphRange = string.paragraphRange(for: NSRange(location: occupiedLine.range.location, length: 0))
            let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphRange))
            paragraph.insert(NSAttributedString(string: "\t", attributes: attributes), at: end - paragraphRange.location)
            paragraph.addAttribute(.paragraphStyle, value: existing, range: NSRange(location: 0, length: paragraph.length))
            insertText(paragraph, replacementRange: paragraphRange)
            setSelectedRange(NSRange(location: end + 1, length: 0))
            typingAttributes = attributes
        } else {
            let used = lm.usedRect(for: container)
            guard storage.length == 0 || local.y >= used.maxY else { return false }
            let hasTrailingNewline = storage.string.hasSuffix("\n")
            let baselineY: CGFloat = storage.length == 0 ? 0 : used.maxY
            let lines = min(5000, max(0, Int((local.y - baselineY) / lineHeight)))
            let separator = storage.length > 0 && !hasTrailingNewline ? "\n" : ""
            let padding = separator + String(repeating: "\n", count: lines)
            setSelectedRange(NSRange(location: storage.length, length: 0))
            if !padding.isEmpty {
                var blankAttributes = attributes
                blankAttributes[.paragraphStyle] = NSParagraphStyle.default
                insertText(NSAttributedString(string: padding, attributes: blankAttributes), replacementRange: selectedRange())
            }
            typingAttributes = attributes
        }
        window?.makeFirstResponder(self)
        imageCanvas?.sync()
        return true
    }
}

/// Keeps empty paper available below the last line, including in an empty note.
final class NoteCanvasScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? DaftarTextView)?.updateCanvasExtent()
    }
}

extension DaftarTextView {
    func updateCanvasExtent() {
        guard allowsCanvasTyping, let lm = layoutManager, let container = textContainer else { return }
        lm.ensureLayout(for: container)
        let textBottom = lm.usedRect(for: container).maxY + textContainerOrigin.y
        let height = max(enclosingScrollView?.contentView.bounds.height ?? 0,
                         textBottom + 300, (imageCanvas?.extent ?? 0) + 40)
        let size = NSSize(width: imageCanvas?.minimumWidth ?? 0, height: height)
        guard minSize != size else { return }
        minSize = size
        sizeToFit()
    }
}

extension DaftarTextView {
    /// Left/Right slide a caret that was placed on empty paper, since there
    /// are no characters there for the arrows to step through. Returns false
    /// when ordinary text navigation should handle the key instead.
    func nudgeCanvasCaret(forward: Bool, large: Bool) -> Bool {
        guard allowsCanvasTyping, isEditable, let storage = textStorage,
              let lm = layoutManager, let container = textContainer else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: selection)
        let font = (typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        let step = max(1, (" " as NSString).size(withAttributes: [.font: font]).width) * (large ? 8 : 1)
        let maxX = max(0, container.size.width - 32)
        let isBlank: (NSRange) -> Bool = {
            string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Caret alone on a blank line: move the whole (empty) paragraph's indent.
        if isBlank(paragraph) {
            let current = (paragraph.length > 0
                ? storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                : typingAttributes[.paragraphStyle]) as? NSParagraphStyle ?? .default
            let x = current.firstLineHeadIndent
            let atDocumentEnd = paragraph.location == storage.length
            // A blank line that was never placed keeps normal Right navigation.
            guard x > 0 || !forward || atDocumentEnd else { return false }
            let newX = min(maxX, max(0, x + (forward ? step : -step)))
            guard newX != x else { return !forward && x == 0 ? false : true }
            let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = newX
            style.headIndent = newX
            applyCanvasParagraphStyle(style, to: paragraph)
            return true
        }

        // Caret right after a placed tab at the end of a line: move that tab stop.
        let lineEnd = NSMaxRange(paragraph)
        guard selection.location > paragraph.location,
              string.character(at: selection.location - 1) == 9,
              isBlank(NSRange(location: selection.location, length: lineEnd - selection.location)),
              let current = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
              let stop = current.tabStops.last else { return false }
        let tabGlyphs = lm.glyphRange(forCharacterRange: NSRange(location: selection.location - 1, length: 1), actualCharacterRange: nil)
        let tabStart = lm.boundingRect(forGlyphRange: tabGlyphs, in: container).minX - container.lineFragmentPadding
        guard stop.location > tabStart else { return false }
        let newX = min(maxX, max(tabStart + step, stop.location + (forward ? step : -step)))
        // Can't go further left than the text before it: step back over the tab normally.
        guard newX != stop.location else { return forward }
        let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.tabStops = style.tabStops.dropLast() + [NSTextTab(textAlignment: stop.alignment, location: newX, options: stop.options)]
        applyCanvasParagraphStyle(style, to: paragraph)
        return true
    }

    /// Undoable, attribute-only paragraph style change that keeps the caret in place.
    private func applyCanvasParagraphStyle(_ style: NSParagraphStyle, to paragraph: NSRange) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        var attributes = typingAttributes
        attributes[.paragraphStyle] = style
        if paragraph.length > 0, shouldChangeText(in: paragraph, replacementString: nil) {
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            didChangeText()
        } else if let lm = layoutManager, storage.length > 0 {
            // The empty last line is drawn from typing attributes; re-lay it out.
            lm.invalidateLayout(forCharacterRange: NSRange(location: storage.length - 1, length: 1), actualCharacterRange: nil)
        }
        setSelectedRange(selection)
        typingAttributes = attributes
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(true)
    }
}
