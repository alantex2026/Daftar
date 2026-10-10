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

    /// Moves `page` up one level, directly after its former parent, and
    /// renumbers its new siblings so the order stays unambiguous.
    static func moveOut(_ page: Page) {
        guard let oldParent = page.parent else { return }
        let newParent = oldParent.parent
        var siblings = (newParent?.sortedChildren ?? page.section?.rootPages ?? []).filter { $0 !== page }
        page.parent = newParent
        let index = siblings.firstIndex { $0 === oldParent }.map { $0 + 1 } ?? siblings.count
        siblings.insert(page, at: index)
        for (position, item) in siblings.enumerated() { item.sortIndex = position }
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

    // MARK: - Moving pages anywhere

    /// Moves `page` and its sub-pages to the end of `section`'s top level.
    static func move(_ page: Page, to section: NoteSection) {
        guard !section.isGroup else { return }
        let index = section.nextRootPageIndex
        page.parent = nil
        page.reassignSection(section)
        page.sortIndex = index
    }

    /// Makes `page` the last sub-page of `parent`, in whichever section
    /// `parent` is. Refuses to put a page inside itself or its own sub-pages.
    @discardableResult
    static func nest(_ page: Page, under parent: Page) -> Bool {
        guard parent !== page, !parent.isWithin(page), let section = parent.section else { return false }
        let index = parent.nextChildIndex
        page.parent = parent
        page.reassignSection(section)
        page.sortIndex = index
        parent.isExpanded = true
        return true
    }

    /// Places `page` directly before (or after) `target` among `target`'s
    /// siblings - in any section or under any parent - and renumbers them.
    @discardableResult
    static func place(_ page: Page, beside target: Page, after: Bool = false) -> Bool {
        guard page !== target, !target.isWithin(page), let section = target.section else { return false }
        var siblings = (target.parent?.sortedChildren ?? section.rootPages).filter { $0 !== page }
        page.parent = target.parent
        page.reassignSection(section)
        let targetIndex = siblings.firstIndex { $0 === target } ?? siblings.count
        siblings.insert(page, at: min(siblings.count, targetIndex + (after ? 1 : 0)))
        for (position, item) in siblings.enumerated() { item.sortIndex = position }
        return true
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
    /// Moves this page and every sub-page - trashed ones included, so they
    /// restore to the right place - into `section`.
    func reassignSection(_ section: NoteSection) {
        if self.section !== section { self.section = section }
        for child in children { child.reassignSection(section) }
    }

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
