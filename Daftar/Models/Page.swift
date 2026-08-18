//  Page.swift
//  Level 3: a Page. A page can also contain sub-pages (parent / children),
//  which is what makes the middle column look like an outline.

import Foundation
import SwiftData

@Model
final class Page {
    var title: String = "Untitled"
    var contentData: Data?          // formatted text saved as RTFD
    var plainText: String = ""      // plain copy, used by search
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastOpenedAt: Date = Date.distantPast
    var sortIndex: Int = 0
    var isExpanded: Bool = true
    var tagRaw: Int = 0             // see PageTag

    /// Set when this page is moved to the Trash. `nil` means it is live.
    var deletedAt: Date?

    /// Set when the user pins this page. `nil` means not pinned; the
    /// timestamp doubles as the sort key for the Pinned list (most
    /// recently pinned first).
    var pinnedAt: Date?

    /// Stable, exportable identity used by page-to-page links (RTFD's own
    /// storage identity isn't something a link URL can reference).
    var linkID: UUID = UUID()

    /// The page IDs this page's saved text currently links to, refreshed
    /// on every save - lets "linked mentions" be a cheap array lookup
    /// instead of decoding every other page's RTFD to find backlinks.
    var outgoingLinkIDs: [UUID] = []

    var section: NoteSection?
    var parent: Page?

    @Relationship(deleteRule: .cascade, inverse: \Page.parent)
    var children: [Page] = []

    init(title: String = "Untitled", sortIndex: Int = 0) {
        self.title = title
        self.sortIndex = sortIndex
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastOpenedAt = Date.distantPast
        self.isExpanded = true
        self.tagRaw = 0
        self.plainText = ""
    }

    /// True if this page, or any ancestor (parent page / section / notebook), is trashed.
    var isTrashed: Bool {
        if deletedAt != nil { return true }
        if let parent { return parent.isTrashed }
        return section?.isTrashed ?? false
    }

    var sortedChildren: [Page] {
        children.filter { !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
    }
    var hasChildren: Bool { children.contains { !$0.isTrashed } }
    var nextChildIndex: Int { (children.map(\.sortIndex).max() ?? -1) + 1 }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var tag: PageTag {
        get { PageTag(rawValue: tagRaw) ?? .none }
        set { tagRaw = newValue.rawValue }
    }

    var isPinned: Bool { pinnedAt != nil }

    func togglePinned() {
        pinnedAt = isPinned ? nil : Date()
    }
}
