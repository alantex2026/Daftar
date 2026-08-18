//  NoteSection.swift
//  Level 2: a Section holds Pages.
//  If `isGroup` is true it is a Section Group and holds other Sections instead.

import Foundation
import SwiftData

@Model
final class NoteSection {
    var name: String = "New Section"
    var colorName: String = "blue"
    var sortIndex: Int = 0
    var isGroup: Bool = false
    var isExpanded: Bool = true
    var createdAt: Date = Date()

    /// Set when this section is moved to the Trash. `nil` means it is live.
    var deletedAt: Date?

    /// Whether opening this section's pages requires Touch ID / the Mac
    /// password first. Unlocking (see `SectionLockStore`) only lasts for
    /// the current run of the app - never written anywhere, so it can't
    /// itself leak whether a section was ever opened.
    var isLocked: Bool = false

    var notebook: Notebook?
    var parent: NoteSection?

    @Relationship(deleteRule: .cascade, inverse: \NoteSection.parent)
    var children: [NoteSection] = []

    @Relationship(deleteRule: .cascade, inverse: \Page.section)
    var pages: [Page] = []

    init(name: String, colorName: String = "blue", sortIndex: Int = 0, isGroup: Bool = false) {
        self.name = name
        self.colorName = colorName
        self.sortIndex = sortIndex
        self.isGroup = isGroup
        self.isExpanded = true
        self.createdAt = Date()
    }

    /// True if this section, or any ancestor (parent group / notebook), is trashed.
    var isTrashed: Bool {
        if deletedAt != nil { return true }
        if let parent { return parent.isTrashed }
        return notebook?.isTrashed ?? false
    }

    var sortedChildren: [NoteSection] {
        children.filter { !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Pages that sit directly in the section (not sub-pages), excluding trashed ones.
    var rootPages: [Page] {
        pages.filter { $0.parent == nil && !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
    }

    var totalPageCount: Int {
        rootPageCount + children.filter { !$0.isTrashed }.reduce(0) { $0 + $1.totalPageCount }
    }

    private var rootPageCount: Int { pages.filter { !$0.isTrashed }.count }

    var nextRootPageIndex: Int { (rootPages.map(\.sortIndex).max() ?? -1) + 1 }
}
