//  EditorController+Formatting.swift
//  Bold, italic, underline, font size, colors, paragraph styles and alignment.

import AppKit

extension EditorController {
    // MARK: - Bold / Italic

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()

        // Nothing selected: change what the NEXT typed characters will look like.
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
            attrs[.font] = fm.traits(of: font).contains(trait)
                ? fm.convert(font, toNotHaveTrait: trait)
                : fm.convert(font, toHaveTrait: trait)
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        let runs = fontRuns(in: range)
        let allHave = runs.allSatisfy { fm.traits(of: $0.1).contains(trait) }
        edit(range) { storage in
            for (r, f) in runs {
                let newFont = allHave ? fm.convert(f, toNotHaveTrait: trait)
                                      : fm.convert(f, toHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: r)
            }
        }
    }

    func toggleBold()   { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    // MARK: - Underline

    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = (attrs[.underlineStyle] as? Int) ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allUnderlined = false }
        }
        edit(range) { storage in
            storage.addAttribute(.underlineStyle,
                                 value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
    }

    // MARK: - Strikethrough

    func toggleStrikethrough() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = (attrs[.strikethroughStyle] as? Int) ?? 0
            attrs[.strikethroughStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        var allStruck = true
        storage.enumerateAttribute(.strikethroughStyle, in: range, options: []) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allStruck = false }
        }
        edit(range) { storage in
            storage.addAttribute(.strikethroughStyle,
                                 value: allStruck ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
    }

    // MARK: - Font size

    func setFontSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
            attrs[.font] = fm.convert(font, toSize: size)
            tv.typingAttributes = attrs
            fontSize = size
            return
        }

        let runs = fontRuns(in: range)
        edit(range) { storage in
            for (r, f) in runs {
                storage.addAttribute(.font, value: fm.convert(f, toSize: size), range: r)
            }
        }
    }

    func stepFontSize(by delta: CGFloat) {
        setFontSize(max(6, min(200, fontSize + delta)))
    }

    // MARK: - Colors

    func setTextColor(_ color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.foregroundColor] = color
            tv.typingAttributes = attrs
            return
        }
        edit(range) { $0.addAttribute(.foregroundColor, value: color, range: range) }
    }

    func setHighlight(_ color: NSColor?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if let color { attrs[.backgroundColor] = color }
            else { attrs.removeValue(forKey: .backgroundColor) }
            tv.typingAttributes = attrs
            return
        }
        edit(range) { storage in
            if let color { storage.addAttribute(.backgroundColor, value: color, range: range) }
            else { storage.removeAttribute(.backgroundColor, range: range) }
        }
    }

    // MARK: - Paragraph styles (Normal, Heading 1, ...)

    enum TextStyle: String, CaseIterable, Identifiable {
        case normal    = "Normal"
        case heading1  = "Heading 1"
        case heading2  = "Heading 2"
        case heading3  = "Heading 3"
        case monospace = "Code"

        var id: String { rawValue }

        /// Normal text uses the default font chosen in Settings.
        var font: NSFont {
            switch self {
            case .normal:    return EditorController.defaultFont
            case .heading1:  return NSFont.systemFont(ofSize: 26, weight: .bold)
            case .heading2:  return NSFont.systemFont(ofSize: 20, weight: .semibold)
            case .heading3:  return NSFont.systemFont(ofSize: 16, weight: .semibold)
            case .monospace: return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            }
        }

        static let headings: [TextStyle] = [.heading1, .heading2, .heading3]

        /// 1-3 when `font` is one of the heading styles, else nil. RTFD keeps
        /// no heading attribute (`headerLevel` is dropped), so a heading is
        /// recognized by its exact size *and* bold/semibold weight - plain
        /// 16pt body text isn't a Heading 3. The table of contents and
        /// Markdown export both use this one rule.
        nonisolated static func headingLevel(of font: NSFont) -> Int? {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weight = (traits?[.weight] as? CGFloat) ?? 0
            let isBold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                || weight >= NSFont.Weight.semibold.rawValue - 0.01
            guard isBold else { return nil }
            let sizes: [CGFloat] = [26, 20, 16]
            return sizes.firstIndex { abs(font.pointSize - $0) < 0.5 }.map { $0 + 1 }
        }
    }

    /// Applies a paragraph style. Italic text stays italic; bold stays bold
    /// unless it only came from the heading the text is leaving.
    func applyStyle(_ style: TextStyle) {
        guard let tv = textView else { return }
        styleName = style.rawValue
        var range = tv.selectedRange()
        if range.length == 0 { range = currentParagraphRange() }

        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = style.font
            tv.typingAttributes = attrs
            fontSize = style.font.pointSize
            return
        }
        let runs = fontRuns(in: range)
        edit(range) { storage in
            for (runRange, runFont) in runs {
                storage.addAttribute(.font, value: Self.font(for: style, keepingTraitsOf: runFont), range: runRange)
            }
        }
        var attrs = tv.typingAttributes
        attrs[.font] = runs.last.map { Self.font(for: style, keepingTraitsOf: $0.1) } ?? style.font
        tv.typingAttributes = attrs
    }

    private static func font(for style: TextStyle, keepingTraitsOf original: NSFont) -> NSFont {
        let fm = NSFontManager.shared
        let traits = fm.traits(of: original)
        var font = style.font
        if traits.contains(.italicFontMask) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        if traits.contains(.boldFontMask), TextStyle.headingLevel(of: original) == nil,
           !TextStyle.headings.contains(style) {
            font = fm.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
    }

    // MARK: - Alignment

    func setAlignment(_ newAlignment: NSTextAlignment) {
        guard let tv = textView else { return }
        let range = currentParagraphRange()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        tv.setAlignment(newAlignment, range: range)
        tv.didChangeText()
        alignment = newAlignment
    }
}
