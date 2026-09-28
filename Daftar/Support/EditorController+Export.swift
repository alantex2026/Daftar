//  EditorController+Export.swift
//  Find bar, spell check and export.

import AppKit
import UniformTypeIdentifiers

extension EditorController {
    // MARK: - Find bar, spell check, export

    func showFindBar() {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performFindPanelAction(item)
    }

    func toggleSpellCheck() {
        spellCheckOn.toggle()
    }

    /// Save the current page as a PDF file.
    func exportPDF(to url: URL) {
        guard let tv = textView else { return }
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            errorMessage = "Couldn't export as PDF."
            return
        }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        info.horizontalPagination = .fit
        info.topMargin = 40; info.bottomMargin = 40
        info.leftMargin = 40; info.rightMargin = 40

        let printView: NSView
        if let document = tv.superview as? PaginatedPagesView {
            printView = document
            info.paperSize = document.printedPageSize
            info.topMargin = 0; info.bottomMargin = 0
            info.leftMargin = 0; info.rightMargin = 0
            info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        } else { printView = tv }
        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        if !operation.run() {
            errorMessage = "Couldn't export as PDF."
        }
    }

    /// Give back the current text as RTF data (for "Export as RTF").
    func currentRTF() -> Data? {
        guard let storage = textView?.textStorage else { return nil }
        let full = NSRange(location: 0, length: storage.length)
        do {
            return try CanvasImageLayout.portable(storage).data(from: full,
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            errorMessage = "Couldn't export as RTF."
            return nil
        }
    }
}
