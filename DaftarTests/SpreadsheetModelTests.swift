//  SpreadsheetModelTests.swift
//  Coverage for the cell-reference scheme and the formula engine, both
//  plain enough logic to test without any AppKit/SwiftUI involved.

import XCTest
@testable import Daftar

final class SpreadsheetModelTests: XCTestCase {

    // MARK: - CellReference

    func testCellReferenceNameForFirstColumnsAndRows() {
        XCTAssertEqual(CellReference.name(row: 0, column: 0), "A1")
        XCTAssertEqual(CellReference.name(row: 0, column: 1), "B1")
        XCTAssertEqual(CellReference.name(row: 5, column: 0), "A6")
    }

    func testCellReferenceNameWrapsPastZ() {
        XCTAssertEqual(CellReference.name(row: 0, column: 25), "Z1")
        XCTAssertEqual(CellReference.name(row: 0, column: 26), "AA1")
        XCTAssertEqual(CellReference.name(row: 0, column: 27), "AB1")
    }

    func testCellReferenceParseRoundTripsWithName() {
        for row in [0, 1, 25, 26, 100] {
            for column in [0, 1, 25, 26, 51] {
                let name = CellReference.name(row: row, column: column)
                let parsed = CellReference.parse(name)
                XCTAssertEqual(parsed?.row, row, "row round-trip for \(name)")
                XCTAssertEqual(parsed?.column, column, "column round-trip for \(name)")
            }
        }
    }

    func testCellReferenceParseRejectsInvalidStrings() {
        XCTAssertNil(CellReference.parse(""))
        XCTAssertNil(CellReference.parse("1A"))       // digits before letters
        XCTAssertNil(CellReference.parse("A"))        // no row number
        XCTAssertNil(CellReference.parse("A0"))       // rows are 1-based
        XCTAssertNil(CellReference.parse("A1B2"))     // letters after digits
        XCTAssertNil(CellReference.parse("$A$1"))     // not a supported reference style
    }

    // MARK: - FormulaEngine

    func testEvaluateAllPassesThroughPlainText() {
        let data = SpreadsheetData(rows: 2, columns: 2, cells: ["A1": "hello"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "hello")
    }

    func testEvaluateAllComputesSimpleArithmetic() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=1+2*3"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "7")
    }

    func testEvaluateAllRespectsParenthesesAndUnaryMinus() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=-(2+3)*2"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "-10")
    }

    func testEvaluateAllResolvesCellReferences() {
        let data = SpreadsheetData(rows: 2, columns: 2, cells: ["A1": "4", "B1": "5", "A2": "=A1+B1"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A2"], "9")
    }

    func testEvaluateAllChainsThroughMultipleFormulaCells() {
        let data = SpreadsheetData(rows: 3, columns: 1, cells: ["A1": "2", "A2": "=A1*3", "A3": "=A2+1"])
        let results = FormulaEngine.evaluateAll(data)
        XCTAssertEqual(results["A2"], "6")
        XCTAssertEqual(results["A3"], "7")
    }

    func testEvaluateAllTreatsBlankReferenceAsZero() {
        let data = SpreadsheetData(rows: 2, columns: 1, cells: ["A2": "=A1+5"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A2"], "5")
    }

    func testEvaluateAllTreatsNonNumericTextReferenceAsZero() {
        let data = SpreadsheetData(rows: 2, columns: 1, cells: ["A1": "hello", "A2": "=A1+5"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A2"], "5")
    }

    func testEvaluateAllReportsDirectCircularReference() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=A1+1"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "#REF!")
    }

    func testEvaluateAllReportsIndirectCircularReference() {
        let data = SpreadsheetData(rows: 2, columns: 1, cells: ["A1": "=A2", "A2": "=A1"])
        let results = FormulaEngine.evaluateAll(data)
        XCTAssertEqual(results["A1"], "#REF!")
        XCTAssertEqual(results["A2"], "#REF!")
    }

    func testEvaluateAllReportsDivideByZero() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=1/0"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "#REF!")
    }

    func testEvaluateAllReportsSyntaxError() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=1+"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "#REF!")
    }

    func testEvaluateAllReportsInvalidCellReference() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=1+A1B2"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "#REF!")
    }

    func testEvaluateAllFormatsFractionalResults() {
        let data = SpreadsheetData(rows: 1, columns: 1, cells: ["A1": "=10/4"])
        XCTAssertEqual(FormulaEngine.evaluateAll(data)["A1"], "2.5")
    }
}
