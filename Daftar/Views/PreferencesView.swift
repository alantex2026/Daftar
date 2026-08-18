//  PreferencesView.swift
//  The Settings window (Cmd+,). Just the few app-wide preferences that
//  should survive a relaunch instead of quietly resetting every time.

import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var editor: EditorController
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("editorFontName") private var editorFontName = "System"
    @AppStorage("editorFontSize") private var editorFontSize: Double = 13
    @AppStorage("autoEmptyTrashEnabled") private var autoEmptyTrashEnabled = true
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Show sidebar when Daftar opens", isOn: $showSidebar)
            }

            Section("Editor") {
                Toggle("Check spelling while typing", isOn: $editor.spellCheckOn)
                Stepper("Zoom: \(Int(editor.zoom * 100))%", value: $editor.zoom, in: 0.5...2.0, step: 0.1)
                Picker("Default font", selection: $editorFontName) {
                    Text("System").tag("System")
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper("Default size: \(Int(editorFontSize))pt", value: $editorFontSize, in: 9...24, step: 1)
                Text("Applies to new pages, not ones already written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saving") {
                Stepper("Auto-save delay: \(editor.autoSaveDelay, specifier: "%.1f")s",
                        value: $editor.autoSaveDelay, in: 0.1...3.0, step: 0.1)
                Text("How long to wait after you stop typing before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trash") {
                Toggle("Empty trash automatically", isOn: $autoEmptyTrashEnabled)
                Text("Removes items older than \(TrashMaintenance.retentionDays) days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Help") {
                Button("Show Onboarding Tour Again") { hasSeenOnboarding = false }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
    }
}
