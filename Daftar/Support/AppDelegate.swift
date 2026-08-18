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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.first?.setFrameAutosaveName("Daftar.MainWindow")
    }
}
