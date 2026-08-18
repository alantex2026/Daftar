//  DaftarApp.swift
//  The starting point. `@main` means: run this first.

import SwiftUI
import SwiftData

@main
struct DaftarApp: App {

    // One shared editor "remote control" so the menu bar shortcuts work too.
    @StateObject private var editor = EditorController()
    @StateObject private var sectionLock = SectionLockStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(editor: editor)
                .environmentObject(sectionLock)
                .preferredColorScheme(preferredColorScheme)
        }
        // This one line creates the local database file for us.
        .modelContainer(for: [Notebook.self, NoteSection.self, Page.self])
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Format") {
                Button("Bold") { editor.toggleBold() }.keyboardShortcut("b", modifiers: .command)
                Button("Italic") { editor.toggleItalic() }.keyboardShortcut("i", modifiers: .command)
                Button("Underline") { editor.toggleUnderline() }.keyboardShortcut("u", modifiers: .command)
                Button("Strikethrough") { editor.toggleStrikethrough() }.keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Bigger Text") { editor.stepFontSize(by: 2) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { editor.stepFontSize(by: -2) }.keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Bulleted List") { editor.toggleBullet(numbered: false) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Numbered List") { editor.toggleBullet(numbered: true) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Checklist") { editor.toggleChecklist() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Insert Date and Time") { editor.insertDate(includeTime: true) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Find in Page") { editor.showFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            PreferencesView(editor: editor)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
