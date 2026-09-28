import AppKit
import SwiftData

/// A versioned companion to the human-readable Markdown export. No filesystem
/// paths are read from this manifest; content and attachments are self-contained.
struct NotebookArchive: Codable, Equatable, Sendable {
    static let filename = ".daftar-notebook.json"
    var version = 1
    var stableID: UUID?
    var createdAt: Date?
    var deletedAt: Date?
    var sortIndex: Int?
    var name: String
    var colorName: String
    var sections: [SectionRecord]

    struct SectionRecord: Codable, Equatable, Sendable {
        var stableID: UUID?
        var createdAt: Date?
        var deletedAt: Date?
        var sortIndex: Int?
        var name: String
        var colorName: String
        var isGroup: Bool
        var isLocked: Bool
        var children: [SectionRecord]
        var pages: [PageRecord]

        init(_ section: NoteSection, includeTrash: Bool = false, structuredHistory: Bool = false) {
            stableID = section.stableID; createdAt = section.createdAt
            deletedAt = section.deletedAt; sortIndex = section.sortIndex
            name = section.name
            colorName = section.colorName
            isGroup = section.isGroup
            isLocked = section.isLocked
            children = (includeTrash ? section.children.sorted { ($0.sortIndex, $0.stableID.uuidString) < ($1.sortIndex, $1.stableID.uuidString) } : section.sortedChildren)
                .map { SectionRecord($0, includeTrash: includeTrash, structuredHistory: structuredHistory) }
            pages = (includeTrash ? section.pages.filter { $0.parent == nil }.sorted { ($0.sortIndex, $0.linkID.uuidString) < ($1.sortIndex, $1.linkID.uuidString) } : section.rootPages)
                .map { PageRecord($0, includeTrash: includeTrash, structuredHistory: structuredHistory) }
        }
    }

    struct PageRecord: Codable, Equatable, Sendable {
        var plainText: String?
        var outgoingLinkIDs: [UUID]?
        var customTags: [String]?
        var historyData: Data?
        var paperSize: String?
        var deletedAt: Date?
        var sortIndex: Int?
        var title: String
        var kind: Int
        var tag: Int
        var linkID: UUID
        var contentData: Data?
        var spreadsheetData: Data?
        var createdAt: Date
        var updatedAt: Date
        var pinnedAt: Date?
        var children: [PageRecord]
        /// Sync-only: payloads moved to blob files (see `SyncBlobs`). Always nil
        /// in backups and exports, and omitted from their JSON.
        var contentBlob: String?
        var spreadsheetBlob: String?
        var historyBlob: String?
        var history: [SyncRevision]?

        /// `structuredHistory` (sync) takes revisions straight from their rows
        /// into `history` instead of encoding JSON on the main thread; call
        /// `withPortableHistory()` before writing such an archive to a file.
        init(_ page: Page, includeTrash: Bool = false, structuredHistory: Bool = false) {
            plainText = page.plainText; outgoingLinkIDs = page.outgoingLinkIDs
            customTags = page.customTags; paperSize = page.paperSize
            if structuredHistory, let revisions = try? PageHistory.revisions(page) {
                history = revisions.isEmpty ? nil : revisions.map { SyncRevision(revision: $0) }
            } else {
                historyData = page.historyData  // Damaged history stays byte-for-byte.
            }
            deletedAt = page.deletedAt; sortIndex = page.sortIndex
            title = page.title
            kind = page.pageKindRaw
            tag = page.tagRaw
            linkID = page.linkID
            contentData = page.contentData
            spreadsheetData = page.spreadsheetData
            createdAt = page.createdAt
            updatedAt = page.updatedAt
            pinnedAt = page.pinnedAt
            children = (includeTrash ? page.children.sorted { ($0.sortIndex, $0.linkID.uuidString) < ($1.sortIndex, $1.linkID.uuidString) } : page.sortedChildren)
                .map { PageRecord($0, includeTrash: includeTrash, structuredHistory: structuredHistory) }
        }
    }

    init(_ notebook: Notebook, includeTrash: Bool = false, structuredHistory: Bool = false) {
        stableID = notebook.stableID; createdAt = notebook.createdAt
        deletedAt = notebook.deletedAt; sortIndex = notebook.sortIndex
        name = notebook.name
        colorName = notebook.colorName
        sections = (includeTrash ? notebook.sections.filter { $0.parent == nil }.sorted { ($0.sortIndex, $0.stableID.uuidString) < ($1.sortIndex, $1.stableID.uuidString) } : notebook.topLevelSections)
            .map { SectionRecord($0, includeTrash: includeTrash, structuredHistory: structuredHistory) }
    }

    var pageIDs: [UUID] {
        func pages(_ page: PageRecord) -> [UUID] { [page.linkID] + page.children.flatMap(pages) }
        func sections(_ section: SectionRecord) -> [UUID] { section.pages.flatMap(pages) + section.children.flatMap(sections) }
        return self.sections.flatMap(sections)
    }

