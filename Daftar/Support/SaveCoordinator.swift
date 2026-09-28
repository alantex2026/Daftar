import Foundation
import Combine

/// Owns pending edits independently of view lifetime. A failed save stays available
/// for retry, including after its editor is removed from the view hierarchy.
@MainActor
final class SaveCoordinator: ObservableObject {
    private final class WeakEntry {
        weak var value: SaveCoordinator?
        init(_ value: SaveCoordinator) { self.value = value }
    }
    private static var registered: [UUID: WeakEntry] = [:]
    private static var pending: [UUID: SaveCoordinator] = [:]
    private let id = UUID()
    private var action: (() throws -> Void)?
    private var work: DispatchWorkItem?
    private var firstEditAt: Date?
    var saveContext: (() throws -> Void)?
    /// Writes the pending edit into a folder outside the library and returns
    /// the file it wrote - the last resort when saving keeps failing.
    var rescue: ((URL) throws -> URL)?
    var onStateChange: ((EditorController.SaveState) -> Void)?
    var onError: ((String) -> Void)?
    @Published private(set) var state: EditorController.SaveState = .idle
    @Published private(set) var errorMessage: String?

    init() {
        Self.registered[id] = WeakEntry(self)
    }

    func schedule(delay: TimeInterval = 1, action: @escaping () throws -> Void) {
        self.action = action
        Self.pending[id] = self
        if firstEditAt == nil { firstEditAt = Date() }
        setState(.saving)
        work?.cancel()
        // Continuous typing still saves at least every `maxWait` seconds, but the
        // cap never undercuts the user's chosen delay (Preferences allows 0.5–30s).
        let maxWait = max(5, delay)
        let remaining = max(0, maxWait - Date().timeIntervalSince(firstEditAt!))
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(0, delay), remaining), execute: work)
    }

    @discardableResult
    func flush() -> Bool {
        work?.cancel()
        work = nil
        do {
            try action?()
            try saveContext?()
            let hadChanges = action != nil
            action = nil
            firstEditAt = nil
            errorMessage = nil
            Self.pending.removeValue(forKey: id)
            if hadChanges || state == .failed { setState(.saved) }
            return true
        } catch {
            Self.pending[id] = self
            errorMessage = "Couldn't save your changes. \(error.localizedDescription)"
            setState(.failed)
            onError?(errorMessage!)
            return false
        }
    }

    private func setState(_ value: EditorController.SaveState) {
        state = value
        onStateChange?(value)
    }

    /// Unsaved edits that `rescueAll` can't write out (no rescue handler).
    static var unrescuablePendingCount: Int {
        pending.values.filter { $0.action != nil && $0.rescue == nil }.count
    }

    /// Writes every unsaved edit that supports it into `folder`, so quitting
    /// after a persistent save failure doesn't lose typing. Returns the files.
    static func rescueAll(to folder: URL) throws -> [URL] {
        let rescuable = pending.values.filter { $0.action != nil && $0.rescue != nil }
        guard !rescuable.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try rescuable.map { try $0.rescue!(folder) }
    }

    /// A file URL in `folder` named after `name` (sanitized, never clobbering).
    nonisolated static func rescueURL(named name: String, extension ext: String, in folder: URL) -> URL {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters))
            .joined().trimmingCharacters(in: .whitespaces)
        let base = String((cleaned.isEmpty ? "Unsaved Page" : cleaned).prefix(60))
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext); suffix += 1
        }
        return url
    }

    /// Used before export and normal application termination. Do not short-circuit:
    /// a failure in one window must not prevent the others from being saved.
    @discardableResult
    static func flushAll() -> Bool {
        registered = registered.filter { $0.value.value != nil }
        let coordinators = registered.values.compactMap(\.value)
        var success = true
        for coordinator in coordinators {
            if !coordinator.flush() { success = false }
        }
        return success
    }
}
