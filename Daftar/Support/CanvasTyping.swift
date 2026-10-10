import AppKit

/// Where a click on empty paper wants the next typed text to go. Nothing is
/// written to the note until the person actually types or pastes, so stray
/// clicks never leave blank lines, tabs or undo steps behind.
struct CanvasPlacement {
    enum Kind {
        /// A blank line that gets indented to the click.
        case blankLine(NSRange)
        /// Right of the last visual line of a paragraph: a tab stop is added.
        case afterLine(NSRange, end: Int)
        /// Below all text: padding line breaks are added first.
        case belowText(padding: String)
    }

    var kind: Kind
    /// Indent in the same coordinates as `NSParagraphStyle.headIndent`.
    var x: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    /// Caret line in text-container coordinates.
    var caretTop: CGFloat
    var caretHeight: CGFloat
    /// Real selection location while the placement is pending.
    var anchor: Int
    /// Note length when resolved; any edit makes the placement stale.
    var length: Int
}

extension DaftarTextView {
    /// Clicks this close to the left margin of a blank line are ordinary
    /// clicks, not a request for an indent.
    private static let canvasIndentSnap: CGFloat = 8

    /// Shows the caret at an empty canvas location. The paragraph indent, tab
    /// or line breaks that put text there are only added on the first edit
    /// (`materializePendingCanvasPlacement`), keeping the result ordinary
    /// rich text that is searchable, undoable and RTFD/export compatible.
    @discardableResult
    func placeInsertionPointOnCanvas(at point: NSPoint) -> Bool {
        guard let placement = resolveCanvasPlacement(at: point) else { return false }
        let font = (typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        var attributes = typingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: .paragraphStyle)
        attributes[.font] = font

        controller?.textView = self
        window?.makeFirstResponder(self)
        clearPendingCanvasPlacement()
        setSelectedRange(NSRange(location: placement.anchor, length: 0))
        // Keep the font the person was typing with; the indent is added later.
        typingAttributes = attributes
        pendingCanvasPlacement = placement
        refreshCanvasCaret()
        imageCanvas?.sync()
        return true
    }