    enum ArchiveError: LocalizedError {
        case unsupportedVersion, invalidPage, duplicateID
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "This notebook archive uses an unsupported version."
            case .invalidPage: return "This notebook archive contains an unsupported page type."
            case .duplicateID: return "This notebook archive contains duplicate page identifiers."
            }
        }
    }

    @MainActor
    func restore(context: ModelContext, preserveIDs: Bool = false, pageIDMap: [UUID: UUID] = [:], validateContent: Bool = true) throws -> Notebook {
        guard version == 1 else { throw ArchiveError.unsupportedVersion }
        // A sync manifest must be hydrated first, or page content would be lost.
        guard !hasBlobReferences else { throw ArchiveError.invalidPage }
        var newIDs: [UUID: UUID] = [:]
        // Validate the entire archive before inserting any models.
        func validatePage(_ page: PageRecord) throws {
            guard let kind = PageKind(rawValue: page.kind) else { throw ArchiveError.invalidPage }
            guard newIDs[page.linkID] == nil else { throw ArchiveError.duplicateID }
            newIDs[page.linkID] = pageIDMap[page.linkID] ?? (preserveIDs ? page.linkID : UUID())
            if !validateContent { for child in page.children { try validatePage(child) }; return }
            if kind == .spreadsheet { _ = try PageContentCodec.spreadsheet(page.spreadsheetData) }
            else { _ = try PageContentCodec.richText(page.contentData) }
            for child in page.children { try validatePage(child) }
        }
        func validateSection(_ section: SectionRecord) throws {
            for page in section.pages { try validatePage(page) }
            for child in section.children { try validateSection(child) }
        }
        for section in sections { try validateSection(section) }

        let notebook = Notebook(name: name, colorName: colorName)
        context.insert(notebook)
        if preserveIDs, let stableID { notebook.stableID = stableID }
        notebook.deletedAt = deletedAt
        notebook.createdAt = createdAt ?? notebook.createdAt
        notebook.sortIndex = sortIndex ?? 0
        let allIDs = pageIDMap.merging(newIDs) { _, local in local }
        func restorePage(_ record: PageRecord, section: NoteSection, parent: Page?, index: Int) throws {
            let page = Page(title: record.title, sortIndex: index)
            context.insert(page)
            page.section = section
            page.parent = parent
            page.pageKindRaw = record.kind
            page.tagRaw = record.tag
            page.customTags = record.customTags ?? []
            page.historyData = record.historyData
            page.paperSize = record.paperSize ?? "letter"
            page.deletedAt = record.deletedAt
            page.sortIndex = record.sortIndex ?? index
            page.linkID = newIDs[record.linkID]!
            page.createdAt = record.createdAt
            page.updatedAt = record.updatedAt
            page.pinnedAt = record.pinnedAt
            if page.kind == .spreadsheet {
                page.spreadsheetData = record.spreadsheetData
                page.plainText = record.plainText ?? (try? PageContentCodec.spreadsheet(record.spreadsheetData).cells.values.joined(separator: " ")) ?? ""
            } else if let decoded = try? PageContentCodec.richText(record.contentData) {
                let text = NSMutableAttributedString(attributedString: decoded)
                // Imported notebooks can coexist with their originals. Rewrite internal
                // links to fresh IDs so clicking a link opens the imported page.
                text.remapPageLinks(allIDs)
                page.contentData = allIDs.allSatisfy { $0.key == $0.value } ? record.contentData : try PageContentCodec.rtfd(text)
                page.plainText = record.plainText ?? text.string
                page.outgoingLinkIDs = PageContentCodec.linkIDs(in: text)
            } else {
                page.contentData = record.contentData
                page.plainText = record.plainText ?? ""
                page.outgoingLinkIDs = (record.outgoingLinkIDs ?? []).map { allIDs[$0] ?? $0 }
            }
            if !allIDs.allSatisfy({ $0.key == $0.value }), let bytes = page.historyData, var history = try? JSONDecoder().decode([PageRevision].self, from: bytes) {
                for i in history.indices {
                    history[i].outgoingLinkIDs = history[i].outgoingLinkIDs.map { allIDs[$0] ?? $0 }
                    if let data = history[i].contentData { history[i].contentData = try PageContentCodec.remapLinks(data, ids: allIDs) }
                }
                page.historyData = try JSONEncoder().encode(history)
            }
            for (index, child) in record.children.enumerated() {
                try restorePage(child, section: section, parent: page, index: index)
            }
        }
        func restoreSection(_ record: SectionRecord, parent: NoteSection?, index: Int) throws {
            let section = NoteSection(name: record.name, colorName: record.colorName, sortIndex: index, isGroup: record.isGroup)
            context.insert(section)
            section.notebook = notebook
            section.parent = parent
            section.isLocked = record.isLocked
            if preserveIDs, let id = record.stableID { section.stableID = id }
            section.createdAt = record.createdAt ?? section.createdAt
            section.deletedAt = record.deletedAt
            section.sortIndex = record.sortIndex ?? index
            for (index, page) in record.pages.enumerated() {
                try restorePage(page, section: section, parent: nil, index: index)
            }
            for (index, child) in record.children.enumerated() {
                try restoreSection(child, parent: section, index: index)
            }
        }
        do {
            for (index, section) in sections.enumerated() { try restoreSection(section, parent: nil, index: index) }
            return notebook
        } catch {
            context.delete(notebook)
            throw error
        }
    }
}
