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

    /// Save the current page as a PDF file. Returns whether it was written.
    @discardableResult
    func exportPDF(to url: URL) -> Bool {
        guard let (printView, info) = printSetup() else {
            errorMessage = "Couldn't export as PDF."
            return false
        }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Couldn't export as PDF."
            return false
        }
        return true
    }

    /// File > Print (Cmd P): the standard print panel, laid out exactly like
    /// the PDF export.
    func printPage() {
        guard let (printView, info) = printSetup(), let window = textView?.window else { return }
        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The view to print and its page setup: a document page prints its
    /// sheets as they are; a note prints its text with page margins.
    private func printSetup() -> (NSView, NSPrintInfo)? {
        guard let tv = textView, let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return nil }
        info.horizontalPagination = .fit
        info.topMargin = 40; info.bottomMargin = 40
        info.leftMargin = 40; info.rightMargin = 40
        if let document = tv.superview as? PaginatedPagesView {
            info.paperSize = document.printedPageSize
            info.topMargin = 0; info.bottomMargin = 0
            info.leftMargin = 0; info.rightMargin = 0
            info.isHorizontallyCentered = false; info.isVerticallyCentered = false
            return (document, info)
        }
        return (tv, info)
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
