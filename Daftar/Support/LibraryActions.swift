//  LibraryActions.swift
//  Every change to the notebook / section / page structure, in one place.
//  Views decide *when* (menus, drags, buttons) and update their own
//  selection; this decides *what* happens to the models, so the rules
//  (sort order, trash cascading, restoring ancestors) live once and are
//  unit-testable without any UI.

import Foundation
import SwiftData

@MainActor
enum LibraryActions {
    private static var randomColor: String { PaletteColor.allCases.randomElement()!.rawValue }

    // MARK: - Creating

    @discardableResult
    static func addNotebook(after notebooks: [Notebook], context: ModelContext) -> (notebook: Notebook, section: NoteSection) {
        let notebook = Notebook(name: "New Notebook", colorName: randomColor,
                                sortIndex: (notebooks.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(notebook)
        let section = NoteSection(name: "New Section", sortIndex: 0)
        section.notebook = notebook
        context.insert(section)
        return (notebook, section)
    }

    @discardableResult
    static func addSection(to notebook: Notebook, isGroup: Bool, context: ModelContext) -> NoteSection {
        let section = NoteSection(name: isGroup ? "New Section Group" : "New Section", colorName: randomColor,
                                  sortIndex: notebook.nextSectionIndex, isGroup: isGroup)
        section.notebook = notebook
        context.insert(section)
        notebook.isExpanded = true
        return section
    }

    @discardableResult
    static func addSection(inside group: NoteSection, context: ModelContext) -> NoteSection {
        let section = NoteSection(name: "New Section", colorName: randomColor,
                                  sortIndex: (group.children.map(\.sortIndex).max() ?? -1) + 1)
        section.notebook = group.notebook
        section.parent = group
        context.insert(section)
        group.isExpanded = true
        return section
    }

    /// Adds a page at the end of `section`, or as the last sub-page of `parent`.
    static func addPage(to section: NoteSection, under parent: Page?, template: PageTemplate = .blank,
                        kind: PageKind = .richText, context: ModelContext) -> Page? {
        guard !section.isGroup else { return nil }
        let page = Page(title: "Untitled", sortIndex: parent?.nextChildIndex ?? section.nextRootPageIndex)
        page.parent = parent
        parent?.isExpanded = true
        page.section = section
        page.kind = kind
        if kind == .richText {
            if let title = template.pageTitle { page.title = title }
            page.contentData = template.contentData
            page.plainText = template.plainText
        }
        context.insert(page)
        return page
    }

    /// Copies a page and all its sub-pages, placing the copy last among the
    /// original's siblings. History isn't copied: the copy starts fresh.
    @discardableResult
    static func duplicate(_ page: Page, context: ModelContext) -> Page {
        let index = page.parent?.nextChildIndex ?? page.section?.nextRootPageIndex ?? 0
        return copy(page, title: page.title + " copy", sortIndex: index, parent: page.parent, context: context)
    }

    private static func copy(_ page: Page, title: String, sortIndex: Int, parent: Page?, context: ModelContext) -> Page {
        let copy = Page(title: title, sortIndex: sortIndex)
        copy.contentData = page.contentData
        copy.spreadsheetData = page.spreadsheetData
        copy.plainText = page.plainText
        copy.tagRaw = page.tagRaw
        copy.pageKindRaw = page.pageKindRaw
        copy.customTags = page.customTags
        copy.paperSize = page.paperSize
        copy.outgoingLinkIDs = page.outgoingLinkIDs
        copy.section = page.section
        copy.parent = parent
        context.insert(copy)
        for child in page.sortedChildren {
            _ = self.copy(child, title: child.title, sortIndex: copy.nextChildIndex, parent: copy, context: context)
        }
        return copy
    }

    static func moveOut(_ page: Page) {
        page.parent = page.parent?.parent
    }

    // MARK: - Reordering

    /// Moves `dragged` to `target`'s position among `siblings` and renumbers
    /// them. Items that aren't in `siblings` are left alone.
    static func reorder<Item: AnyObject>(_ siblings: [Item], moving dragged: Item, to target: Item,
                                         sortIndex: ReferenceWritableKeyPath<Item, Int>) {
        guard dragged !== target else { return }
        var ordered = siblings
        ordered.removeAll { $0 === dragged }
        guard let targetIndex = ordered.firstIndex(where: { $0 === target }) else { return }
        ordered.insert(dragged, at: targetIndex)
        for (index, item) in ordered.enumerated() { item[keyPath: sortIndex] = index }
    }

    static func reorderNotebooks(_ notebooks: [Notebook], moving dragged: Notebook, to target: Notebook) {
        // Trashed notebooks keep their old position in case they're restored.
        let live = notebooks.filter { !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
        reorder(live, moving: dragged, to: target, sortIndex: \.sortIndex)
    }

    /// Only reorders siblings (same notebook and group); dragging never moves
    /// a section somewhere else.
    static func reorderSections(moving dragged: NoteSection, to target: NoteSection) {
        guard dragged.notebook === target.notebook, dragged.parent === target.parent else { return }
        reorder(target.parent?.sortedChildren ?? target.notebook?.topLevelSections ?? [],
                moving: dragged, to: target, sortIndex: \.sortIndex)
    }

    /// Only reorders siblings (same parent page and section).
    static func reorderPages(moving dragged: Page, to target: Page) {
        guard dragged.parent === target.parent, dragged.section === target.section else { return }
        reorder(target.parent?.sortedChildren ?? target.section?.rootPages ?? [],
                moving: dragged, to: target, sortIndex: \.sortIndex)
    }

    // MARK: - Trash

    static func trash(_ notebook: Notebook) { notebook.deletedAt = Date() }
    static func trash(_ section: NoteSection) { section.deletedAt = Date() }
    static func trash(_ page: Page) { page.deletedAt = Date() }

    /// Restoring also restores trashed ancestors, so the item is actually
    /// reachable again instead of quietly staying hidden.
    static func restore(_ notebook: Notebook) { notebook.deletedAt = nil }

    static func restore(_ section: NoteSection) {
        var current: NoteSection? = section
        while let item = current {
            item.deletedAt = nil
            item.notebook?.deletedAt = nil
            current = item.parent
        }
    }

    static func restore(_ page: Page) {
        var current: Page? = page
        while let item = current {
            item.deletedAt = nil
            if item.parent == nil, let section = item.section { restore(section) }
            current = item.parent
        }
    }

    static func deletePermanently(_ model: any PersistentModel, context: ModelContext) {
        context.delete(model)
    }
}

extension NoteSection {
    /// True if this is `ancestor` itself or nested anywhere inside it.
    func isWithin(_ ancestor: NoteSection) -> Bool {
        var current: NoteSection? = self
        while let item = current {
            if item === ancestor { return true }
            current = item.parent
        }
        return false
    }
}

extension Page {
    /// True if this is `ancestor` itself or nested anywhere inside it.
    func isWithin(_ ancestor: Page) -> Bool {
        var current: Page? = self
        while let item = current {
            if item === ancestor { return true }
            current = item.parent
        }
        return false
    }
}
