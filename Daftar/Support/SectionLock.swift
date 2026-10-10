import AppKit
import SwiftData
import LocalAuthentication

@MainActor
final class SectionLockStore: ObservableObject {
    typealias Authenticate = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
    @Published private var unlockedSectionIDs: Set<PersistentIdentifier> = []
    private let authenticate: Authenticate

    private var lockObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(authenticate: @escaping Authenticate = SectionLockStore.authenticateOwner) {
        self.authenticate = authenticate
        // Walking away from the Mac shouldn't leave private sections open:
        // relock them when it sleeps, its display sleeps, or the screen locks.
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name) in [(workspace, NSWorkspace.willSleepNotification),
                               (workspace, NSWorkspace.screensDidSleepNotification),
                               (distributed as NotificationCenter, Notification.Name("com.apple.screenIsLocked"))] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockAllIfEnabled() }
            }
            lockObservers.append((center, token))
        }
    }

    /// Relocks every section unlocked this session (Settings > Privacy). The
    /// once-per-launch background sync permission is kept.
    func lockAllIfEnabled(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: AppSettings.autoLockSections) as? Bool ?? true else { return }
        lockAll()
    }

    func lockAll() {
        if !unlockedSectionIDs.isEmpty { unlockedSectionIDs.removeAll() }
    }

    private static func authenticateOwner(_ reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            Task { @MainActor in completion(success) }
        }
    }

    private func lockedAncestors(of section: NoteSection?) -> [NoteSection] {
        var result: [NoteSection] = []
        var current = section
        while let item = current {
            if item.isLocked { result.append(item) }
            current = item.parent
        }
        return result
    }

    func isUnlocked(_ section: NoteSection?) -> Bool {
        lockedAncestors(of: section).allSatisfy { unlockedSectionIDs.contains($0.persistentModelID) }
    }

    func canShow(_ page: Page) -> Bool { isUnlocked(page.section) }

    func requestUnlock(_ section: NoteSection, reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        requestUnlock(sections: [section], reason: reason, completion: completion)
    }

    func requestUnlock(sections: [NoteSection], reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let required = sections.flatMap { lockedAncestors(of: $0) }
            .filter { !unlockedSectionIDs.contains($0.persistentModelID) }
        guard !required.isEmpty else { completion(true); return }
        authenticate(reason) { [weak self] success in
            guard let self else { completion(false); return }
            if success {
                // Resolve IDs after authentication, in case an inserted model was saved meanwhile.
                self.unlockedSectionIDs.formUnion(required.map(\.persistentModelID))
            }
            completion(success)
        }
    }

    func lockNow(_ section: NoteSection) {
        unlockedSectionIDs.remove(section.persistentModelID)
    }

    // MARK: - Background sync

    /// Granted by one Touch ID / password check per run of the app. Lets
    /// sync read locked sections in the background without unlocking them
    /// on screen, so "Lock Now" and relaunching no longer pause sync.
    /// Like unlocks, it lives only in memory and ends when the app quits.
    @Published private(set) var isSyncAuthorized = false
    private var syncAuthorizationWaiters: [@MainActor (Bool) -> Void] = []

    /// Whether sync and backups may read these sections now, without asking.
    func canCapture(_ sections: [NoteSection], forSync: Bool) -> Bool {
        (forSync && isSyncAuthorized) || sections.allSatisfy { isUnlocked($0) }
    }

    /// Asks once per launch, and only if `sections` include locked ones.
    /// Concurrent callers (several windows at launch) share a single prompt.
    func authorizeSync(for sections: [NoteSection], completion: @escaping @MainActor (Bool) -> Void) {
        guard !canCapture(sections, forSync: true) else { completion(true); return }
        syncAuthorizationWaiters.append(completion)
        guard syncAuthorizationWaiters.count == 1 else { return }
        authenticate("sync your locked sections in the background") { [weak self] success in
            guard let self else { return }
            if success { self.isSyncAuthorized = true }
            let waiters = self.syncAuthorizationWaiters
            self.syncAuthorizationWaiters = []
            waiters.forEach { $0(success) }
        }
    }
}
