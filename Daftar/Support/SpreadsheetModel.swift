//  SpreadsheetModel.swift
//  The data model and formula engine behind a `.spreadsheet` page - kept
//  free of AppKit/SwiftUI on purpose so it's plain, fast-to-test logic;
//  SpreadsheetView.swift is the only thing that touches UI.

import Foundation

/// The persisted contents of a `.spreadsheet` page - a sparse grid of
/// cells addressed like Numbers/Excel ("A1", "B12"). Only cells the user
/// has actually typed into are stored; everything else is blank.
struct SpreadsheetData: Codable, Equatable {
    var rows: Int
    var columns: Int
    /// Keyed by cell reference (e.g. "A1"). A value starting with "="
    /// is a formula; anything else is shown as-is, and parsed as a
    /// number (or treated as 0) wherever a formula references it.
    var cells: [String: String]

    static let defaultRows = 20
    static let defaultColumns = 8
    static let maxRows = 200
    static let maxColumns = 26

    static var empty: SpreadsheetData {
        SpreadsheetData(rows: defaultRows, columns: defaultColumns, cells: [:])
    }
}

/// Converts between a zero-based (row, column) pair and a spreadsheet
/// reference like "A1" or "AA12" - the same column-letter scheme Numbers
/// and Excel use (A-Z, then AA-AZ, BA-BZ, ...), rows 1-based for display.
extension SpreadsheetData {
    /// Raw cell contents (formulas as written) as RFC 4180 CSV.
    var csv: String {
        (0..<rows).map { row in
            (0..<columns).map { column in
                let value = cells[CellReference.name(row: row, column: column)] ?? ""
                let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0.isNewline }
                return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: ",")
        }.joined(separator: "\r\n")
    }
}

