import Foundation
import SwiftData

struct LibraryBackup: Codable, Sendable {
    var formatVersion = 1
    var createdAt = Date()
    var notebooks: [NotebookArchive]
    var savedSearches: [SavedSearch]

    enum BackupError: LocalizedError {
        case invalidFormat, locked, saveFailed
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "This backup is unsupported or contains duplicate identifiers."
            case .locked: return "Unlock protected sections before backing up or syncing."
            case .saveFailed: return "Save pending changes before continuing."
            }
        }
    }

    @MainActor
    static func capture(context: ModelContext, locks: SectionLockStore, defaults: UserDefaults = .standard,
                        structuredHistory: Bool = false, includeHistory: Bool = true,
                        forSync: Bool = false) throws -> LibraryBackup {
        guard SaveCoordinator.flushAll() else { throw BackupError.saveFailed }
        let sections = try context.fetch(FetchDescriptor<NoteSection>())
        guard locks.canCapture(sections, forSync: forSync) else { throw BackupError.locked }
        let notebooks = try context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.sortIndex)]))
        return LibraryBackup(notebooks: notebooks.map { NotebookArchive($0, includeTrash: true, structuredHistory: structuredHistory, includeHistory: includeHistory) },
                             savedSearches: SavedSearchStore.load(defaults: defaults))
    }

    func validate() throws {
        guard formatVersion == 1, notebooks.allSatisfy({ $0.version == 1 }) else { throw BackupError.invalidFormat }
        let ids = notebooks.flatMap(\.pageIDs)
        let notebookIDs = notebooks.compactMap(\.stableID)
        func sectionIDs(_ section: NotebookArchive.SectionRecord) -> [UUID] {
            (section.stableID.map { [$0] } ?? []) + section.children.flatMap(sectionIDs)
        }
        let sections = notebooks.flatMap { $0.sections.flatMap(sectionIDs) }
        guard notebookIDs.count == notebooks.count,
              Set(sections).count == sections.count,
              Set(ids).count == ids.count, Set(notebookIDs).count == notebookIDs.count else { throw BackupError.invalidFormat }
    }

    func withPortableHistory() throws -> LibraryBackup {
        var copy = self
        copy.notebooks = try notebooks.map { try $0.withPortableHistory() }
        return copy
    }

    /// Writes a format 2 backup (see `BackupFile`). Page history is never
    /// written: backups hold the current library (pages, Trash, attachments,
    /// saved searches), so they stay small. Sync captures can be written directly.
    func write(to url: URL) throws {
        try BackupFile(self).encoded().write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> LibraryBackup {
        try decode(Data(contentsOf: url))
    }

    /// Reads either format: 2 (binary property list) or 1 (JSON, from older versions).
    static func decode(_ data: Data) throws -> LibraryBackup {
        let result = BackupFile.isBackupFile(data)
            ? try BackupFile.decode(data).restored()
            : try JSONDecoder().decode(LibraryBackup.self, from: data)
        try result.validate()
        return result
    }

    /// Reads off the main thread through file coordination, so a backup kept in
    /// Dropbox or iCloud Drive as an online-only file is downloaded first
    /// without freezing the app.
    static func load(from url: URL) async throws -> LibraryBackup {
        try await Task.detached(priority: .userInitiated) {
            try decode(FolderSync.coordinatedRead(url))
        }.value
    }

    /// Additive restore: never replaces existing notebooks. On an empty library,
    /// preserve IDs; otherwise remap the entire backup consistently across notebooks.
    @MainActor
    func restore(context: ModelContext, defaults: UserDefaults = .standard) throws -> [Notebook] {
        try validate()
        guard SaveCoordinator.flushAll() else { throw BackupError.saveFailed }
        try context.save()
        let empty = try context.fetchCount(FetchDescriptor<Notebook>()) == 0
        let mapping = Dictionary(uniqueKeysWithValues: notebooks.flatMap(\.pageIDs).map { ($0, empty ? $0 : UUID()) })
        var restored: [Notebook] = []
        do {
            for archive in notebooks {
                restored.append(try archive.restore(context: context, preserveIDs: empty, pageIDMap: mapping, validateContent: false))
            }
            try context.save()
        } catch { context.rollback(); throw error }
        let notebookMap = Dictionary(uniqueKeysWithValues: zip(notebooks, restored).compactMap { archive, model in archive.stableID.map { ($0, model.stableID) } })
        var searches = SavedSearchStore.load(defaults: defaults)
        for var search in savedSearches {
            search.id = UUID()
            if let id = search.notebookID { search.notebookID = notebookMap[id] }
            searches.append(search)
        }
        try SavedSearchStore.save(searches, defaults: defaults)
        return restored
    }
}
