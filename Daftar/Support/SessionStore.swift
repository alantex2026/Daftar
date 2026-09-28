import Foundation

struct WindowSession: Codable, Equatable {
    var tabs: [UUID] = []
    var section: UUID?
    var page: UUID?
}

enum SessionStore {
    @MainActor private static var activeWindows = Set<String>()
    @MainActor static func claimWindow(_ preferred: String) -> String {
        let candidate = preferred.isEmpty ? (UserDefaults.standard.string(forKey: "lastWindowSessionID") ?? "main") : preferred
        let id = activeWindows.contains(candidate) ? UUID().uuidString : candidate
        activeWindows.insert(id)
        return id
    }
    @MainActor static func releaseWindow(_ id: String) { activeWindows.remove(id) }
    static func load(_ id: String, defaults: UserDefaults = .standard) -> WindowSession? {
        guard let data = defaults.data(forKey: "windowSession." + id) else { return nil }
        return try? JSONDecoder().decode(WindowSession.self, from: data)
    }
    static func save(_ value: WindowSession, id: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: "windowSession." + id)
            defaults.set(id, forKey: "lastWindowSessionID")
        }
    }
    static func cursor(_ id: UUID, defaults: UserDefaults = .standard) -> Int {
        max(0, defaults.integer(forKey: "cursor." + id.uuidString))
    }
    static func saveCursor(_ position: Int, id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(max(0, position), forKey: "cursor." + id.uuidString)
    }
    /// Drops remembered cursor positions for pages that no longer exist, so
    /// preferences don't grow with every page ever opened. Returns how many.
    @discardableResult
    static func pruneCursors(keeping pageIDs: Set<UUID>, defaults: UserDefaults = .standard) -> Int {
        let stale = defaults.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix("cursor."), let id = UUID(uuidString: String(key.dropFirst(7))) else { return false }
            return !pageIDs.contains(id)
        }
        stale.forEach(defaults.removeObject(forKey:))
        return stale.count
    }
}

struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var query: String
    var notebookID: UUID?
    var tagRaw: Int?
    var customTag: String?
}

enum SavedSearchStore {
    static func load(defaults: UserDefaults = .standard) -> [SavedSearch] {
        guard let data = defaults.data(forKey: "savedSearches") else { return [] }
        return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
    }
    static func save(_ searches: [SavedSearch], defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(searches), forKey: "savedSearches")
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: .daftarSavedSearchesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let daftarSavedSearchesChanged = Notification.Name("DaftarSavedSearchesChanged")
}
