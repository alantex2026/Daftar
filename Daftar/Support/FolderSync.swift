import Foundation
import SwiftData
import CryptoKit

struct SyncRecord: Codable, Equatable, Sendable {
    var clock: [String: UInt64]
    var notebook: NotebookArchive?

    func dominates(_ other: SyncRecord) -> Bool {
        Set(clock.keys).union(other.clock.keys).allSatisfy { clock[$0, default: 0] >= other.clock[$0, default: 0] }
    }
    static func digest(_ notebook: NotebookArchive?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(notebook)).map { String(format: "%02x", $0) }.joined()
    }
    /// Both devices make the same choice for concurrent edits, then retain the
    /// other version as a separate, deterministically identified notebook.
    static func merge(_ local: SyncRecord, _ remote: SyncRecord,
                      conflictCopy: (NotebookArchive, String) throws -> NotebookArchive = { try $0.conflictCopy(namespace: $1) })
        throws -> (record: SyncRecord, conflict: NotebookArchive?) {
        if local.dominates(remote) && local.clock != remote.clock { return (local, nil) }
        if remote.dominates(local) && local.clock != remote.clock { return (remote, nil) }
        var mergedClock = local.clock
        for (device, counter) in remote.clock { mergedClock[device] = max(counter, mergedClock[device, default: 0]) }
        if local.notebook == remote.notebook { return (SyncRecord(clock: mergedClock, notebook: local.notebook), nil) }
        // Preserve an edit when it competes with deletion; deletion can be retried
        // explicitly after the conflict has been resolved by the user.
        if local.notebook == nil { return (SyncRecord(clock: mergedClock, notebook: remote.notebook), nil) }
        if remote.notebook == nil { return (SyncRecord(clock: mergedClock, notebook: local.notebook), nil) }
        let localHash = try digest(local.notebook), remoteHash = try digest(remote.notebook)
        let winner = localHash < remoteHash ? local.notebook : remote.notebook
        let loser = localHash < remoteHash ? remote.notebook! : local.notebook!
        let conflict = try conflictCopy(loser, min(localHash, remoteHash) + max(localHash, remoteHash))
        return (SyncRecord(clock: mergedClock, notebook: winner), conflict)
    }
}

struct SyncEnvelope: Codable, Sendable {
    /// Version 2 keeps page payloads in `Daftar Sync/blobs`; version 1 kept them inline.
    static let currentVersion = 2
    var formatVersion = SyncEnvelope.currentVersion
    var deviceID: String
    var records: [String: SyncRecord] = [:]

    /// Every blob hash this envelope's records point at, as written.
    var references: Set<String> {
        records.values.compactMap(\.notebook).reduce(into: Set<String>()) { $0.formUnion(SyncBlobs.references($1)) }
    }

    /// Brings any envelope - older versions carried page history, and version 1
    /// carried payloads inline - to the form every comparison and merge uses:
    /// no history (it stays on each Mac) and large payloads moved into `store`.
    mutating func dehydrate(store: inout [String: Data]) {
        for (id, record) in records {
            if let notebook = record.notebook {
                records[id]?.notebook = SyncBlobs.dehydrate(notebook.withoutHistory, store: &store)
            }
        }
    }

    func validate() throws {
        guard (1...Self.currentVersion).contains(formatVersion), UUID(uuidString: deviceID) != nil else { throw LibraryBackup.BackupError.invalidFormat }
        for (id, record) in records {
            guard UUID(uuidString: id) != nil,
                  record.clock.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 }),
                  record.notebook == nil || record.notebook?.stableID?.uuidString == id else { throw LibraryBackup.BackupError.invalidFormat }
            if let notebook = record.notebook {
                // Hashes become file names; reject anything that isn't one.
                guard SyncBlobs.references(notebook).allSatisfy(SyncBlobs.isValidHash) else { throw LibraryBackup.BackupError.invalidFormat }
                try LibraryBackup(notebooks: [notebook], savedSearches: []).validate()
            }
        }
    }
}

