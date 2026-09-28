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

        var font: NSFont {
            switch self {
            case .normal:    return NSFont.systemFont(ofSize: 13)
            case .heading1:  return NSFont.systemFont(ofSize: 26, weight: .bold)
            case .heading2:  return NSFont.systemFont(ofSize: 20, weight: .semibold)
            case .heading3:  return NSFont.systemFont(ofSize: 16, weight: .semibold)
            case .monospace: return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            }
        }
    }

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
        edit(range) { $0.addAttribute(.font, value: style.font, range: range) }
        var attrs = tv.typingAttributes
        attrs[.font] = style.font
        tv.typingAttributes = attrs
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
