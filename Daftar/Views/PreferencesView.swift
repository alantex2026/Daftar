//  PreferencesView.swift
//  The Settings window (Cmd+,). Just the few app-wide preferences that
//  should survive a relaunch instead of quietly resetting every time.

import SwiftUI
import AppKit

struct PreferencesView: View {
    @AppStorage(AppSettings.spellCheckEnabled) private var spellCheckOn = true
    @AppStorage(AppSettings.editorZoom) private var zoom = 1.0
    @AppStorage(AppSettings.autoSaveDelay) private var autoSaveDelay = 1.0
    @AppStorage(AppSettings.showSidebar) private var showSidebar = true
    @AppStorage(AppSettings.appearanceMode) private var appearanceMode = "system"
    @AppStorage(AppSettings.editorFontName) private var editorFontName = "System"
    @AppStorage(AppSettings.editorFontSize) private var editorFontSize: Double = 13
    @AppStorage(AppSettings.autoEmptyTrashEnabled) private var autoEmptyTrashEnabled = true
    @AppStorage(AppSettings.autoLockSections) private var autoLockSections = true
    @AppStorage(AppSettings.hasSeenOnboarding) private var hasSeenOnboarding = true
    @AppStorage(AppSettings.defaultImageSize) private var defaultImageSize = InsertedImageSize.medium.rawValue
    @AppStorage(AppSettings.imageCompressionKey) private var imageCompression = ImageCompression.original.rawValue

    private var colorTheme: Binding<ColorTheme> {
        Binding(get: { ThemeStore.shared.theme }, set: { ThemeStore.shared.theme = $0 })
    }

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Colors", selection: colorTheme) {
                    ForEach(ColorTheme.allCases) { theme in
                        HStack(spacing: 8) {
                            Text(theme.title)
                            HStack(spacing: 2) {
                                ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, color in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(color)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                                        .frame(width: 14, height: 14)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                        .tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Theme", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .disabled(ThemeStore.shared.theme.forcedColorScheme != nil)
                if ThemeStore.shared.theme.forcedColorScheme != nil {
                    Text("Desert is a light theme, so it always uses Light mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show sidebar when Daftar opens", isOn: $showSidebar)
            }

            Section("Editor") {
                Toggle("Check spelling while typing", isOn: $spellCheckOn)
                Stepper("Zoom: \(Int(zoom * 100))%", value: $zoom, in: 0.5...2.0, step: 0.1)
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
                Picker("Default image size", selection: $defaultImageSize) {
                    ForEach(InsertedImageSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Size of newly inserted pictures compared with their original size, never wider than the page. Right-click a picture to change its size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Compress new pictures", selection: $imageCompression) {
                    ForEach(ImageCompression.allCases, id: \.self) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                Text("Makes pages, backups and sync smaller. Pictures with transparency stay PNG, animations are never changed, and a picture is only replaced when that saves space. Pictures already in your notes aren't changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saving") {
                Stepper("Auto-save delay: \(autoSaveDelay, specifier: "%.1f")s",
                        value: $autoSaveDelay, in: 0.5...30.0, step: 0.5)
                Text("How long to wait after you stop typing before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Lock sections when the Mac sleeps or locks", isOn: $autoLockSections)
                Text("Locked sections you've opened close again and need Touch ID or your password. Background sync keeps working.")
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
