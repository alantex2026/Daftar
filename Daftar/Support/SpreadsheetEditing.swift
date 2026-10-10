import Foundation

struct CellRange: Equatable {
    var firstRow: Int
    var lastRow: Int
    var firstColumn: Int
    var lastColumn: Int
    init(_ text: String) throws {
        let parts = text.uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = CellReference.parse(String(parts[0])),
              let last = CellReference.parse(String(parts.last!)),
              max(first.row, last.row) < SpreadsheetData.maxRows,
              max(first.column, last.column) < SpreadsheetData.maxColumns else { throw SpreadsheetEditing.Error.invalidRange }
        firstRow = min(first.row, last.row); lastRow = max(first.row, last.row)
        firstColumn = min(first.column, last.column); lastColumn = max(first.column, last.column)
    }
}

enum SpreadsheetEditing {
    enum Error: LocalizedError {
        case invalidRange, tooLarge, invalidCSV
        var errorDescription: String? {
            switch self {
            case .invalidRange: return "Enter a valid range such as A1:C5."
            case .tooLarge: return "The spreadsheet supports up to 200 rows and 26 columns."
            case .invalidCSV: return "The CSV contains an unfinished or misplaced quoted field."
            }
        }
    }

    static func parseDelimited(_ text: String, separator: Character = ",") throws -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = []; var row: [String] = []; var field = ""
        var quoted = false; var closedQuote = false; var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(char) }
            } else if char == separator {
                row.append(field); field = ""; closedQuote = false
            } else if char == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false
            } else if char == "\"" {
                guard field.isEmpty && !closedQuote else { throw Error.invalidCSV }
                quoted = true
            } else {
                guard !closedQuote else { throw Error.invalidCSV }
                field.append(char)
            }
            index += 1
        }
        guard !quoted else { throw Error.invalidCSV }
        if !row.isEmpty || !field.isEmpty || closedQuote || chars.last != "\n" { row.append(field); rows.append(row) }
        return rows
    }

    static func delimited(_ rows: [[String]], separator: Character = ",") -> String {
        rows.map { row in
            row.map { field in
                if field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: String(separator))
        }.joined(separator: "\n")
    }

    static func importCSV(_ text: String) throws -> SpreadsheetData {
        let values = try parseDelimited(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text)
        var result = SpreadsheetData(rows: max(1, values.count), columns: max(1, values.map(\.count).max() ?? 1), cells: [:])
        guard result.rows <= SpreadsheetData.maxRows, result.columns <= SpreadsheetData.maxColumns else { throw Error.tooLarge }
        try paste(values, into: &result, at: "A1")
        return result
    }

    static func copy(_ data: SpreadsheetData, range: CellRange) -> [[String]] {
        (range.firstRow...range.lastRow).map { row in
            (range.firstColumn...range.lastColumn).map { data.cells[CellReference.name(row: row, column: $0)] ?? "" }
        }
    }

    static func exportCSV(_ data: SpreadsheetData) -> String {
        delimited((0..<data.rows).map { row in (0..<data.columns).map { data.cells[CellReference.name(row: row, column: $0)] ?? "" } })
    }

    static func paste(_ values: [[String]], into data: inout SpreadsheetData, at reference: String) throws {
        guard let start = CellReference.parse(reference.uppercased()) else { throw Error.invalidRange }
        let rows = start.row + values.count
        let columns = start.column + (values.map(\.count).max() ?? 0)
        guard rows <= SpreadsheetData.maxRows, columns <= SpreadsheetData.maxColumns else { throw Error.tooLarge }
        data.rows = max(data.rows, rows); data.columns = max(data.columns, columns)
        for (r, row) in values.enumerated() {
            for (c, value) in row.enumerated() {
                let ref = CellReference.name(row: r + start.row, column: c + start.column)
                data.cells[ref] = value.isEmpty ? nil : value
            }
        }
    }

    /// Shift references with rows, and explicitly invalidate references to deleted cells.
    static func deleteRows(_ range: ClosedRange<Int>, from data: SpreadsheetData) throws -> SpreadsheetData {
        guard range.lowerBound >= 0, range.upperBound < data.rows, range.count < data.rows else { throw Error.invalidRange }
        var result = SpreadsheetData(rows: data.rows - range.count, columns: data.columns, cells: [:])
        let regex = try NSRegularExpression(pattern: "(?i)\\b([A-Z]+)([1-9][0-9]*)\\b")
        for (ref, raw) in data.cells {
            guard let cell = CellReference.parse(ref), !range.contains(cell.row) else { continue }
            let row = cell.row > range.upperBound ? cell.row - range.count : cell.row
            var value = raw
            if raw.hasPrefix("=") {
                let text = raw as NSString
                for match in regex.matches(in: raw, range: NSRange(location: 0, length: text.length)).reversed() {
                    guard let target = CellReference.parse(text.substring(with: match.range)) else { continue }
                    let replacement: String
                    if range.contains(target.row) { replacement = "#REF!" }
                    else { replacement = CellReference.name(row: target.row > range.upperBound ? target.row - range.count : target.row, column: target.column) }
                    if let swiftRange = Range(match.range, in: value) { value.replaceSubrange(swiftRange, with: replacement) }
                }
            }
            result.cells[CellReference.name(row: row, column: cell.column)] = value
        }
        return result
    }
}
