//  SectionLock.swift
//  Tracks which locked sections have been unlocked with Touch ID/the Mac
//  password during this run of the app. Deliberately in-memory only -
//  every relaunch starts with every locked section locked again, and
//  nothing here is ever written to the SwiftData store, so the unlocked
//  state itself can't leak which sections exist or were opened.

import Foundation
import SwiftData
import LocalAuthentication

@MainActor
final class SectionLockStore: ObservableObject {
    @Published private var unlockedSectionIDs: Set<PersistentIdentifier> = []

    func isUnlocked(_ section: NoteSection?) -> Bool {
        guard let section, section.isLocked else { return true }
        return unlockedSectionIDs.contains(section.persistentModelID)
    }

    /// True if `page` can be shown right now - either it isn't in a locked
    /// section, or that section has already been unlocked this session.
    func canShow(_ page: Page) -> Bool {
        isUnlocked(page.section)
    }

    /// Prompts Touch ID / the Mac password if `section` is locked and not
    /// already unlocked this session. `completion(true)` means the caller
    /// is clear to show the section's contents.
    func requestUnlock(_ section: NoteSection, reason: String, completion: @escaping (Bool) -> Void) {
        if isUnlocked(section) { completion(true); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        let id = section.persistentModelID
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            Task { @MainActor in
                if success { self?.unlockedSectionIDs.insert(id) }
                completion(success)
            }
        }
    }

    /// Re-locks a section immediately, without waiting for relaunch -
    /// used when the user turns "Lock This Section" on while it's open.
    func lockNow(_ section: NoteSection) {
        unlockedSectionIDs.remove(section.persistentModelID)
    }
}
