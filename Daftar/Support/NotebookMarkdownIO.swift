//  NotebookMarkdownIO.swift
//  Notebook-level Markdown export/import: walks the Notebook/Section/Page
//  tree on the way out, and a chosen folder on the way in. A versioned
//  .daftar-notebook.json companion preserves complete content and hierarchy
//  for restoration; other folders are imported as ordinary Markdown pages.
//
//      Section/
//        Simple Page.md
//        Page With Sub-pages/
//          Page With Sub-pages.md   <- that page's own content
//          Sub-page.md
//          assets/
//            photo.png

import AppKit
import SwiftData

@MainActor
enum NotebookMarkdownIO {

    enum IOError: LocalizedError {
        case nothingToImport
        case lockedSection
        var errorDescription: String? {
            switch self {
            case .lockedSection: return "Unlock every protected section before exporting this notebook."
            case .nothingToImport: return "That folder doesn't contain any Markdown files."
            }
        }
    }

    // MARK: - Export

    @discardableResult
    static func export(_ notebook: Notebook, to destinationFolder: URL, locks: SectionLockStore) throws -> URL {
        // Check the whole tree before creating any files, including empty locked groups.
        func authorize(_ section: NoteSection) throws {
            guard locks.isUnlocked(section) else { throw IOError.lockedSection }
            for child in section.sortedChildren { try authorize(child) }
        }
        for section in notebook.topLevelSections { try authorize(section) }
        let notebookFolder = try uniqueURL(baseName: sanitize(notebook.name), extension: nil, in: destinationFolder)
        let staging = destinationFolder.appendingPathComponent(".daftar-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for section in notebook.topLevelSections { try exportSection(section, into: staging) }
        let manifest = try JSONEncoder().encode(NotebookArchive(notebook))
        try manifest.write(to: staging.appendingPathComponent(NotebookArchive.filename), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: notebookFolder)
        return notebookFolder
    }

    private static func exportSection(_ section: NoteSection, into parentFolder: URL) throws {
        let sectionFolder = try uniqueURL(baseName: sanitize(section.name), extension: nil, in: parentFolder)
        try FileManager.default.createDirectory(at: sectionFolder, withIntermediateDirectories: true)
        if section.isGroup {
            for child in section.sortedChildren {
                try exportSection(child, into: sectionFolder)
            }
        } else {
            for page in section.rootPages {
                try exportPage(page, into: sectionFolder)
            }
        }
    }

    private static func exportPage(_ page: Page, into parentFolder: URL) throws {
        let title = sanitize(page.displayTitle)
        if page.sortedChildren.isEmpty {
            let fileURL = try uniqueURL(baseName: title, extension: "md", in: parentFolder)
            try writePageFile(page, to: fileURL, assetsFolder: parentFolder.appendingPathComponent("assets"))
        } else {
            let pageFolder = try uniqueURL(baseName: title, extension: nil, in: parentFolder)
            try FileManager.default.createDirectory(at: pageFolder, withIntermediateDirectories: true)
            let fileURL = pageFolder.appendingPathComponent("\(title).md")
            try writePageFile(page, to: fileURL, assetsFolder: pageFolder.appendingPathComponent("assets"))
            for child in page.sortedChildren {
                try exportPage(child, into: pageFolder)
            }
        }
    }

    private static func writePageFile(_ page: Page, to fileURL: URL, assetsFolder: URL) throws {
        let body: String
        if page.kind == .spreadsheet {
            let sheet = try PageContentCodec.spreadsheet(page.spreadsheetData)
            // Keep raw formulas readable in Markdown; the manifest preserves exact types and dimensions.
            func escape(_ text: String) -> String {
                text.replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
            // Built in small typed steps: as one expression, Xcode 16's type
            // checker gave up on it ("unable to type-check ... in reasonable time").
            func tableRow(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
            let headers: [String] = (0..<sheet.columns).map { String(CellReference.name(row: 0, column: $0).dropLast()) }
            let rule: [String] = Array(repeating: "---", count: sheet.columns)
            var lines: [String] = [tableRow(headers), tableRow(rule)]
            for row in 0..<sheet.rows {
                let cells: [String] = (0..<sheet.columns).map { escape(sheet.cells[CellReference.name(row: row, column: $0)] ?? "") }
                lines.append(tableRow(cells))
            }
            body = lines.joined(separator: "\n")
        } else {
            let attributed = try PageContentCodec.richText(page.contentData)
            var assetError: Error?
            body = MarkdownConverter.markdown(from: attributed) { data, suggestedName in
                guard assetError == nil else { return nil }
                do {
                    try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
                    let ext = (suggestedName as NSString).pathExtension
                    let base = sanitize((suggestedName as NSString).deletingPathExtension)
                    let assetURL = try uniqueURL(baseName: base, extension: ext.isEmpty ? nil : ext, in: assetsFolder)
                    try data.write(to: assetURL, options: .atomic)
                    let escapedName = assetURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?"))) ?? assetURL.lastPathComponent
                    return "assets/\(escapedName)"
                } catch {
                    assetError = error
                    return nil
                }
            }
            if let assetError { throw assetError }
        }
        let content = "# \(page.displayTitle)\n\n\(body)"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Import

    /// Daftar exports restore from their self-contained manifest. Without one,
    /// import ordinary Markdown into a single section, treating folders as pages.
    @discardableResult
    static func importFolder(_ folderURL: URL, context: ModelContext) throws -> Notebook {
        let manifestURL = folderURL.appendingPathComponent(NotebookArchive.filename)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let archive = try JSONDecoder().decode(NotebookArchive.self, from: Data(contentsOf: manifestURL))
            return try archive.restore(context: context)
        }
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard entries.contains(where: { $0.pathExtension.lowercased() == "md" || $0.hasDirectoryPath }) else {
            throw IOError.nothingToImport
        }

        let notebook = Notebook(name: folderURL.lastPathComponent,
                                colorName: PaletteColor.allCases.randomElement()!.rawValue,
                                sortIndex: 0)
        context.insert(notebook)
        let section = NoteSection(name: "Notes", colorName: "blue", sortIndex: 0)
        section.notebook = notebook
        context.insert(section)

        var index = 0
        for item in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if item.lastPathComponent == "assets" { continue }
            if item.hasDirectoryPath {
                importPageFolder(item, section: section, parent: nil, sortIndex: index, context: context)
                index += 1
            } else if item.pathExtension.lowercased() == "md" {
                importPageFile(item, section: section, parent: nil, sortIndex: index, context: context)
                index += 1
            }
        }
        return notebook
    }

    @discardableResult
    private static func importPageFolder(_ folderURL: URL, section: NoteSection, parent: Page?,
                                         sortIndex: Int, context: ModelContext) -> Page {
        let name = folderURL.lastPathComponent
        let ownFile = folderURL.appendingPathComponent("\(name).md")
        let hasOwnFile = FileManager.default.fileExists(atPath: ownFile.path)
        let (title, body) = hasOwnFile ? readPage(ownFile, fallbackTitle: name) : (name, "")

        let page = Page(title: title, sortIndex: sortIndex)
        page.section = section
        page.parent = parent
        page.contentData = encode(MarkdownConverter.attributedString(fromMarkdown: body))
        page.plainText = body
        context.insert(page)

        let children = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var index = 0
        for item in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if item == ownFile || item.lastPathComponent == "assets" { continue }
            if item.hasDirectoryPath {
                importPageFolder(item, section: section, parent: page, sortIndex: index, context: context)
                index += 1
            } else if item.pathExtension.lowercased() == "md" {
                importPageFile(item, section: section, parent: page, sortIndex: index, context: context)
                index += 1
            }
        }
        return page
    }

    @discardableResult
    private static func importPageFile(_ fileURL: URL, section: NoteSection, parent: Page?,
                                       sortIndex: Int, context: ModelContext) -> Page {
        let (title, body) = readPage(fileURL, fallbackTitle: fileURL.deletingPathExtension().lastPathComponent)
        let page = Page(title: title, sortIndex: sortIndex)
        page.section = section
        page.parent = parent
        page.contentData = encode(MarkdownConverter.attributedString(fromMarkdown: body))
        page.plainText = body
        context.insert(page)
        return page
    }

    private static func readPage(_ fileURL: URL, fallbackTitle: String) -> (title: String, body: String) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return (fallbackTitle, "") }
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? fallbackTitle : title, body)
        }
        return (fallbackTitle, text)
    }

    // MARK: - Shared helpers

    private static func encode(_ attributed: NSAttributedString) -> Data? {
        let full = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let result = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." || result == "assets" ? "Untitled" : result
    }

    /// Appends " 2", " 3", etc. if something with this name already exists,
    /// so exporting twice into the same folder doesn't silently overwrite.
    private static func uniqueURL(baseName: String, extension ext: String?, in folder: URL) throws -> URL {
        let fm = FileManager.default
        var attempt = 1
        while true {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = folder.appendingPathComponent(ext.map { "\(name).\($0)" } ?? name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }
}
