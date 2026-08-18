//  NotebookMarkdownIO.swift
//  Notebook-level Markdown export/import: walks the Notebook/Section/Page
//  tree on the way out, and a chosen folder on the way in. Shares one
//  convention in both directions so a notebook Daftar exported itself
//  round-trips cleanly:
//
//      Section/
//        Simple Page.md
//        Page With Sub-pages/
//          Page With Sub-pages.md   <- that page's own content
//          Sub-page.md
//          assets/
//            1-photo.png

import AppKit
import SwiftData

enum NotebookMarkdownIO {

    enum IOError: LocalizedError {
        case nothingToImport
        var errorDescription: String? {
            switch self {
            case .nothingToImport: return "That folder doesn't contain any Markdown files."
            }
        }
    }

    // MARK: - Export

    static func export(_ notebook: Notebook, to destinationFolder: URL) throws {
        let notebookFolder = try uniqueURL(baseName: sanitize(notebook.name), extension: nil, in: destinationFolder)
        try FileManager.default.createDirectory(at: notebookFolder, withIntermediateDirectories: true)
        for section in notebook.topLevelSections {
            try exportSection(section, into: notebookFolder)
        }
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
        let attributed = decode(page.contentData)
        var assetIndex = 0
        var assetsFolderReady = false
        let body = MarkdownConverter.markdown(from: attributed) { data, suggestedName in
            if !assetsFolderReady {
                assetsFolderReady = (try? FileManager.default.createDirectory(
                    at: assetsFolder, withIntermediateDirectories: true)) != nil
            }
            assetIndex += 1
            let ext = (suggestedName as NSString).pathExtension
            let base = sanitize((suggestedName as NSString).deletingPathExtension)
            let fileName = "\(assetIndex)-\(base)" + (ext.isEmpty ? "" : ".\(ext)")
            guard (try? data.write(to: assetsFolder.appendingPathComponent(fileName))) != nil else { return nil }
            return "assets/\(fileName)"
        }
        let content = "# \(page.displayTitle)\n\n\(body)"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Import

    /// Imports a folder as a new notebook with one section, named after the
    /// folder. Each `.md` file becomes a page; each subfolder becomes a page
    /// with sub-pages, using the same convention `export` writes.
    @discardableResult
    static func importFolder(_ folderURL: URL, context: ModelContext) throws -> Notebook {
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

    private static func decode(_ data: Data?) -> NSAttributedString {
        guard let data, let attributed = try? NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) else {
            return NSAttributedString(string: "")
        }
        return attributed
    }

    private static func encode(_ attributed: NSAttributedString) -> Data? {
        let full = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let result = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Untitled" : result
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
