//  TrashMaintenance.swift
//  Permanently removes items that have sat in the Trash past the retention
//  window, so the Trash doesn't grow forever for anyone who never empties
//  it by hand. Runs once at launch; off by default toggle lives in Settings.

import Foundation
import SwiftData

enum TrashMaintenance {
    static let retentionDays = 30

    static func purgeExpired(context: ModelContext) {
        guard UserDefaults.standard.object(forKey: "autoEmptyTrashEnabled") as? Bool ?? true else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast

        // Notebooks first: deleting one cascades away its sections and
        // pages, so the fetches below no longer see (and double-delete) them.
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        for notebook in notebooks where isExpired(notebook.deletedAt, before: cutoff) {
            context.delete(notebook)
        }
        let sections = (try? context.fetch(FetchDescriptor<NoteSection>())) ?? []
        for section in sections where isExpired(section.deletedAt, before: cutoff) {
            context.delete(section)
        }
        let pages = (try? context.fetch(FetchDescriptor<Page>())) ?? []
        for page in pages where isExpired(page.deletedAt, before: cutoff) {
            context.delete(page)
        }
    }

    private static func isExpired(_ deletedAt: Date?, before cutoff: Date) -> Bool {
        guard let deletedAt else { return false }
        return deletedAt < cutoff
    }
}
