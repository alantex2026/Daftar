import SwiftData
import Foundation

@MainActor
enum LibraryIdentity {
    /// Lightweight migrations can assign one evaluated UUID default to multiple
    /// existing rows. Normalize new identity fields once before using them.
    static func normalize(context: ModelContext) throws {
        var notebooks = Set<UUID>(), sections = Set<UUID>()
        for notebook in try context.fetch(FetchDescriptor<Notebook>()) {
            if !notebooks.insert(notebook.stableID).inserted { notebook.stableID = UUID(); notebooks.insert(notebook.stableID) }
        }
        for section in try context.fetch(FetchDescriptor<NoteSection>()) {
            if !sections.insert(section.stableID).inserted { section.stableID = UUID(); sections.insert(section.stableID) }
        }
        if context.hasChanges { try context.save() }
    }
}
