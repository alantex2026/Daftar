import Foundation
import SwiftData
import LocalAuthentication

@MainActor
final class SectionLockStore: ObservableObject {
    typealias Authenticate = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
    @Published private var unlockedSectionIDs: Set<PersistentIdentifier> = []
    private let authenticate: Authenticate

    init(authenticate: @escaping Authenticate = SectionLockStore.authenticateOwner) {
        self.authenticate = authenticate
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
}