enum CellReference {
    static func name(row: Int, column: Int) -> String {
        var col = column
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(65 + col % 26)!) + letters
            col = col / 26 - 1
        } while col >= 0
        return "\(letters)\(row + 1)"
    }

    /// Parses "A1"/"AA12" back into a zero-based (row, column) pair, or
    /// `nil` if `name` isn't a valid reference (letters, then digits).
    static func parse(_ name: String) -> (row: Int, column: Int)? {
        var letters = ""
        var digits = ""
        for char in name {
            if char.isLetter {
                guard digits.isEmpty else { return nil }
                letters.append(char)
            } else if char.isNumber {
                digits.append(char)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty, let row = Int(digits), row >= 1 else { return nil }
        var column = 0
        for char in letters.uppercased() {
            guard let ascii = char.asciiValue, (65...90).contains(ascii) else { return nil }
            let (scaled, multiplyOverflow) = column.multipliedReportingOverflow(by: 26)
            let (next, addOverflow) = scaled.addingReportingOverflow(Int(ascii - 65 + 1))
            guard !multiplyOverflow, !addOverflow else { return nil }
            column = next
        }
        return (row - 1, column - 1)
    }
}

/// Evaluates basic arithmetic formulas over spreadsheet cells - cell
/// references, arithmetic, parentheses, and SUM/AVERAGE/MIN/MAX/COUNT
/// over ranges and expressions. Circular or invalid formulas display #REF!.
enum FormulaEngine {
    enum EvaluationError: Error { case circularReference, invalidReference(String), syntaxError, divideByZero }

    /// The text to display for every cell that currently has content,
    /// computed in one pass with cycle detection - a formula cell that
    /// takes part in a circular reference (directly or transitively)
    /// shows "#REF!" instead of hanging.
    static func evaluateAll(_ data: SpreadsheetData) -> [String: String] {
        var results: [String: Double] = [:]
        var errors: Set<String> = []
        var inProgress: Set<String> = []

        func value(of ref: String) -> Double {
            if let cached = results[ref] { return cached }
            if errors.contains(ref) { return .nan }
            guard let raw = data.cells[ref], !raw.isEmpty else { return 0 }
            guard inProgress.insert(ref).inserted else {
                errors.insert(ref)
                return .nan
            }
            defer { inProgress.remove(ref) }

            let computed: Double
            if raw.hasPrefix("=") {
                do {
                    var parser = FormulaParser(formula: String(raw.dropFirst()), resolve: value, isNumeric: { ref in
                        guard let raw = data.cells[ref] else { return false }
                        return raw.hasPrefix("=") || Double(raw) != nil
                    })
                    let parsed = try parser.parse()
                    guard parsed.isFinite else { throw EvaluationError.divideByZero }
                    computed = parsed
                } catch {
                    errors.insert(ref)
                    return .nan
                }
            } else {
                computed = Double(raw) ?? 0
            }
            results[ref] = computed
            return computed
        }

        var display: [String: String] = [:]
        for (ref, raw) in data.cells {
            if raw.hasPrefix("=") {
                let computed = value(of: ref)
                display[ref] = errors.contains(ref) ? "#REF!" : format(computed)
            } else {
                display[ref] = raw
            }
        }
        return display
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.4g", value)
    }
}

/// A small recursive-descent parser for `+ - * / ( )`, decimal numbers,
/// and cell references - just enough for formulas like `=A1+B2*2`.
private struct FormulaParser {
    private let characters: [Character]
    private var index = 0
    private let resolve: (String) -> Double
    private let isNumeric: (String) -> Bool

    init(formula: String, resolve: @escaping (String) -> Double, isNumeric: @escaping (String) -> Bool) {
        self.characters = Array(formula.uppercased().filter { !$0.isWhitespace })
        self.resolve = resolve
        self.isNumeric = isNumeric
    }

    mutating func parse() throws -> Double {
        guard !characters.isEmpty else { throw FormulaEngine.EvaluationError.syntaxError }
        let value = try parseExpr()
        guard index == characters.count else { throw FormulaEngine.EvaluationError.syntaxError }
        return value
    }

    private mutating func parseExpr() throws -> Double {
        var value = try parseTerm()
        while let op = peek(), op == "+" || op == "-" {
            index += 1
            let rhs = try parseTerm()
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while let op = peek(), op == "*" || op == "/" {
            index += 1
            let rhs = try parseFactor()
            if op == "*" {
                value *= rhs
            } else {
                guard rhs != 0 else { throw FormulaEngine.EvaluationError.divideByZero }
                value /= rhs
            }
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        guard let char = peek() else { throw FormulaEngine.EvaluationError.syntaxError }
        if char == "-" { index += 1; return -(try parseFactor()) }
        if char == "+" { index += 1; return try parseFactor() }
        if char == "(" {
            index += 1
            let value = try parseExpr()
            guard peek() == ")" else { throw FormulaEngine.EvaluationError.syntaxError }
            index += 1
            return value
        }
        if char.isNumber || char == "." { return try parseNumber() }
        if char.isLetter { return try parseReference() }
        throw FormulaEngine.EvaluationError.syntaxError
    }

    private mutating func parseNumber() throws -> Double {
        var text = ""
        while let char = peek(), char.isNumber || char == "." {
            text.append(char)
            index += 1
        }
        guard let value = Double(text) else { throw FormulaEngine.EvaluationError.syntaxError }
        return value
    }

    private mutating func parseReference() throws -> Double {
        var text = ""
        while let char = peek(), char.isLetter || char.isNumber {
            text.append(char)
            index += 1
        }
        if peek() == "(" { return try parseFunction(text) }
        guard CellReference.parse(text) != nil else { throw FormulaEngine.EvaluationError.invalidReference(text) }
        return resolve(text)
    }

    private mutating func parseFunction(_ name: String) throws -> Double {
        guard ["SUM", "AVERAGE", "MIN", "MAX", "COUNT"].contains(name) else { throw FormulaEngine.EvaluationError.syntaxError }
        index += 1
        var values: [Double] = []
        if peek() != ")" {
            while true {
                let start = index
                var reference = ""
                while let char = peek(), char.isLetter || char.isNumber { reference.append(char); index += 1 }
                if peek() == ":" {
                    index += 1
                    var end = ""
                    while let char = peek(), char.isLetter || char.isNumber { end.append(char); index += 1 }
                    let range = try CellRange(reference + ":" + end)
                    for row in range.firstRow...range.lastRow {
                        for column in range.firstColumn...range.lastColumn {
                            let ref = CellReference.name(row: row, column: column)
                            if isNumeric(ref) { values.append(resolve(ref)) }
                        }
                    }
                } else {
                    index = start
                    values.append(try parseExpr())
                }
                if peek() != "," { break }
                index += 1
            }
        }
        guard peek() == ")" else { throw FormulaEngine.EvaluationError.syntaxError }
        index += 1
        guard values.allSatisfy(\.isFinite) else { throw FormulaEngine.EvaluationError.circularReference }
        switch name {
        case "SUM": return values.reduce(0, +)
        case "COUNT": return Double(values.count)
        case "AVERAGE":
            guard !values.isEmpty else { throw FormulaEngine.EvaluationError.divideByZero }
            return values.reduce(0, +) / Double(values.count)
        case "MIN": return values.min() ?? 0
        default: return values.max() ?? 0
        }
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }
}