extension NotebookArchive {
    func conflictCopy(namespace: String) throws -> NotebookArchive {
        func id(_ original: UUID) -> UUID {
            let bytes = Array(SHA256.hash(data: Data((namespace + original.uuidString).utf8)).prefix(16))
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        let mapping = Dictionary(uniqueKeysWithValues: pageIDs.map { ($0, id($0)) })
        func page(_ original: PageRecord) throws -> PageRecord {
            var copy = original; copy.linkID = id(original.linkID)
            copy.outgoingLinkIDs = original.outgoingLinkIDs?.map { mapping[$0] ?? $0 }
            if let data = copy.contentData { copy.contentData = try PageContentCodec.remapLinks(data, ids: mapping) }
            if let data = copy.historyData, var history = try? JSONDecoder().decode([PageRevision].self, from: data) {
                for index in history.indices {
                    history[index].outgoingLinkIDs = history[index].outgoingLinkIDs.map { mapping[$0] ?? $0 }
                    if let data = history[index].contentData { history[index].contentData = try PageContentCodec.remapLinks(data, ids: mapping) }
                }
                copy.historyData = try JSONEncoder().encode(history)
            }
            copy.children = try original.children.map(page)
            return copy
        }
        func section(_ original: SectionRecord) throws -> SectionRecord {
            var copy = original; copy.stableID = original.stableID.map(id)
            copy.pages = try original.pages.map(page); copy.children = try original.children.map(section)
            return copy
        }
        var copy = self; copy.stableID = stableID.map(id)
        copy.name += " (Sync conflict)"
        copy.sections = try sections.map(section)
        return copy
    }
}

/// Each device writes only its own envelope; cloud file providers never have to
/// merge simultaneous writes to one file. Vector clocks detect offline edits.
@MainActor
final class FolderSync: ObservableObject {
    @Published private(set) var status = "Sync is off"
    @Published private(set) var lastSync: Date?
    @Published private(set) var busy = false
    @Published private(set) var enabled: Bool
    /// Sync stopped for a reason the user has to act on (locked sections, a
    /// damaged or unreachable folder). Shown as a badge on the toolbar icon;
    /// temporary conditions that retry by themselves don't set it.
    @Published private(set) var needsAttention = false
    private let defaults: UserDefaults
    private let localDirectory: URL
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var context: ModelContext?
    private weak var locks: SectionLockStore?
    private var saveObserver: NSObjectProtocol?
    /// Set whenever any model context saves; lets the periodic timer skip work.
    private var localChanged = true
    /// Counts model saves, to detect edits made while a sync was running.
    private var saveCount = 0
    /// Other devices' sync files as last seen (name, size, date).
    private var lastRemoteSignature: String?
    /// Digest of the envelope this device last published, to avoid re-uploading it.
    private var lastPublishedDigest: String?

    init(defaults: UserDefaults = .standard, localDirectory: URL? = nil) {
        self.defaults = defaults
        enabled = defaults.data(forKey: "syncFolderBookmark") != nil
        self.localDirectory = localDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DaftarRecovery", isDirectory: true)
        status = enabled ? "Ready to sync" : "Sync is off"
    }

    func attach(context: ModelContext, locks: SectionLockStore) {
        self.context = context; self.locks = locks
        guard timer == nil else { return }
        // Delivered synchronously so saves made during a sync are cleared by it.
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread { MainActor.assumeIsolated { self?.noteSave() } }
            else { Task { @MainActor in self?.noteSave() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow(onlyIfChanged: true) }
        }
        // Locked sections need one Touch ID check per launch before
        // background sync can include them; ask up front rather than
        // leaving sync silently paused.
        if enabled { authorizeAndSync() }
    }

    /// Gets this launch's sync permission for locked sections (asking at
    /// most once), then syncs. Used at launch, by Sync Now and by setup.
    func authorizeAndSync() {
        guard enabled, let context, let locks else { return }
        guard let sections = try? context.fetch(FetchDescriptor<NoteSection>()) else { syncNow(); return }
        locks.authorizeSync(for: sections) { [weak self] allowed in
            guard let self else { return }
            if allowed { self.syncNow() }
            else { self.status = "Sync paused: confirm with Touch ID or your password, then choose Sync Now."; self.needsAttention = true }
        }
    }

