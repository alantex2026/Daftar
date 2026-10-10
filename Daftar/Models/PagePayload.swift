//  PagePayload.swift
//  The heavy part of a Page - its RTFD, spreadsheet and history - kept in its
//  own row so it's only loaded when a page is actually opened, saved,
//  exported or synced.

import Foundation
import SwiftData

@Model
final class PagePayload {
    var contentData: Data?
    var spreadsheetData: Data?
    /// History as a JSON blob: either not yet split into `revisionEntries`,
    /// or damaged (kept byte-for-byte so it can still be recovered).
    @Attribute(originalName: "historyData") var legacyHistoryData: Data?
    /// History that couldn't be read, set aside by `PageHistory.capture` so the
    /// page keeps saving. Every distinct copy is kept; never exported.
    var damagedHistory: [Data] = []
    @Relationship(deleteRule: .cascade, inverse: \PageRevisionEntry.payload)
    var revisionEntries: [PageRevisionEntry] = []
    var page: Page?
    /// `historyJSON`, encoded once per change rather than once per read. Keyed
    /// by the revision IDs it was built from: rows can change behind our back
    /// (`ModelContext.rollback()`, undo), and revisions never change once
    /// captured, so matching IDs means matching content.
    @Transient private var historyJSONCache: (ids: [UUID], data: Data)? = nil

    init(contentData: Data? = nil, spreadsheetData: Data? = nil, historyData: Data? = nil) {
        self.contentData = contentData
        self.spreadsheetData = spreadsheetData
        setHistoryJSON(historyData)
    }

    // MARK: - History

    /// The revisions that really belong to this page. After a rollback,
    /// older SwiftData (macOS 15) can leave a discarded, never-saved row in
    /// `revisionEntries`; it's detached (or deleted) while this payload is
    /// still in the store, so it's left out. A payload not yet inserted
    /// anywhere keeps all of its rows.
    var liveEntries: [PageRevisionEntry] {
        guard modelContext != nil else { return revisionEntries }
        return revisionEntries.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    var hasRevisions: Bool { !liveEntries.isEmpty }

    /// Newest first.
    var orderedEntries: [PageRevisionEntry] {
        liveEntries.sorted { $0.sequence > $1.sequence }
    }

    /// The history as the JSON `[PageRevision]` used by backups, export and
    /// sync. Encoded on demand; only those paths read it.
    var historyJSON: Data? {
        if !hasRevisions { return legacyHistoryData }
        let entries = orderedEntries
        let ids = entries.map(\.revisionID)
        if let historyJSONCache, historyJSONCache.ids == ids { return historyJSONCache.data }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // Same history, same bytes.
        guard let encoded = try? encoder.encode(entries.map(\.revision)) else { return nil }
        historyJSONCache = (ids, encoded)
        return encoded
    }

    /// Replaces the history. Undecodable data is kept as-is rather than lost.
    func setHistoryJSON(_ data: Data?) {
        removeAllRevisions()
        guard let data else { legacyHistoryData = nil; return }
        guard let revisions = try? JSONDecoder().decode([PageRevision].self, from: data) else {
            legacyHistoryData = data
            return
        }
        legacyHistoryData = nil
        for (index, revision) in revisions.enumerated() { add(revision, sequence: revisions.count - index) }
    }

    /// Adds `revision` as the newest version.
    func appendRevision(_ revision: PageRevision) {
        add(revision, sequence: (revisionEntries.map(\.sequence).max() ?? 0) + 1)
    }

    func removeRevisions(_ entries: [PageRevisionEntry]) {
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(ObjectIdentifier.init))
        revisionEntries.removeAll { ids.contains(ObjectIdentifier($0)) }
        for entry in entries { modelContext?.delete(entry) }
        historyJSONCache = nil
    }

    private func removeAllRevisions() { removeRevisions(revisionEntries) }

    private func add(_ revision: PageRevision, sequence: Int) {
        let entry = PageRevisionEntry(revision, sequence: sequence)
        modelContext?.insert(entry)
        revisionEntries.append(entry)
        historyJSONCache = nil
    }

    /// Moves data from the pre-payload columns on `Page` into payload rows.
    /// Runs at launch; a no-op once every page has been moved. Returns the
    /// number of pages moved.
    @MainActor @discardableResult
    static func migrateLegacyColumns(context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Page>(predicate: #Predicate {
            $0.legacyContentData != nil || $0.legacyHistoryData != nil || $0.legacySpreadsheetData != nil
        })
        let pages = try context.fetch(descriptor)
        guard !pages.isEmpty else { return 0 }
        for page in pages {
            let payload = page.payload ?? PagePayload()
            if payload.contentData == nil { payload.contentData = page.legacyContentData }
            if payload.spreadsheetData == nil { payload.spreadsheetData = page.legacySpreadsheetData }
            if payload.revisionEntries.isEmpty, payload.legacyHistoryData == nil { payload.setHistoryJSON(page.legacyHistoryData) }
            page.payload = payload
            page.legacyContentData = nil; page.legacyHistoryData = nil; page.legacySpreadsheetData = nil
        }
        do { try context.save() } catch { context.rollback(); throw error }
        return pages.count
    }

    /// Splits history JSON into one row per revision. Runs at launch after
    /// `migrateLegacyColumns`; damaged history stays as JSON. Returns the
    /// number of payloads converted.
    @MainActor @discardableResult
    static func migrateHistoryToRevisions(context: ModelContext) throws -> Int {
        let payloads = try context.fetch(FetchDescriptor<PagePayload>(predicate: #Predicate { $0.legacyHistoryData != nil }))
        var converted = 0
        for payload in payloads where payload.revisionEntries.isEmpty {
            guard let data = payload.legacyHistoryData,
                  (try? JSONDecoder().decode([PageRevision].self, from: data)) != nil else { continue }
            payload.setHistoryJSON(data)
            converted += 1
        }
        guard converted > 0 else { return 0 }
        do { try context.save() } catch { context.rollback(); throw error }
        return converted
    }
}
