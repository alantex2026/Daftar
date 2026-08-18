//  MarkdownConverterTests.swift
//  Round-trip and edge-case coverage for the rich-text <-> Markdown
//  converter behind notebook export/import.

import XCTest
import AppKit
@testable import Daftar

final class MarkdownConverterTests: XCTestCase {

    // MARK: - Export

    func testExportAppliesBoldAndItalicMarkers() {
        let text = NSMutableAttributedString(string: "bold italic")
        text.addAttribute(.font, value: NSFontManager.shared.convert(EditorController.defaultFont, toHaveTrait: .boldFontMask),
                          range: NSRange(location: 0, length: 4))
        text.addAttribute(.font, value: NSFontManager.shared.convert(EditorController.defaultFont, toHaveTrait: .italicFontMask),
                          range: NSRange(location: 5, length: 6))

        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, _ in nil })

        XCTAssertTrue(markdown.contains("**bold**"), markdown)
        XCTAssertTrue(markdown.contains("*italic*"), markdown)
    }

    func testExportConvertsHeadingFontSizesToHashPrefixes() {
        func heading(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: "Title", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold)])
        }
        XCTAssertTrue(MarkdownConverter.markdown(from: heading(26), writeAsset: { _, _ in nil }).hasPrefix("# Title"))
        XCTAssertTrue(MarkdownConverter.markdown(from: heading(20), writeAsset: { _, _ in nil }).hasPrefix("## Title"))
        XCTAssertTrue(MarkdownConverter.markdown(from: heading(16), writeAsset: { _, _ in nil }).hasPrefix("### Title"))
    }

    func testExportConvertsBulletMarkerToMarkdownDash() {
        let text = NSAttributedString(string: "\u{2022} first line\n\u{2022} second line")
        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, _ in nil })
        XCTAssertTrue(markdown.contains("- first line"), markdown)
        XCTAssertTrue(markdown.contains("- second line"), markdown)
    }

    func testExportLeavesNumberedListMarkersAsIs() {
        let text = NSAttributedString(string: "1. first\n2. second")
        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, _ in nil })
        XCTAssertTrue(markdown.contains("1. first"), markdown)
        XCTAssertTrue(markdown.contains("2. second"), markdown)
    }

    func testExportConvertsLinkAttributeToMarkdownLink() {
        let text = NSMutableAttributedString(string: "visit here")
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 6, length: 4))
        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, _ in nil })
        XCTAssertTrue(markdown.contains("[here](https://example.com)"), markdown)
    }

    func testExportWritesImageAttachmentThroughCallback() {
        // Matches how EditorController.insertImage(from:) actually builds an
        // attachment: a FileWrapper around real image data with a real
        // filename, not a bare `.image` (which is what "paste from Finder"
        // produces, not what Daftar's own insert flow produces).
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "photo.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)

        let text = NSAttributedString(attachment: attachment)
        var writtenNames: [String] = []
        let markdown = MarkdownConverter.markdown(from: text, writeAsset: { _, name in
            writtenNames.append(name)
            return "assets/\(name)"
        })

        XCTAssertEqual(writtenNames, ["photo.png"])
        XCTAssertTrue(markdown.contains("![](assets/photo.png)"), markdown)
    }

    // MARK: - Import

    func testImportAppliesHeadingFont() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "# Title")
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, EditorController.TextStyle.heading1.font.pointSize)
    }

    func testImportAppliesBoldTrait() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "**bold word**")
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(NSFontManager.shared.traits(of: font!).contains(.boldFontMask))
    }

    func testImportPrefixesUnorderedListItemsWithBulletMarker() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "- one\n- two")
        XCTAssertTrue(attributed.string.contains("\u{2022} one"), attributed.string)
        XCTAssertTrue(attributed.string.contains("\u{2022} two"), attributed.string)
    }

    func testImportPrefixesOrderedListItemsWithNumber() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "1. one\n2. two")
        XCTAssertTrue(attributed.string.contains("1. one"), attributed.string)
        XCTAssertTrue(attributed.string.contains("2. two"), attributed.string)
    }

    func testImportAppliesLinkAttribute() {
        let attributed = MarkdownConverter.attributedString(fromMarkdown: "[here](https://example.com)")
        let link = attributed.attribute(.link, at: 0, effectiveRange: nil)
        XCTAssertNotNil(link)
    }

    // MARK: - Round trip

    func testRoundTripPreservesPlainTextContent() {
        let original = NSMutableAttributedString(string: "Hello world")
        original.addAttribute(.font, value: NSFontManager.shared.convert(EditorController.defaultFont, toHaveTrait: .boldFontMask),
                              range: NSRange(location: 0, length: 5))

        let markdown = MarkdownConverter.markdown(from: original, writeAsset: { _, _ in nil })
        let reimported = MarkdownConverter.attributedString(fromMarkdown: markdown)

        XCTAssertEqual(reimported.string.trimmingCharacters(in: .whitespacesAndNewlines), "Hello world")
    }
}
