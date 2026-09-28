import Foundation
import SwiftData

struct PageRevision: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var capturedAt = Date()
    var title: String
    var kind: Int
    var contentData: Data?
    var spreadsheetData: Data?
    var plainText: String
    var outgoingLinkIDs: [UUID]
    var customTags: [String]
    var tagRaw: Int
    var paperSize: String

    init(id: UUID, capturedAt: Date, title: String, kind: Int, contentData: Data?, spreadsheetData: Data?,
         plainText: String, outgoingLinkIDs: [UUID], customTags: [String], tagRaw: Int, paperSize: String) {
        self.id = id; self.capturedAt = capturedAt; self.title = title; self.kind = kind
        self.contentData = contentData; self.spreadsheetData = spreadsheetData; self.plainText = plainText
        self.outgoingLinkIDs = outgoingLinkIDs; self.customTags = customTags; self.tagRaw = tagRaw; self.paperSize = paperSize
    }

    init(_ page: Page) {
        title = page.title; kind = page.pageKindRaw
        contentData = page.contentData; spreadsheetData = page.spreadsheetData
        plainText = page.plainText; outgoingLinkIDs = page.outgoingLinkIDs
        customTags = page.customTags; tagRaw = page.tagRaw; paperSize = page.paperSize
    }

    func matches(_ page: Page) -> Bool {
        title == page.title && kind == page.pageKindRaw && contentData == page.contentData
        && spreadsheetData == page.spreadsheetData && customTags == page.customTags
        && tagRaw == page.tagRaw && paperSize == page.paperSize
    }

    func apply(to page: Page) {
        page.title = title; page.pageKindRaw = kind
        page.contentData = contentData; page.spreadsheetData = spreadsheetData
        page.plainText = plainText; page.outgoingLinkIDs = outgoingLinkIDs
        page.customTags = customTags; page.tagRaw = tagRaw; page.paperSize = paperSize
        page.updatedAt = Date()
    }
}

enum PageHistory {
    static let limit = 50
    static let byteLimit = 64 * 1024 * 1024
    static func size(of revision: PageRevision) -> Int {
        (revision.contentData?.count ?? 0) + (revision.spreadsheetData?.count ?? 0) + revision.plainText.utf8.count
    }

    /// Newest first. Throws only for damaged history that was never converted to rows.
    static func revisions(_ page: Page) throws -> [PageRevision] {
        if let payload = page.payload, !payload.revisionEntries.isEmpty { return payload.orderedEntries.map(\.revision) }
        guard let data = page.historyData else { return [] }
        return try JSONDecoder().decode([PageRevision].self, from: data)
    }

    /// Whether `data` (portable history JSON) holds the same revisions the page
    /// has, compared by revision identity - revisions never change once captured.
    static func hasSameRevisions(_ page: Page, as data: Data?) -> Bool {
        guard let data else { return page.historyData == nil }
        guard let incoming = try? JSONDecoder().decode([PageRevision].self, from: data),
              let current = try? revisions(page) else { return page.historyData == data }
        return incoming.map(\.id) == current.map(\.id)
    }

    /// Preserve the previous saved state before applying an edit, at most once
    /// per minute. Explicit snapshots and restores bypass this coalescing window.
    static func capture(_ page: Page, force: Bool = false, now: Date = Date()) throws {
        // Runs on every autosave and title keystroke. Inside the coalescing
        // window nothing would be captured anyway, so skip decoding what can
        // be tens of megabytes of history.
        if !force, page.hasHistory, let last = page.historyCapturedAt,
           now.timeIntervalSince(last) >= 0, now.timeIntervalSince(last) < 60 { return }
        // History must never block saving the page itself. Unreadable history
        // is set aside byte-for-byte and a fresh history starts.
        let latest: PageRevision?
        var damaged = false
        do { latest = try revisions(page).first } catch { latest = nil; damaged = true }
        if let latest {
            page.historyCapturedAt = latest.capturedAt
            if latest.matches(page) { return }
            if !force && now.timeIntervalSince(latest.capturedAt) < 60 { return }
        }
        var revision = PageRevision(page)
        revision.capturedAt = now
        let payload = page.writablePayload()
        if damaged, let unreadable = payload.legacyHistoryData {
            if !payload.damagedHistory.contains(unreadable) { payload.damagedHistory.append(unreadable) }
            payload.legacyHistoryData = nil
        }
        // History still stored as JSON (not yet migrated) becomes rows first.
        if payload.revisionEntries.isEmpty, let legacy = payload.legacyHistoryData { payload.setHistoryJSON(legacy) }
        payload.appendRevision(revision)
        // Keep the newest `limit` revisions within `byteLimit` (always at least one).
        var bytes = 0, kept = 0
        var excess: [PageRevisionEntry] = []
        for entry in payload.orderedEntries {
            if kept >= limit || (kept > 0 && bytes + entry.byteSize > byteLimit) { excess.append(entry); continue }
            kept += 1; bytes += entry.byteSize
        }
        payload.removeRevisions(excess)
        page.historyCapturedAt = now
    }

    @MainActor
    static func restore(_ revision: PageRevision, to page: Page, context: ModelContext) throws {
        let previous = PageRevision(page)
        let oldHistory = page.historyData, oldCapturedAt = page.historyCapturedAt
        try capture(page, force: true)
        revision.apply(to: page)
        do { try context.save() }
        catch { previous.apply(to: page); page.historyData = oldHistory; page.historyCapturedAt = oldCapturedAt; throw error }
        NotificationCenter.default.post(name: .daftarReloadEditors, object: nil)
    }
}

extension Notification.Name {
    /// Rebuilds page editors from saved data. `object`: `Set<UUID>` of page
    /// link IDs to reload, or nil for every open editor.
    static let daftarReloadEditors = Notification.Name("DaftarReloadEditors")
}
