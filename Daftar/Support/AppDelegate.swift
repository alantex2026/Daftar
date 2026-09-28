//  AppDelegate.swift
//  Just enough AppKit delegate to make the window remember its size and
//  position across relaunches.
//
//  This needs two things, not one: setting `setFrameAutosaveName` alone
//  isn't enough - it fights with AppKit's own secure-state-restoration
//  system (the thing that reopens windows after a crash or "log back in").
//  Both try to own the window's frame, and the result is the window closing
//  itself shortly after launch. Opting out of secure restorable state hands
//  frame ownership to the simpler autosave mechanism alone.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SaveCoordinator.flushAll() else { return askToQuitWithUnsavedChanges() }
        return .terminateNow
    }

    /// Saving keeps failing (damaged data, full disk, read-only store...). Never
    /// trap the user in the app, and never let quitting silently drop typing:
    /// offer to write copies of the unsaved pages first.
    private func askToQuitWithUnsavedChanges() -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Your changes couldn't be saved.")
        let unrescuable = SaveCoordinator.unrescuablePendingCount
        alert.informativeText = unrescuable == 0
            ? String(localized: "You can keep working and retry, or save copies of your unsaved pages to a folder and quit.")
            : String(localized: "You can keep working and retry, or save copies of your unsaved pages and quit. Some other changes (such as a new tag or paper size) can't be copied and will be lost.")
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.addButton(withTitle: String(localized: "Save Copies and Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaftarRecovery/Unsaved \(stamp)", isDirectory: true)
        do {
            let files = try SaveCoordinator.rescueAll(to: folder)
            if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
            return .terminateNow
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = String(localized: "Copies couldn't be saved, so Daftar will stay open.")
            failure.runModal()
            return .terminateCancel
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.first?.setFrameAutosaveName("Daftar.MainWindow")
    }
}
