//  DaftarApp.swift
//  The starting point. `@main` means: run this first.

import SwiftUI
import SwiftData

@main
struct DaftarApp: App {

    @StateObject private var folderSync = FolderSync()
    @StateObject private var sectionLock = SectionLockStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        WindowGroup(id: NotebookWindow.sceneID) {
            if isTestHost {
                Color.clear
            } else {
                NotebookWindow()
                    .environmentObject(sectionLock)
                    .environmentObject(folderSync)
                    .themedAppearance()
            }
        }
        // This one line creates the local database file for us.
        .modelContainer(for: [Notebook.self, NoteSection.self, Page.self, PagePayload.self, PageRevisionEntry.self], inMemory: isTestHost)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { EditorCommands() }

        Settings {
            PreferencesView()
                .themedAppearance()
        }
    }
}

/// Each window owns its own AppKit editor target and navigation callbacks.
struct NotebookWindow: View {
    static let sceneID = "notebook"
    @StateObject private var editor = EditorController()
    @SceneStorage("windowSessionID") private var sessionID = ""
    @State private var claimed = false
    var body: some View {
        ZStack {
            if claimed { ContentView(editor: editor, sessionID: sessionID) }
            else { Color.clear }
        }
        .task {
            guard !claimed else { return }
            sessionID = SessionStore.claimWindow(sessionID)
            claimed = true
        }
        .onDisappear { SessionStore.releaseWindow(sessionID); claimed = false }
    }
}

struct FocusedEditorKey: FocusedValueKey {
    typealias Value = EditorController
}

/// Adds a blank page to the focused window's current section.
struct NewPageAction {
    let perform: () -> Void
}

struct FocusedNewPageKey: FocusedValueKey {
    typealias Value = NewPageAction
}

extension FocusedValues {
    var notebookEditor: EditorController? {
        get { self[FocusedEditorKey.self] }
        set { self[FocusedEditorKey.self] = newValue }
    }
    var newPageAction: NewPageAction? {
        get { self[FocusedNewPageKey.self] }
        set { self[FocusedNewPageKey.self] = newValue }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.notebookEditor) private var editor
    @FocusedValue(\.spreadsheetUndo) private var spreadsheetUndo
    @FocusedValue(\.newPageAction) private var newPage
    @FocusedValue(\.quickOpenAction) private var quickOpen
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        // Cmd N makes a page, as in Notes; a new window moves to Shift Cmd N.
        CommandGroup(replacing: .newItem) {
            Button("New Page") { newPage?.perform() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newPage == nil)
            Button("New Window") { openWindow(id: NotebookWindow.sceneID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // Cmd O, as in other notes apps; Cmd P is Print.
            Button("Go to Page\u{2026}") { quickOpen?.perform() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(quickOpen == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            if let spreadsheetUndo {
                Button("Undo", action: spreadsheetUndo.undo).keyboardShortcut("z").disabled(!spreadsheetUndo.canUndo)
                Button("Redo", action: spreadsheetUndo.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!spreadsheetUndo.canRedo)
            } else {
                Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { editor?.printPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(editor == nil)
        }

            CommandMenu("Format") {
                Group {
                Button("Bold") { editor?.toggleBold() }.keyboardShortcut("b", modifiers: .command)
                Button("Italic") { editor?.toggleItalic() }.keyboardShortcut("i", modifiers: .command)
                Button("Underline") { editor?.toggleUnderline() }.keyboardShortcut("u", modifiers: .command)
                Button("Strikethrough") { editor?.toggleStrikethrough() }.keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Bigger Text") { editor?.stepFontSize(by: 2) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { editor?.stepFontSize(by: -2) }.keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Bulleted List") { editor?.toggleBullet(numbered: false) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Numbered List") { editor?.toggleBullet(numbered: true) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Checklist") { editor?.toggleChecklist() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Insert Date and Time") { editor?.insertDate(includeTime: true) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Find in Page") { editor?.showFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
                }
                .disabled(editor == nil)
            }
    }
}
