//  Page.swift
//  Level 3: a Page. A page can also contain sub-pages (parent / children),
//  which is what makes the middle column look like an outline.

import Foundation
import SwiftData

@Model
final class Page {
    var customTags: [String] = []
    /// Content, spreadsheet and history live in `PagePayload`, a separate
    /// row loaded only when accessed, so listing, searching and counting
    /// pages never pulls megabytes of RTFD and history into memory.
    /// (Not `.externalStorage`: enabling it on an existing store makes SwiftData
    /// read previously-nil blobs back as empty Data - verified on a real library.)
    @Relationship(deleteRule: .cascade, inverse: \PagePayload.page) var payload: PagePayload?
    // Pre-payload columns, renamed so a lightweight migration keeps their data.
    // `PagePayload.migrateLegacyColumns` moves it into `payload` once.
    @Attribute(originalName: "historyData") var legacyHistoryData: Data?
    @Attribute(originalName: "contentData") var legacyContentData: Data?
    @Attribute(originalName: "spreadsheetData") var legacySpreadsheetData: Data?
    /// When the newest history revision was captured - lets a save skip
    /// decoding `historyData` inside the one-minute coalescing window.
    var historyCapturedAt: Date?
    var paperSize: String = "letter"
    var title: String = "Untitled"
    var plainText: String = ""      // plain copy, used by search
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    // Retained for compatibility with existing stores; no longer tracked.
    var lastOpenedAt: Date = Date.distantPast
    var sortIndex: Int = 0
    var isExpanded: Bool = true
    var tagRaw: Int = 0             // see PageTag
    var pageKindRaw: Int = 0        // see PageKind


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

    var kind: PageKind {
        get { PageKind(rawValue: pageKindRaw) ?? .richText }
        set { pageKindRaw = newValue.rawValue }
    }

    var isPinned: Bool { pinnedAt != nil }

    // MARK: - Payload

    /// Formatted text saved as RTFD.
    var contentData: Data? {
        get { payload?.contentData ?? legacyContentData }
        set { writablePayload().contentData = newValue }
    }

    /// Only set for `.spreadsheet` pages - a JSON-encoded `SpreadsheetData`.
    /// `.richText` and `.document` pages both use `contentData` (RTFD)
    /// instead; `.document` differs from `.richText` only in how it's
    /// rendered (paginated vs. continuous), not in how it's stored.
    var spreadsheetData: Data? {
        get { payload?.spreadsheetData ?? legacySpreadsheetData }
        set { writablePayload().spreadsheetData = newValue }
    }

    /// JSON-encoded `[PageRevision]`, newest first - the portable form used by
    /// backups, export and sync. Stored as one row per revision (see
    /// `PageRevisionEntry`); `PageHistory` works with the rows directly.
    var historyData: Data? {
        get { payload?.historyJSON ?? legacyHistoryData }
        set { writablePayload().setHistoryJSON(newValue) }
    }

    /// Cheap check that never encodes the history.
    var hasHistory: Bool {
        if let payload { return !payload.revisionEntries.isEmpty || payload.legacyHistoryData != nil }
        return legacyHistoryData != nil
    }

    /// Creates the payload on first write, carrying over any legacy values
    /// so writing one field never hides the others.
    func writablePayload() -> PagePayload {
        if let payload { return payload }
        let created = PagePayload(contentData: legacyContentData, spreadsheetData: legacySpreadsheetData, historyData: legacyHistoryData)
        legacyContentData = nil; legacySpreadsheetData = nil; legacyHistoryData = nil
        payload = created
        return created
    }

    func togglePinned() {
        pinnedAt = isPinned ? nil : Date()
    }
}
