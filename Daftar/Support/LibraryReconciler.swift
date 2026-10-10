//  LibraryReconciler.swift
//  Applies incoming notebook archives (from sync) to the existing models in
//  place, matching sections and pages by their stable IDs. Nothing the user
//  is looking at gets swapped for a new object, so open windows, selections
//  and expanded/collapsed state survive a sync - only editors whose page
//  content actually changed are reloaded.

import Foundation
import SwiftData

@MainActor
struct LibraryReconciler {
    private let context: ModelContext
    private var notebooks: [UUID: Notebook]
    private var sections: [UUID: NoteSection]
    private var pages: [UUID: Page]
    private var keptSections = Set<UUID>()
    private var keptPages = Set<UUID>()
    /// Pages whose content or kind changed; open editors for them must reload.
    private(set) var changedPages = Set<UUID>()

    init(context: ModelContext) throws {
        self.context = context
        notebooks = Dictionary(try context.fetch(FetchDescriptor<Notebook>()).map { ($0.stableID, $0) }, uniquingKeysWith: { a, _ in a })
        sections = Dictionary(try context.fetch(FetchDescriptor<NoteSection>()).map { ($0.stableID, $0) }, uniquingKeysWith: { a, _ in a })
        pages = Dictionary(try context.fetch(FetchDescriptor<Page>()).map { ($0.linkID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Replaces the listed notebooks' contents with `archives` and deletes
    /// the rest of `replaced`. Sections and pages that moved between
    /// notebooks keep their identity. Call `context.save()` afterwards.
    mutating func apply(_ archives: [NotebookArchive], replacing replaced: Set<UUID>) throws {
        for archive in archives { try validate(archive) }
        let staleSections = sections.values.filter { $0.notebook.map { replaced.contains($0.stableID) } ?? false }
        let stalePages = pages.values.filter { $0.section?.notebook.map { replaced.contains($0.stableID) } ?? false }
        var keptNotebooks = Set<UUID>()
        for archive in archives {
            keptNotebooks.insert(try apply(archive).stableID)
        }
        // Pages before sections, so a section's cascade never reaches a page
        // that was just moved elsewhere.
        for page in stalePages where !keptPages.contains(page.linkID) {
            changedPages.insert(page.linkID)
            context.delete(page)
        }
        for section in staleSections where !keptSections.contains(section.stableID) { context.delete(section) }
        for id in replaced where !keptNotebooks.contains(id) {
            if let notebook = notebooks[id] { context.delete(notebook) }
        }
    }

    private func validate(_ archive: NotebookArchive) throws {
        guard archive.version == 1, archive.stableID != nil, !archive.hasBlobReferences else { throw NotebookArchive.ArchiveError.unsupportedVersion }
        func check(_ page: NotebookArchive.PageRecord) throws {
            guard PageKind(rawValue: page.kind) != nil else { throw NotebookArchive.ArchiveError.invalidPage }
            try page.children.forEach(check)
        }
        func check(_ section: NotebookArchive.SectionRecord) throws {
            try section.pages.forEach(check)
            try section.children.forEach(check)
        }
        try archive.sections.forEach(check)
    }

    private mutating func apply(_ archive: NotebookArchive) throws -> Notebook {
        let id = archive.stableID!
        let notebook = notebooks[id] ?? {
            let created = Notebook(name: archive.name, colorName: archive.colorName)
            created.stableID = id
            context.insert(created)
            return created
        }()
        notebooks[id] = notebook
        assign(notebook, \.name, archive.name)
        assign(notebook, \.colorName, archive.colorName)
        assign(notebook, \.deletedAt, archive.deletedAt)
        assign(notebook, \.sortIndex, archive.sortIndex ?? 0)
        if let created = archive.createdAt { assign(notebook, \.createdAt, created) }
        for (index, record) in archive.sections.enumerated() {
            apply(record, notebook: notebook, parent: nil, index: index)
        }
        return notebook
    }

    private mutating func apply(_ record: NotebookArchive.SectionRecord, notebook: Notebook, parent: NoteSection?, index: Int) {
        let id = record.stableID ?? UUID()
        let section = sections[id] ?? {
            let created = NoteSection(name: record.name, colorName: record.colorName, sortIndex: index, isGroup: record.isGroup)
            created.stableID = id
            context.insert(created)
            return created
        }()
        sections[id] = section
        keptSections.insert(id)
        assign(section, \.name, record.name)
        assign(section, \.colorName, record.colorName)
        assign(section, \.isGroup, record.isGroup)
        assign(section, \.isLocked, record.isLocked)
        assign(section, \.deletedAt, record.deletedAt)
        assign(section, \.sortIndex, record.sortIndex ?? index)
        if let created = record.createdAt { assign(section, \.createdAt, created) }
        if section.notebook !== notebook { section.notebook = notebook }
        if section.parent !== parent { section.parent = parent }
        for (index, page) in record.pages.enumerated() { apply(page, section: section, parent: nil, index: index) }
        for (index, child) in record.children.enumerated() { apply(child, notebook: notebook, parent: section, index: index) }
    }

    private mutating func apply(_ record: NotebookArchive.PageRecord, section: NoteSection, parent: Page?, index: Int) {
        let page = pages[record.linkID] ?? {
            let created = Page(title: record.title, sortIndex: index)
            created.linkID = record.linkID
            context.insert(created)
            return created
        }()
        pages[record.linkID] = page
        keptPages.insert(record.linkID)
        if page.contentData != record.contentData || page.spreadsheetData != record.spreadsheetData || page.pageKindRaw != record.kind {
            changedPages.insert(record.linkID)
            page.contentData = record.contentData
            page.spreadsheetData = record.spreadsheetData
            assign(page, \.pageKindRaw, record.kind)
            page.historyCapturedAt = nil  // History may have changed with it.
        }
        // Sync doesn't carry history, so each Mac keeps its own; only an
        // archive that actually has history replaces it.
        if record.historyData != nil, !PageHistory.hasSameRevisions(page, as: record.historyData) {
            page.historyData = record.historyData; page.historyCapturedAt = nil
        }
        assign(page, \.title, record.title)
        assign(page, \.tagRaw, record.tag)
        assign(page, \.customTags, record.customTags ?? [])
        assign(page, \.paperSize, record.paperSize ?? "letter")
        assign(page, \.deletedAt, record.deletedAt)
        assign(page, \.sortIndex, record.sortIndex ?? index)
        assign(page, \.createdAt, record.createdAt)
        assign(page, \.updatedAt, record.updatedAt)
        assign(page, \.pinnedAt, record.pinnedAt)
        let derived = Self.searchFields(record)
        assign(page, \.plainText, derived.plainText)
        assign(page, \.outgoingLinkIDs, derived.links)
        if page.section !== section { page.section = section }
        if page.parent !== parent { page.parent = parent }
        for (index, child) in record.children.enumerated() { apply(child, section: section, parent: page, index: index) }
    }

    /// Same derivation `NotebookArchive.restore` uses when IDs are preserved.
    private static func searchFields(_ record: NotebookArchive.PageRecord) -> (plainText: String, links: [UUID]) {
        if record.kind == PageKind.spreadsheet.rawValue {
            let text = record.plainText ?? (try? PageContentCodec.spreadsheet(record.spreadsheetData).cells.values.joined(separator: " ")) ?? ""
            return (text, record.outgoingLinkIDs ?? [])
        }
        if let plain = record.plainText, let links = record.outgoingLinkIDs { return (plain, links) }
        if let text = try? PageContentCodec.richText(record.contentData) {
            return (record.plainText ?? text.string, text.linkedPageIDs)
        }
        return (record.plainText ?? "", record.outgoingLinkIDs ?? [])
    }

    /// Only writes real changes, so an unchanged model isn't marked dirty.
    private func assign<Model: AnyObject, Value: Equatable>(_ model: Model, _ keyPath: ReferenceWritableKeyPath<Model, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }
}
