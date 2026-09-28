//  EditorController+Insert.swift
//  Inserting dates, links, file attachments and tables.

import AppKit
import UniformTypeIdentifiers

extension EditorController {
    // MARK: - Inserting things

    func insert(_ attributed: NSAttributedString) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: attributed.string) else { return }
        storage.replaceCharacters(in: range, with: attributed)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        refreshCounts()
    }

    func insertDate(includeTime: Bool) {
        guard let tv = textView else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = includeTime ? .short : .none
        insert(NSAttributedString(string: formatter.string(from: Date()),
                                  attributes: tv.typingAttributes))
    }

    func applyLink(_ urlString: String) {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let tv = textView else { return }

        let range = tv.selectedRange()
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        if range.length == 0 {
            var attrs = tv.typingAttributes
            linkAttrs.forEach { attrs[$0.key] = $0.value }
            insert(NSAttributedString(string: text, attributes: attrs))
        } else {
            edit(range) { $0.addAttributes(linkAttrs, range: range) }
        }
    }


    func insertFileAttachment(from url: URL) {
        guard let wrapper = try? FileWrapper(url: url, options: .immediate) else {
            errorMessage = "Couldn't attach \u{201C}\(url.lastPathComponent)\u{201D}."
            return
        }
        wrapper.preferredFilename = url.lastPathComponent
        let result = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        result.addAttribute(.link, value: Self.fileAttachmentURL, range: NSRange(location: 0, length: result.length))
        insert(result)
    }

    func insertTable(rows: Int, columns: Int) {
        guard let tv = textView else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let font = (tv.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
        let result = NSMutableAttributedString()

        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table,
                                             startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                result.append(NSAttributedString(string: " \n",
                                                 attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        insert(result)
    }
}
