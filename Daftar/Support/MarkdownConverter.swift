//  MarkdownConverter.swift
//  Converts between Daftar's rich text (NSAttributedString/RTFD, the same
//  format a page's `contentData` is stored in) and plain Markdown text, for
//  notebook export/import. Deliberately lossy in both directions - Markdown
//  has no notion of arbitrary text/highlight colors, and this isn't trying
//  to be a full word processor interchange format, just a legible, portable
//  round trip for headings, bold/italic, links, lists, tables, and images.

import AppKit

enum MarkdownConverter {

    // MARK: - Export: rich text -> Markdown

    /// `writeAsset` is called once per embedded image or file attachment,
    /// with its data and a suggested filename; return the path to reference
    /// it by (e.g. "assets/photo.png"), or nil to drop it from the output.
    /// Kept as a callback so this function has no file-system dependency of
    /// its own, which is what makes it straightforward to unit test.
    static func markdown(from attributed: NSAttributedString,
                         writeAsset: @escaping (Data, String) -> String?) -> String {
        guard attributed.length > 0 else { return "" }
        let fullRange = NSRange(location: 0, length: attributed.length)
        var output = ""
        var tableRows: [Int: [Int: String]] = [:]
        var tableColumnCount = 0
        var inTable = false

        func flushTable() {
            defer { inTable = false; tableRows = [:]; tableColumnCount = 0 }
            guard !tableRows.isEmpty, tableColumnCount > 0 else { return }
            for (i, row) in tableRows.keys.sorted().enumerated() {
                let cells = (0..<tableColumnCount).map { (tableRows[row]?[$0] ?? "").replacingOccurrences(of: "\n", with: " ") }
                output += "| " + cells.joined(separator: " | ") + " |\n"
                if i == 0 {
                    output += "| " + Array(repeating: "---", count: tableColumnCount).joined(separator: " | ") + " |\n"
                }
            }
            output += "\n"
        }

        (attributed.string as NSString).enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, subRange, _, _ in
            let safeLocation = min(subRange.location, attributed.length - 1)
            let paraAttrs = attributed.attributes(at: max(safeLocation, 0), effectiveRange: nil)
            let paragraphStyle = paraAttrs[.paragraphStyle] as? NSParagraphStyle

            if let block = paragraphStyle?.textBlocks.first as? NSTextTableBlock {
                inTable = true
                tableColumnCount = max(tableColumnCount, block.startingColumn + 1)
                tableRows[block.startingRow, default: [:]][block.startingColumn] =
                    inlineMarkdown(for: attributed, in: subRange, writeAsset: writeAsset)
                return
            } else if inTable {
                flushTable()
            }

            let fontSize = (paraAttrs[.font] as? NSFont)?.pointSize.rounded() ?? 13
            let headingPrefix: String
            switch fontSize {
            case 26: headingPrefix = "# "
            case 20: headingPrefix = "## "
            case 16: headingPrefix = "### "
            default: headingPrefix = ""
            }

            // Headings are already bold by being headings - if we also ran
            // them through the usual bold-trait check, a Heading 1 (a bold
            // font) would come out as "# **Title**" instead of "# Title".
            var line = inlineMarkdown(for: attributed, in: subRange, writeAsset: writeAsset,
                                      suppressBold: !headingPrefix.isEmpty)
            if line.hasPrefix("\u{2022} ") {
                line = "- " + line.dropFirst(2)
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                output += "\n"
            } else {
                output += headingPrefix + line + "\n"
                if !headingPrefix.isEmpty { output += "\n" }
            }
        }
        flushTable()
        return output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func inlineMarkdown(for attributed: NSAttributedString, in range: NSRange,
                                       writeAsset: @escaping (Data, String) -> String?,
                                       suppressBold: Bool = false) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        attributed.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let (data, name, isImage) = assetPayload(for: attachment), let path = writeAsset(data, name) {
                    result += isImage ? "![](\(path))" : "[\(name)](\(path))"
                }
                return
            }

            var text = (attributed.string as NSString).substring(with: subRange)
            guard !text.isEmpty, text != "\u{FFFC}" else { return }

            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.italicFontMask) { text = "*\(text)*" }
                if traits.contains(.boldFontMask), !suppressBold { text = "**\(text)**" }
            }
            if let url = attrs[.link] as? URL {
                text = "[\(text)](\(url.absoluteString))"
            } else if let urlString = attrs[.link] as? String, !urlString.isEmpty {
                text = "[\(text)](\(urlString))"
            }
            result += text
        }
        return result
    }

    private static func assetPayload(for attachment: NSTextAttachment) -> (Data, String, Bool)? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
            return (data, wrapper.preferredFilename ?? "attachment", NSImage(data: data) != nil)
        }
        if let image = attachment.image, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image.png", true)
        }
        return nil
    }

    // MARK: - Import: Markdown -> rich text

    static func attributedString(fromMarkdown text: String) -> NSAttributedString {
        let normalAttrs: [NSAttributedString.Key: Any] = [.font: EditorController.defaultFont, .foregroundColor: NSColor.textColor]
        guard let parsed = try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )), !parsed.characters.isEmpty else {
            return NSAttributedString(string: text, attributes: normalAttrs)
        }

        let result = NSMutableAttributedString()
        var previousIntent: PresentationIntent?
        var previousWasListItem = false
        let fm = NSFontManager.shared

        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            let intent = run.presentationIntent

            var headingLevel: Int?
            var isOrderedItem = false
            var isUnorderedItem = false
            var ordinal: Int?
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): headingLevel = level
                case .orderedList: isOrderedItem = true
                case .unorderedList: isUnorderedItem = true
                case .listItem(let n): ordinal = n
                default: break
                }
            }

            var font: NSFont
            switch headingLevel {
            case 1: font = EditorController.TextStyle.heading1.font
            case 2: font = EditorController.TextStyle.heading2.font
            case 3: font = EditorController.TextStyle.heading3.font
            default: font = EditorController.defaultFont
            }
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.stronglyEmphasized) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = fm.convert(font, toHaveTrait: .italicFontMask) }

            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            // A new block-level element starts on its own line, with a blank
            // line between them - except consecutive items in the same list,
            // which stay tight against each other.
            let isListItem = isOrderedItem || isUnorderedItem
            if result.length > 0, intent != previousIntent {
                let separator = (isListItem && previousWasListItem) ? "\n" : "\n\n"
                result.append(NSAttributedString(string: separator, attributes: [.font: EditorController.defaultFont]))
            }

            var runText = substring
            if isOrderedItem, let ordinal, result.length == 0 || previousIntent != intent {
                runText = "\(ordinal). " + runText
            } else if isUnorderedItem, result.length == 0 || previousIntent != intent {
                runText = "\u{2022} " + runText
            }

            result.append(NSAttributedString(string: runText, attributes: attrs))
            previousIntent = intent
            previousWasListItem = isListItem
        }

        return result.length > 0 ? result : NSAttributedString(string: text, attributes: normalAttrs)
    }
}
