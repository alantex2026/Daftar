//  SpreadsheetView.swift
//  The editor for a `.spreadsheet` page - a grid of cells addressed like
//  Numbers/Excel (A1, B2, ...), each holding text, a number, or a
//  "=" formula. See SpreadsheetModel.swift for the data model and the
//  formula engine; this file is just the UI on top of it.

import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

fileprivate enum SpreadsheetNavigationDirection { case up, down, left, right }

struct SpreadsheetPaperView: View {
    @Bindable var page: Page
    @Environment(\.modelContext) private var context
    @State private var loadFailed = false
    @State private var rangeText = "A1"
    @State private var undoStack: [SpreadsheetData] = []
    @State private var redoStack: [SpreadsheetData] = []
    @State private var editingCell: String?
    @State private var sheetError: String?
    @State private var confirmDelete = false

    @State private var data: SpreadsheetData = .empty
    @State private var displayValues: [String: String] = [:]
    @StateObject private var saver = SaveCoordinator()
    @FocusState private var focusedCell: String?

    private let cellWidth: CGFloat = 110
    private let cellHeight: CGFloat = 26
    private let headerWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            PageTitleHeader(page: page)
            editingToolbar

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeaderRow
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<data.rows, id: \.self) { row in
                                rowView(row)
                            }
                        }
                    }
                }
                .padding(.leading, 52)
            }
            .background(AppTheme.paper)

            Divider()
            statusBar
        }
        .background(AppTheme.paper)
        .disabled(loadFailed)
        .focusedSceneValue(\.spreadsheetUndo, SpreadsheetUndoActions(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty, undo: undo, redo: redo))
        .onAppear(perform: load)
        .onChange(of: page.persistentModelID) { _, _ in load() }
        .onDisappear { saver.flush() }
        .onChange(of: focusedCell) { _, cell in
            editingCell = nil
            if let cell {
                rangeText = cell
                if let ref = CellReference.parse(cell) { SessionStore.saveCursor(ref.row * SpreadsheetData.maxColumns + ref.column, id: page.linkID) }
            }
        }
        .alert("Spreadsheet", isPresented: Binding(get: { sheetError != nil }, set: { if !$0 { sheetError = nil } })) {
            Button("OK") {}
        } message: { Text(sheetError ?? "") }
        .confirmationDialog("Delete the rows in the selected range?", isPresented: $confirmDelete) {
            Button("Delete Rows", role: .destructive) {
                perform {
                    let range = try CellRange(rangeText)
                    let result = try SpreadsheetEditing.deleteRows(range.firstRow...range.lastRow, from: data)
                    remember(); data = result; recalculate(); persist()
                }
            }
        }
    }

    private var editingToolbar: some View {
        ScrollView(.horizontal) {
        HStack(spacing: 10) {
            Menu("File") {
                Button("Import CSV…") { importCSV() }
                Button("Export CSV…") { exportCSV() }
            }.fixedSize()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoStack.isEmpty).help("Undo spreadsheet edit")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoStack.isEmpty).help("Redo spreadsheet edit")
            TextField("Range (A1:C5)", text: $rangeText).frame(width: 110)
            Button("Copy Range") {
                perform {
                    let value = SpreadsheetEditing.delimited(SpreadsheetEditing.copy(data, range: try CellRange(rangeText)), separator: "\t")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                }
            }
            Button("Paste Range") {
                perform {
                    guard let text = NSPasteboard.general.string(forType: .string) else { return }
                    let range = try CellRange(rangeText)
                    var changed = data
                    try SpreadsheetEditing.paste(SpreadsheetEditing.parseDelimited(text, separator: "\t"), into: &changed,
                        at: CellReference.name(row: range.firstRow, column: range.firstColumn))
                    remember(); data = changed; recalculate(); persist()
                }
            }
            Button("Delete Rows") { confirmDelete = true }
            Spacer()
        }.controlSize(.small).padding(.horizontal, 20).padding(.bottom, 8)
        }
    }

    private func remember() {
        undoStack.append(data); undoStack = Array(undoStack.suffix(100)); redoStack = []
    }
    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(data); data = previous; editingCell = nil; recalculate(); persist()
    }
    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(data); data = next; editingCell = nil; recalculate(); persist()
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { sheetError = error.localizedDescription }
    }
    private func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let changed = try SpreadsheetEditing.importCSV(String(contentsOf: url, encoding: .utf8))
            remember(); data = changed; focusedCell = nil; recalculate(); persist()
        }
    }
    private func exportCSV() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = page.displayTitle + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try SpreadsheetEditing.exportCSV(data).write(to: url, atomically: true, encoding: .utf8) }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            SaveStateIndicator(state: saver.state)

            Spacer()

            Button { addRow() } label: { Label("Add Row", systemImage: "plus") }
                .disabled(data.rows >= SpreadsheetData.maxRows)
            Button { addColumn() } label: { Label("Add Column", systemImage: "plus") }
                .disabled(data.columns >= SpreadsheetData.maxColumns)

            Text("\(data.rows) \u{00D7} \(data.columns)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
            }
            .help("Full screen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.paper)
    }

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: headerWidth, height: cellHeight)
            ForEach(0..<data.columns, id: \.self) { column in
                Text(String(CellReference.name(row: 0, column: column).dropLast()))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: cellWidth, height: cellHeight)
                    .background(Color.primary.opacity(0.05))
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }
    }

    private func rowView(_ row: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(row + 1)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: headerWidth, height: cellHeight)
                .background(Color.primary.opacity(0.05))
            ForEach(0..<data.columns, id: \.self) { column in
                cellView(row: row, column: column)
            }
        }
    }

    private func cellView(row: Int, column: Int) -> some View {
        let ref = CellReference.name(row: row, column: column)
        return CellField(text: bindingForCell(ref), display: displayValues[ref] ?? "",
                          ref: ref, focusedCell: $focusedCell,
                          onNavigate: { moveFocus(fromRow: row, column: column, direction: $0) })
            .padding(.horizontal, 6)
            .frame(width: cellWidth, height: cellHeight, alignment: .leading)
            .background(focusedCell == ref ? Color.accentColor.opacity(0.1) : Color.clear)
            .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func bindingForCell(_ ref: String) -> Binding<String> {
        Binding(
            get: { data.cells[ref] ?? "" },
            set: { newValue in
                if editingCell != ref { remember(); editingCell = ref }
                if newValue.isEmpty { data.cells.removeValue(forKey: ref) } else { data.cells[ref] = newValue }
                // Recalculated values are needed on screen immediately (a
                // formula elsewhere in the grid may depend on this cell),
                // but the JSON-encode-and-write to `page.spreadsheetData`
                // is debounced - doing that on every keystroke visibly
                // lagged typing in a grid with much formula density.
                recalculate()
                persist()
            })
    }

    /// Moves the focused cell in a keyboard-navigation direction, clamped
    /// to the grid - Tab/Shift-Tab step across a row (wrapping to the next/
    /// previous row at the edge), Return steps down a column, same as
    /// Numbers/Excel.
    private func moveFocus(fromRow row: Int, column: Int, direction: SpreadsheetNavigationDirection) {
        var (r, c) = (row, column)
        switch direction {
        case .up:
            r = max(row - 1, 0)
        case .down:
            r = min(row + 1, data.rows - 1)
        case .right:
            c += 1
            if c >= data.columns { c = 0; r = min(row + 1, data.rows - 1) }
        case .left:
            c -= 1
            if c < 0 { c = data.columns - 1; r = max(row - 1, 0) }
        }
        focusedCell = CellReference.name(row: r, column: c)
    }

    private func load() {
        do {
            data = try PageContentCodec.spreadsheet(page.spreadsheetData)
            let cursor = SessionStore.cursor(page.linkID)
            focusedCell = CellReference.name(row: min(cursor / SpreadsheetData.maxColumns, data.rows - 1),
                                             column: min(cursor % SpreadsheetData.maxColumns, data.columns - 1))
            loadFailed = false
        } catch { loadFailed = true }
        recalculate()
    }

    private func recalculate() {
        displayValues = FormulaEngine.evaluateAll(data)
    }

    private func persist() {
        guard !loadFailed else { return }
        let snapshot = data
        let page = page
        let context = context
        let title = page.displayTitle
        saver.rescue = { folder in
            let url = SaveCoordinator.rescueURL(named: title, extension: "csv", in: folder)
            try snapshot.csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        saver.schedule(delay: AppSettings.saveDelay) {
            try PageHistory.capture(page)
            page.spreadsheetData = try JSONEncoder().encode(snapshot)
            page.plainText = snapshot.cells.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
            page.updatedAt = Date()
            try context.save()
        }
    }

    private func addRow() {
        guard data.rows < SpreadsheetData.maxRows else { return }
        remember()
        data.rows += 1
        persist()
    }

    private func addColumn() {
        guard data.columns < SpreadsheetData.maxColumns else { return }
        remember()
        data.columns += 1
        persist()
    }
}

/// One cell: a plain label showing its computed value, until clicked -
/// then a text field showing (and letting you edit) the raw text or
/// formula behind it, same as Numbers/Excel. Return/Tab commit the edit
/// and move to the next cell, same as Numbers/Excel - without this, every
/// cell needs a fresh click since only the focused cell is a real,
/// tab-reachable text field.
private struct CellField: View {
    @Binding var text: String
    let display: String
    let ref: String
    var focusedCell: FocusState<String?>.Binding
    let onNavigate: (SpreadsheetNavigationDirection) -> Void

    var body: some View {
        if focusedCell.wrappedValue == ref {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused(focusedCell, equals: ref)
                .onKeyPress { press in
                    switch press.key {
                    case .tab:
                        onNavigate(press.modifiers.contains(.shift) ? .left : .right)
                        return .handled
                    case .return:
                        onNavigate(.down)
                        return .handled
                    default:
                        return .ignored
                    }
                }
        } else {
            Text(display)
                .font(.system(size: 12))
                .foregroundStyle(display == "#REF!" ? Color.red : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focusedCell.wrappedValue = ref }
        }
    }
}

struct SpreadsheetUndoActions {
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
}
struct FocusedSpreadsheetUndo: FocusedValueKey { typealias Value = SpreadsheetUndoActions }
extension FocusedValues {
    var spreadsheetUndo: SpreadsheetUndoActions? {
        get { self[FocusedSpreadsheetUndo.self] }
        set { self[FocusedSpreadsheetUndo.self] = newValue }
    }
}