    private func noteSave() { localChanged = true; saveCount += 1 }

    func chooseFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "syncFolderBookmark")
        lastRemoteSignature = nil; lastPublishedDigest = nil
        enabled = true; status = "Ready to sync"
    }
    func disable() {
        syncTask?.cancel()
        defaults.removeObject(forKey: "syncFolderBookmark")
        enabled = false; status = "Sync is off"; needsAttention = false
    }

    /// `onlyIfChanged` (used by the timer) skips the full library capture when
    /// nothing was saved locally and no other device's sync file changed.
    func syncNow(onlyIfChanged: Bool = false) {
        guard enabled, !busy, let context, let locks else { return }
        busy = true; status = "Syncing…"
        syncTask = Task {
            defer { busy = false }
            do {
                guard let bookmark = defaults.data(forKey: "syncFolderBookmark") else { return }
                var stale = false
                let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                if stale { try chooseFolder(folder) }
                try await synchronize(folder: folder, context: context, locks: locks, onlyIfChanged: onlyIfChanged)
                if enabled { lastSync = Date(); status = "Synced with folder"; needsAttention = false }
            } catch is CancellationError { status = enabled ? "Sync cancelled" : "Sync is off" }
            catch LibraryBackup.BackupError.locked {
                if enabled { status = "Sync paused: confirm with Touch ID or your password, then choose Sync Now."; needsAttention = true }
            } catch is SyncBlobs.BlobError { if enabled { status = SyncBlobs.BlobError.missing("").localizedDescription } }
            catch SyncError.libraryChanged { if enabled { status = SyncError.libraryChanged.localizedDescription } }
            catch { if enabled { status = error.localizedDescription; needsAttention = true } }
        }
    }

    func synchronize(folder: URL, context: ModelContext, locks: SectionLockStore, onlyIfChanged: Bool = false) async throws {
        guard locks.canCapture(try context.fetch(FetchDescriptor<NoteSection>()), forSync: true) else {
            throw LibraryBackup.BackupError.locked
        }
        let localDirectory = localDirectory
        let key = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let stateURL = localDirectory.appendingPathComponent("sync-\(key).json")
        let syncDirectory = folder.appendingPathComponent("Daftar Sync", isDirectory: true)
        let blobDirectory = syncDirectory.appendingPathComponent("blobs", isDirectory: true)
        // File providers may need to download files. Never block AppKit's main
        // thread on coordinated I/O or hashing; only model access happens here.
        let skipIfRemoteSignature = onlyIfChanged && !localChanged ? lastRemoteSignature : nil
        let loaded = try await Task.detached(priority: .utility) { () throws -> Loaded? in
            try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
            var known: [String: Data] = [:]
            var previouslyPublished = Set<String>(), otherDevicesUse = Set<String>()
            var state: SyncEnvelope
            var stateDigest: String?
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                state = try JSONDecoder().decode(SyncEnvelope.self, from: data)
                try state.validate()
                stateDigest = Self.digest(data)
                previouslyPublished = state.references  // before history is stripped
                state.dehydrate(store: &known)
            } else { state = SyncEnvelope(deviceID: UUID().uuidString) }
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(at: syncDirectory, includingPropertiesForKeys: keys)
                .filter { $0.pathExtension == "daftarsync" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let signature = files.filter { $0.lastPathComponent != state.deviceID + ".daftarsync" }.map { file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                return "\(file.lastPathComponent)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.joined(separator: "\n")
            // Nothing changed here or on other devices: don't download or decode anything.
            if signature == skipIfRemoteSignature { return nil }
            let remotes = try files.map { file in
                var value = try JSONDecoder().decode(SyncEnvelope.self, from: Self.coordinatedRead(file))
                try value.validate()
                // As written: another Mac on an older build may still use history blobs.
                if value.deviceID == state.deviceID { previouslyPublished.formUnion(value.references) }
                else { otherDevicesUse.formUnion(value.references) }
                value.dehydrate(store: &known)
                return value
            }
            return Loaded(state: state, stateDigest: stateDigest, remotes: remotes, signature: signature, known: known,
                          previouslyPublished: previouslyPublished, otherDevicesUse: otherDevicesUse)
        }.value
        try Task.checkCancellation()
        guard let loaded else { return }
        var finished = false
        // A failed sync must not let the timer skip these edits next time.
        defer { if !finished { localChanged = true } }
        // Structured history: no main-thread JSON encoding of every page's revisions.
        // Page history isn't synced: it stays on each Mac, and would otherwise
        // upload every version of every picture.
        let backup = try LibraryBackup.capture(context: context, locks: locks, defaults: defaults, includeHistory: false, forSync: true)
        localChanged = false  // Everything saved so far, including the capture's flush, is in `backup`.
        let savesAtCapture = saveCount

        let plan = try await Task.detached(priority: .utility) { () throws -> Plan in
            let blobs = BlobSource(known: loaded.known, directory: blobDirectory)
            var current: [String: NotebookArchive] = [:]
            for note in backup.notebooks {
                if let id = note.stableID { current[id.uuidString] = SyncBlobs.dehydrate(note, store: &blobs.known) }
            }
            var state = loaded.state
            state.formatVersion = SyncEnvelope.currentVersion
            let deviceID = state.deviceID
            for id in Set(current.keys).union(state.records.keys) {
                if state.records[id]?.notebook != current[id] || state.records[id] == nil {
                    var record = state.records[id] ?? SyncRecord(clock: [:], notebook: nil)
                    guard record.clock[deviceID, default: 0] < UInt64.max else { throw LibraryBackup.BackupError.invalidFormat }
                    record.clock[deviceID, default: 0] += 1; record.notebook = current[id]; state.records[id] = record
                }
            }
            // Conflict copies rewrite internal links inside page content, so they
            // are made from the full notebook and then moved back into blobs.
            let copier: (NotebookArchive, String) throws -> NotebookArchive = { loser, namespace in
                let copy = try SyncBlobs.hydrate(loser, blob: blobs.data).conflictCopy(namespace: namespace)
                return SyncBlobs.dehydrate(copy, store: &blobs.known)
            }
            for remote in loaded.remotes {
                for (id, incoming) in remote.records {
                    if let local = state.records[id] {
                        let merged = try SyncRecord.merge(local, incoming, conflictCopy: copier)
                        state.records[id] = merged.record
                        if let conflict = merged.conflict, let conflictID = conflict.stableID?.uuidString, state.records[conflictID] == nil {
                            state.records[conflictID] = SyncRecord(clock: merged.record.clock, notebook: conflict)
                        }
                    } else { state.records[id] = incoming }
                }
            }
            let desired = state.records.compactMapValues(\.notebook)
            let removals = Set(current.keys.filter { desired[$0] != current[$0] })
            // Fails with BlobError.missing (before anything is modified) when a
            // payload another device uploaded hasn't finished syncing yet.
            var additions: [NotebookArchive] = []
            for (id, archive) in desired.sorted(by: { $0.key < $1.key }) where archive != current[id] {
                additions.append(try SyncBlobs.hydrate(archive, blob: blobs.data))
            }
            let referenced = desired.values.reduce(into: Set<String>()) { $0.formUnion(SyncBlobs.references($1)) }
            let inUse = referenced.union(loaded.otherDevicesUse)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(state)
            return Plan(bytes: bytes, digest: Self.digest(bytes), removals: removals, additions: additions,
                        payloads: blobs.known.filter { referenced.contains($0.key) }, inUse: inUse,
                        previouslyPublished: loaded.previouslyPublished)
        }.value
        try Task.checkCancellation()

        if !plan.removals.isEmpty || !plan.additions.isEmpty {
            // Keep a complete, local recovery file before replacing any models.
            let recovery = localDirectory.appendingPathComponent("before-sync-\(UUID().uuidString).daftarbackup")
            try await Task.detached(priority: .utility) { try backup.write(to: recovery) }.value
            // Replacing a notebook must never discard an edit made after the capture.
            guard SaveCoordinator.flushAll(), saveCount == savesAtCapture else { throw SyncError.libraryChanged }
            try context.save()
            let changedPages: Set<UUID>
            do {
                // Update the existing models in place (matched by stable IDs) so
                // open windows keep their selection instead of being rebuilt.
                var reconciler = try LibraryReconciler(context: context)
                try reconciler.apply(plan.additions, replacing: Set(plan.removals.compactMap(UUID.init(uuidString:))))
                try context.save()
                changedPages = reconciler.changedPages
                localChanged = false  // The merged result is what gets published below.
            } catch { context.rollback(); throw error }
            if !changedPages.isEmpty {
                NotificationCenter.default.post(name: .daftarReloadEditors, object: changedPages)
            }
        }
        let bytes = plan.bytes, digest = plan.digest
        // Checkpoint first. If publishing fails, the next sync still retries it.
        if digest != loaded.stateDigest {
            try await Task.detached(priority: .utility) { try bytes.write(to: stateURL, options: .atomic) }.value
        }
        try Task.checkCancellation()
        let deviceID = loaded.state.deviceID
        let published = syncDirectory.appendingPathComponent(deviceID + ".daftarsync")
        // Re-uploading an unchanged manifest makes Dropbox/iCloud transfer it
        // again, so only publish when its contents changed.
        let needsPublish = digest != lastPublishedDigest || !FileManager.default.fileExists(atPath: published.path)
        try await Task.detached(priority: .utility) {
            // Payloads go first so other devices rarely see a manifest before its files.
            // Missing ones are rewritten on every sync, which also repairs deletions.
            let existing = SyncBlobs.inventory(in: blobDirectory)
            for (key, data) in plan.payloads where existing[key] == nil {
                let file = SyncBlobs.url(for: key, in: blobDirectory)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.coordinatedWrite(data, to: file)
            }
            if needsPublish { try Self.coordinatedWrite(bytes, to: published) }
            // Unreferenced payloads are kept for a week, in case another device
            // published a manifest that hasn't reached this Mac yet.
            // Blobs only this Mac's previous upload used go right away; anything
            // else waits a week in case another Mac's upload is still arriving.
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            for (key, modified) in existing where !plan.inUse.contains(key)
                && (plan.previouslyPublished.contains(key) || modified < cutoff) {
                try? FileManager.default.removeItem(at: SyncBlobs.url(for: key, in: blobDirectory))
            }
            let backups = try FileManager.default.contentsOfDirectory(at: localDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "daftarbackup" && $0.lastPathComponent.hasPrefix("before-sync-") }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in backups.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        }.value
        lastPublishedDigest = digest
        lastRemoteSignature = loaded.signature
        finished = true
    }

    private struct Loaded: Sendable {
        var state: SyncEnvelope
        var stateDigest: String?
        var remotes: [SyncEnvelope]
        var signature: String
        var known: [String: Data]
        /// Blob hashes this Mac's last published manifest used.
        var previouslyPublished: Set<String>
        /// Blob hashes other Macs' manifests use, as written by them.
        var otherDevicesUse: Set<String>
    }

    private struct Plan: Sendable {
        var bytes: Data
        var digest: String
        var removals: Set<String>
        var additions: [NotebookArchive]
        /// Payloads referenced by this device's manifest, by hash.
        var payloads: [String: Data]
        /// Every hash any device's manifest still references.
        var inUse: Set<String>
        var previouslyPublished: Set<String>
    }

    /// Payloads already in memory, falling back to the sync folder's blob files.
    private final class BlobSource {
        var known: [String: Data]
        let directory: URL
        init(known: [String: Data], directory: URL) { self.known = known; self.directory = directory }
        func data(_ key: String) throws -> Data {
            if let data = known[key] { return data }
            let data = try SyncBlobs.read(key, in: directory)
            known[key] = data
            return data
        }
    }

    enum SyncError: LocalizedError {
        case libraryChanged
        var errorDescription: String? { "Notes changed during sync. Daftar will try again shortly." }
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?; var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try Data(contentsOf: coordinated) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?; var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do { try data.write(to: coordinated, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    var recoveryDirectory: URL { localDirectory }
}

