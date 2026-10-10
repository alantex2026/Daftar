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

    // Editors report the cursor on every keystroke and arrow press. Writing
    // UserDefaults that often also woke every window's settings observer, so
    // positions are kept in memory and written at most every couple of seconds.
    @MainActor private static var pendingCursors: [UUID: Int] = [:]
    @MainActor private static var cursorWrite: DispatchWorkItem?

    @MainActor static func rememberCursor(_ position: Int, id: UUID) {
        pendingCursors[id] = max(0, position)
        guard cursorWrite == nil else { return }
        let work = DispatchWorkItem { flushCursors() }
        cursorWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// The newest known position, including one not yet written.
    @MainActor static func latestCursor(_ id: UUID) -> Int {
        pendingCursors[id] ?? cursor(id)
    }

    /// Writes remembered positions now. Called on quit and by the timer.
    @MainActor static func flushCursors(defaults: UserDefaults = .standard) {
        cursorWrite?.cancel()
        cursorWrite = nil
        let pending = pendingCursors
        pendingCursors = [:]
        for (id, position) in pending { saveCursor(position, id: id, defaults: defaults) }
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
