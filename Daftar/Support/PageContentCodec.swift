import AppKit
import SwiftData

enum PageContentCodec {
    enum ContentError: LocalizedError {
        case invalidSpreadsheet
        var errorDescription: String? { "The spreadsheet data is damaged or has unsupported dimensions." }
    }

    static func richText(_ data: Data?) throws -> NSAttributedString {
        guard let data else { return NSAttributedString(string: "") }
        return try NSAttributedString(data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }

    static func spreadsheet(_ data: Data?) throws -> SpreadsheetData {
        guard let data else { return .empty }
        let result = try JSONDecoder().decode(SpreadsheetData.self, from: data)
        guard (1...SpreadsheetData.maxRows).contains(result.rows),
              (1...SpreadsheetData.maxColumns).contains(result.columns),
              result.cells.keys.allSatisfy({ key in
                  guard let ref = CellReference.parse(key) else { return false }
                  return ref.row < result.rows && ref.column < result.columns && key == key.uppercased()
              }) else { throw ContentError.invalidSpreadsheet }
        return result
    }

    @MainActor static func validate(_ page: Page) throws {
        if page.kind == .spreadsheet { _ = try spreadsheet(page.spreadsheetData) }
        else {
            let text = try richText(page.contentData)
            if let data = page.contentData { handOff(text, decodedFrom: data) }
        }
    }

    // MARK: - One decode per page open

    /// The text `validate` just decoded, waiting for the editor that opens
    /// next - so opening a page decodes its RTFD once, not twice. Used at
    /// most once: an editor owns (and mutates) its attachments, so two
    /// editors must never share one decoded copy.
    @MainActor private static var handedOff: (data: Data, text: NSAttributedString)?

    @MainActor private static func handOff(_ text: NSAttributedString, decodedFrom data: Data) {
        handedOff = (data, text)
    }

    /// `data` decoded, reusing the copy `validate` made for the same bytes.
    @MainActor static func richTextForEditor(_ data: Data) throws -> NSAttributedString {
        if let handedOff, handedOff.data == data {
            self.handedOff = nil
            return handedOff.text
        }
        handedOff = nil
        return try richText(data)
    }

    static func remapLinks(_ data: Data, ids: [UUID: UUID]) throws -> Data {
        guard let decoded = try? richText(data) else { return data }
        let text = NSMutableAttributedString(attributedString: decoded)
        text.remapPageLinks(ids)
        return try rtfd(text)
    }

    static func linkIDs(in text: NSAttributedString) -> [UUID] { text.linkedPageIDs }

    /// The one RTFD encoder used for page content everywhere.
    static func rtfd(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    /// Reset is only permitted after a successful backup of the untouched bytes.
    @MainActor
    static func backUpAndReset(_ page: Page, to url: URL, context: ModelContext) throws {
        let original = page.kind == .spreadsheet ? page.spreadsheetData : page.contentData
        try (original ?? Data()).write(to: url, options: .atomic)
        let oldText = page.plainText
        let oldLinks = page.outgoingLinkIDs
        let oldDate = page.updatedAt
        if page.kind == .spreadsheet { page.spreadsheetData = nil }
        else { page.contentData = nil }
        page.plainText = ""
        page.outgoingLinkIDs = []
        page.updatedAt = Date()
        do { try context.save() }
        catch {
            if page.kind == .spreadsheet { page.spreadsheetData = original }
            else { page.contentData = original }
            page.plainText = oldText
            page.outgoingLinkIDs = oldLinks
            page.updatedAt = oldDate
            throw error
        }
    }
}
