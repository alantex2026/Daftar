//  EditorControllerTests.swift
//  Coverage for the checklist parsing/marking helpers, which are pure
//  enough to test without a live NSTextView.

import XCTest
import AppKit
@testable import Daftar

final class EditorControllerTests: XCTestCase {

    func testChecklistContentReturnsNilForPlainText() {
        XCTAssertNil(EditorController.checklistContent(of: "just a line"))
    }

    func testChecklistContentParsesUncheckedLine() {
        let result = EditorController.checklistContent(of: "\u{2610} buy milk")
        XCTAssertEqual(result?.checked, false)
        XCTAssertEqual(result?.text, "buy milk")
    }

    func testChecklistContentParsesCheckedLine() {
        let result = EditorController.checklistContent(of: "\u{2611} buy milk")
        XCTAssertEqual(result?.checked, true)
        XCTAssertEqual(result?.text, "buy milk")
    }

    func testMarkChecklistGlyphsAddsLinkOnlyToChecklistLines() {
        let storage = NSTextStorage(string: "\u{2610} task one\nplain line\n\u{2611} task two")
        let full = NSRange(location: 0, length: storage.length)

        EditorController.markChecklistGlyphs(in: full, storage: storage)

        // First glyph (task one, unchecked) is linked.
        let firstLink = storage.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(firstLink?.absoluteString, "daftar://checklist-toggle")

        // "plain line" never gets a link attribute anywhere in its range.
        let plainLineStart = (storage.string as NSString).range(of: "plain line").location
        XCTAssertNil(storage.attribute(.link, at: plainLineStart, effectiveRange: nil))

        // Second glyph (task two, checked) is also linked.
        let secondGlyphIndex = (storage.string as NSString).range(of: "\u{2611}").location
        let secondLink = storage.attribute(.link, at: secondGlyphIndex, effectiveRange: nil) as? URL
        XCTAssertEqual(secondLink?.absoluteString, "daftar://checklist-toggle")
    }
}