    /// Read-only hit test for `placeInsertionPointOnCanvas`.
    func resolveCanvasPlacement(at point: NSPoint) -> CanvasPlacement? {
        guard allowsCanvasTyping, isEditable, let storage = textStorage,
              let lm = layoutManager, let container = textContainer else { return nil }
        lm.ensureLayout(for: container)
        let padding = container.lineFragmentPadding
        let local = NSPoint(x: max(0, point.x - textContainerOrigin.x),
                            y: max(0, point.y - textContainerOrigin.y))
        let font = (typingAttributes[.font] as? NSFont) ?? EditorController.defaultFont
        let lineHeight = max(1, lm.defaultLineHeight(for: font))
        let maxX = max(0, container.size.width - 32)
        // Indents are measured from inside the line fragment padding.
        let clickX = min(maxX, max(0, local.x - padding))
        let string = storage.string as NSString
        let isLineBreak: (Int) -> Bool = { string.character(at: $0) == 10 || string.character(at: $0) == 13 }

        var emptyLine: (range: NSRange, rect: NSRect)?
        var occupiedLine: (range: NSRange, rect: NSRect, endX: CGFloat)?
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: container)) { line, used, _, glyphRange, stop in
            guard local.y >= line.minY, local.y < line.maxY else { return }
            let characters = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if string.substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyLine = (characters, line)
            } else if local.x > used.maxX + 12 {
                occupiedLine = (characters, line, used.maxX - padding)
            }
            stop.pointee = true
        }

        if let emptyLine {
            let x = clickX < Self.canvasIndentSnap ? 0 : clickX
            return CanvasPlacement(kind: .blankLine(emptyLine.range), x: x, minX: 0, maxX: maxX,
                                   caretTop: emptyLine.rect.maxY - min(lineHeight, emptyLine.rect.height),
                                   caretHeight: min(lineHeight, emptyLine.rect.height),
                                   anchor: emptyLine.range.location, length: storage.length)
        }
        if let occupiedLine {
            var end = NSMaxRange(occupiedLine.range)
            while end > occupiedLine.range.location, isLineBreak(end - 1) { end -= 1 }
            // Only append to the last visual line of a paragraph: inserting a
            // tab into a wrapped line would reflow existing words elsewhere.
            guard end == storage.length || isLineBreak(end) else { return nil }
            let minX = min(maxX, occupiedLine.endX + 1)
            return CanvasPlacement(kind: .afterLine(occupiedLine.range, end: end), x: max(minX, clickX),
                                   minX: minX, maxX: maxX,
                                   caretTop: occupiedLine.rect.maxY - min(lineHeight, occupiedLine.rect.height),
                                   caretHeight: min(lineHeight, occupiedLine.rect.height),
                                   anchor: end, length: storage.length)
        }

        // Below all text. The empty line after a final line break is not a
        // line fragment, so start from it when it exists.
        let hasExtraLine = lm.extraLineFragmentTextContainer === container
        let textBottom = hasExtraLine ? lm.extraLineFragmentRect.minY : lm.usedRect(for: container).maxY
        guard storage.length == 0 || local.y >= textBottom else { return nil }
        let lines = min(5000, max(0, Int((local.y - textBottom) / lineHeight)))
        let separator = hasExtraLine || storage.length == 0 ? "" : "\n"
        // Without a trailing line break the separator itself starts the first new line.
        let x = clickX < Self.canvasIndentSnap ? 0 : clickX
        return CanvasPlacement(kind: .belowText(padding: separator + String(repeating: "\n", count: lines)),
                               x: x, minX: 0, maxX: maxX,
                               caretTop: textBottom + CGFloat(lines) * lineHeight, caretHeight: lineHeight,
                               anchor: storage.length, length: storage.length)
    }

    /// Writes a pending placement into the note right before the first edit.
    /// Returns true when the selection moved to the placed caret.
    @discardableResult
    func materializePendingCanvasPlacement() -> Bool {
        guard let placement = pendingCanvasPlacement else { return false }
        // Cleared first: the insertions below re-enter this method.
        pendingCanvasPlacement = nil
        guard let storage = textStorage, let lm = layoutManager, let container = textContainer,
              storage.length == placement.length,
              selectedRange() == NSRange(location: placement.anchor, length: 0) else { return false }
        var attributes = typingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .link)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = placement.x
        style.headIndent = placement.x
        attributes[.paragraphStyle] = style
        let string = storage.string as NSString

        switch placement.kind {
        case .blankLine(let emptyLine):
            guard placement.x > 0 else { break }
            // Change only whitespace on this line, never existing note text.
            var end = NSMaxRange(emptyLine)
            while end > emptyLine.location, (string.character(at: end - 1) == 10 || string.character(at: end - 1) == 13) { end -= 1 }
            if emptyLine.length > 0 {
                // Keep the line break but give it the indent.
                let terminator = string.substring(with: NSRange(location: end, length: NSMaxRange(emptyLine) - end))
                insertText(NSAttributedString(string: terminator, attributes: attributes), replacementRange: emptyLine)
            }
            setSelectedRange(NSRange(location: emptyLine.location, length: 0))
            typingAttributes = attributes
        case .afterLine(let line, let end):
            let existing = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let preceding = NSRange(location: line.location, length: end - line.location)
            let lastTab = string.range(of: "\t", options: .backwards, range: preceding)
            var lastUsedStop: CGFloat = -1
            if lastTab.location != NSNotFound {
                let tabGlyphs = lm.glyphRange(forCharacterRange: lastTab, actualCharacterRange: nil)
                lastUsedStop = lm.boundingRect(forGlyphRange: tabGlyphs, in: container).maxX - container.lineFragmentPadding + 0.5
            }
            existing.tabStops = existing.tabStops.filter { $0.location <= lastUsedStop }
            existing.addTabStop(NSTextTab(textAlignment: .left, location: placement.x))
            attributes[.paragraphStyle] = existing
            // AppKit takes tab stops from the beginning of the paragraph,
            // so update the paragraph as one undoable attributed replacement.
            let paragraphRange = string.paragraphRange(for: NSRange(location: line.location, length: 0))
            let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphRange))
            paragraph.insert(NSAttributedString(string: "\t", attributes: attributes), at: end - paragraphRange.location)
            paragraph.addAttribute(.paragraphStyle, value: existing, range: NSRange(location: 0, length: paragraph.length))
            insertText(paragraph, replacementRange: paragraphRange)
            setSelectedRange(NSRange(location: end + 1, length: 0))
            typingAttributes = attributes
        case .belowText(let padding):
            if !padding.isEmpty {
                var blankAttributes = attributes
                blankAttributes[.paragraphStyle] = NSParagraphStyle.default
                insertText(NSAttributedString(string: padding, attributes: blankAttributes),
                           replacementRange: NSRange(location: storage.length, length: 0))
            }
            setSelectedRange(NSRange(location: storage.length, length: 0))
            typingAttributes = attributes
        }
        imageCanvas?.sync()
        return true
    }

    /// Drops a pending placement without touching the note.
    func clearPendingCanvasPlacement() {
        guard pendingCanvasPlacement != nil else { return }
        pendingCanvasPlacement = nil
        refreshCanvasCaret()
    }

    /// Caret rect for a pending placement, in view coordinates.
    var pendingCanvasCaretRect: NSRect? {
        guard let placement = pendingCanvasPlacement, let container = textContainer else { return nil }
        return NSRect(x: textContainerOrigin.x + container.lineFragmentPadding + placement.x,
                      y: textContainerOrigin.y + placement.caretTop,
                      width: 1, height: placement.caretHeight)
    }

    /// Redraws so the caret moves between AppKit's spot and a pending one.
    func refreshCanvasCaret() {
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
        updateInsertionPointStateAndRestartTimer(true)
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

        // A caret that is only shown (nothing typed yet) just moves on screen.
        if var placement = pendingCanvasPlacement {
            let newX = min(placement.maxX, max(placement.minX, placement.x + (forward ? step : -step)))
            guard newX != placement.x else {
                // Past the left edge: hand back to ordinary navigation.
                if forward { return true }
                clearPendingCanvasPlacement()
                return false
            }
            placement.x = newX
            pendingCanvasPlacement = placement
            refreshCanvasCaret()
            return true
        }
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
