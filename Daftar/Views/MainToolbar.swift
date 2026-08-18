//  MainToolbar.swift
//  Everything that lives in the window toolbar at the top.

import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

/// A colour that also has a name, used by the colour menus.
struct NamedColor: Identifiable {
    let id = UUID()
    let name: LocalizedStringKey
    let color: NSColor?
    init(_ name: LocalizedStringKey, _ color: NSColor?) { self.name = name; self.color = color }
}

// Every icon-sized control in the format toolbar - toggle buttons, plain
// action buttons, and icon-only menus alike - shares this exact footprint,
// so the row reads as one consistent family of controls instead of a mix of
// differently-sized buttons and default-bezeled menus.
private let barControlSize = CGSize(width: 25, height: 22)
private let barIconFont = Font.system(size: 13, weight: .medium)

/// A small square button that can look "switched on".
struct BarToggle: View {
    let systemName: String
    let isOn: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(barIconFont)
                .frame(width: barControlSize.width, height: barControlSize.height)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? AppTheme.accent : Color.clear))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A flat, icon-only action button - same footprint as `BarToggle`, for
/// actions that don't have an on/off state (Insert Link, bulleted list, ...).
private struct BarButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(barIconFont)
                .frame(width: barControlSize.width, height: barControlSize.height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .help(help)
    }
}

/// A flat, icon-only menu - same footprint as `BarToggle`/`BarButton`, so a
/// menu (text colour, highlight) doesn't stand out as a bezeled square next
/// to the flat toggle buttons around it.
private struct BarMenu<MenuContent: View>: View {
    let systemName: String
    let help: LocalizedStringKey
    @ViewBuilder var content: () -> MenuContent

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemName)
                .font(barIconFont)
                .foregroundStyle(Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: barControlSize.width, height: barControlSize.height)
        .help(help)
    }
}

/// A soft, low-contrast divider that reads as a group separator, not a hard
/// system-drawn rule - matches the subtlety of the pill background it sits in.
private struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 16).opacity(0.5)
    }
}

// MARK: - Style, font, colour, alignment, lists

// Split into separate small groups - each its own toolbar item - instead of
// one wide bundle. A single ~600pt-wide toolbar item either fits entirely or
// vanishes entirely into the ">>" overflow chevron the moment the window
// narrows even slightly; several smaller items let the least essential
// controls (paragraph alignment, lists) overflow first while the basics
// (style, bold/italic/underline) keep working longest.

private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 6, content: content)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
}

struct StyleFormatGroup: View {
    @ObservedObject var editor: EditorController

    var body: some View {
        pill {
            // An icon-only menu instead of a "Normal ▾" text button - the
            // style name isn't visible at a glance anymore, but it's a
            // ~90pt saving on a toolbar that was overflowing into macOS's
            // ">>" chevron (which renders Daftar's custom controls badly)
            // even at fairly ordinary window widths.
            BarMenu(systemName: "textformat.size", help: "Paragraph style") {
                ForEach(EditorController.TextStyle.allCases) { style in
                    Button(style.rawValue) { editor.applyStyle(style) }
                }
            }

            BarDivider()

            BarToggle(systemName: "bold", isOn: editor.isBold, help: "Bold (Cmd B)") { editor.toggleBold() }
            BarToggle(systemName: "italic", isOn: editor.isItalic, help: "Italic (Cmd I)") { editor.toggleItalic() }
            BarToggle(systemName: "underline", isOn: editor.isUnderlined, help: "Underline (Cmd U)") { editor.toggleUnderline() }
            BarToggle(systemName: "strikethrough", isOn: editor.isStrikethrough, help: "Strikethrough (Cmd Shift X)") { editor.toggleStrikethrough() }
        }
    }
}

struct FontFormatGroup: View {
    @ObservedObject var editor: EditorController
    @State private var showLink = false
    @State private var linkText = ""

    private let sizes = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64]

    private let textColors: [NamedColor] = [
        NamedColor("Automatic", .textColor), NamedColor("Red", .systemRed),
        NamedColor("Orange", .systemOrange), NamedColor("Yellow", .systemYellow),
        NamedColor("Green", .systemGreen), NamedColor("Blue", .systemBlue),
        NamedColor("Purple", .systemPurple), NamedColor("Gray", .systemGray)
    ]

    private let highlights: [NamedColor] = [
        NamedColor("Yellow", NSColor.systemYellow.withAlphaComponent(0.45)),
        NamedColor("Green", NSColor.systemGreen.withAlphaComponent(0.35)),
        NamedColor("Blue", NSColor.systemBlue.withAlphaComponent(0.30)),
        NamedColor("Pink", NSColor.systemPink.withAlphaComponent(0.30)),
        NamedColor("None", nil)
    ]

    var body: some View {
        pill {
            Menu("\(Int(editor.fontSize))") {
                ForEach(sizes, id: \.self) { size in
                    Button("\(size)") { editor.setFontSize(CGFloat(size)) }
                }
                Divider()
                Button("Bigger") { editor.stepFontSize(by: 2) }
                Button("Smaller") { editor.stepFontSize(by: -2) }
            }
            .frame(width: 44, height: barControlSize.height)
            .help("Font size")

            BarDivider()

            BarMenu(systemName: "character", help: "Text colour") {
                ForEach(textColors) { item in
                    Button(item.name) { editor.setTextColor(item.color ?? .textColor) }
                }
            }

            BarMenu(systemName: "highlighter", help: "Highlight colour") {
                ForEach(highlights) { item in
                    Button(item.name) { editor.setHighlight(item.color) }
                }
            }

            BarButton(systemName: "link", help: "Add a link") { showLink = true }
                .popover(isPresented: $showLink, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Link address").font(.headline)
                        TextField("https://example.com", text: $linkText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        HStack {
                            Spacer()
                            Button("Cancel") { showLink = false }
                            Button("Apply") {
                                editor.applyLink(linkText); linkText = ""; showLink = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14)
                }
        }
    }
}

struct ParagraphFormatGroup: View {
    @ObservedObject var editor: EditorController
    // Folded in from what used to be its own toolbar item - one less pill
    // means one less thing needing its own padding/divider/inter-item gap,
    // and it belongs here thematically anyway (document structure).
    @State private var showTOC = false

    // One menu instead of three always-visible toggles - the specific
    // alignment isn't visible at a glance anymore, but it's ~50pt back
    // towards a toolbar that fits without overflowing.
    private var alignmentIcon: String {
        switch editor.alignment {
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        default: return "text.alignleft"
        }
    }

    var body: some View {
        pill {
            BarMenu(systemName: alignmentIcon, help: "Paragraph alignment") {
                Button("Align left") { editor.setAlignment(.left) }
                Button("Align centre") { editor.setAlignment(.center) }
                Button("Align right") { editor.setAlignment(.right) }
            }

            BarDivider()

            BarButton(systemName: "list.bullet", help: "Bulleted list") {
                editor.toggleBullet(numbered: false)
            }
            BarButton(systemName: "list.number", help: "Numbered list") {
                editor.toggleBullet(numbered: true)
            }
            BarButton(systemName: "checklist", help: "Checklist (Cmd Shift C)") {
                editor.toggleChecklist()
            }

            BarDivider()

            BarButton(systemName: "list.bullet.indent", help: "Table of Contents") {
                showTOC = true
            }
        }
        .popover(isPresented: $showTOC, arrowEdge: .bottom) {
            TableOfContentsPopover(editor: editor, dismiss: { showTOC = false })
        }
    }
}

// MARK: - Table of Contents

private struct TableOfContentsPopover: View {
    @ObservedObject var editor: EditorController
    let dismiss: () -> Void

    var body: some View {
        let headings = editor.headings()
        VStack(alignment: .leading, spacing: 0) {
            Text("Table of Contents").font(.system(size: 13, weight: .semibold)).padding(12)
            Divider()
            if headings.isEmpty {
                Text("No headings in this page.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(headings) { item in
                            Button {
                                editor.goTo(item)
                                dismiss()
                            } label: {
                                Text(item.text)
                                    .font(.system(size: item.level == 1 ? 13 : 12,
                                                 weight: item.level == 1 ? .semibold : .regular))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, CGFloat(item.level - 1) * 14 + 12)
                            .padding(.trailing, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 260)
    }
}

// MARK: - Tags

struct TagBar: View {
    @ObservedObject var editor: EditorController
    var page: Page?

    var body: some View {
        // A single Menu instead of three quick-tap buttons plus a chevron -
        // narrower, and (unlike a bare row of buttons) a Menu still nests
        // cleanly as a submenu if the toolbar overflows and this item has
        // to move into macOS's own ">>" overflow menu.
        Menu {
            ForEach(PageTag.allCases) { tag in
                Button {
                    page?.tag = tag
                } label: {
                    Label(tag.title, systemImage: tag.symbol)
                }
            }
        } label: {
            Group {
                if let page, page.tag != .none {
                    TagBadge(tag: page.tag, size: 18)
                } else {
                    Image(systemName: "tag").font(barIconFont).foregroundStyle(Color.primary)
                }
            }
            .frame(width: barControlSize.width, height: barControlSize.height)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(page == nil)
        .help("Choose a tag")
    }
}

// MARK: - Insert menu

struct InsertMenu: View {
    @ObservedObject var editor: EditorController
    var page: Page?
    @State private var showLinkPicker = false
    @State private var showRecorder = false

    var body: some View {
        Menu {
            Menu("Table") {
                Button("2 x 2") { editor.insertTable(rows: 2, columns: 2) }
                Button("3 x 3") { editor.insertTable(rows: 3, columns: 3) }
                Button("4 x 4") { editor.insertTable(rows: 4, columns: 4) }
            }
            Button("Picture...") { pickPicture() }
            Button("File Attachment...") { pickFile() }
            Button("Record Audio...") { showRecorder = true }
            Divider()
            Button("Link to Page...") { showLinkPicker = true }
            Divider()
            Button("Date") { editor.insertDate(includeTime: false) }
            Button("Date and Time") { editor.insertDate(includeTime: true) }
        } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .medium))
        }
        .help("Insert into page")
        .popover(isPresented: $showLinkPicker, arrowEdge: .bottom) {
            PageLinkPicker(editor: editor, currentPage: page, dismiss: { showLinkPicker = false })
        }
        .popover(isPresented: $showRecorder, arrowEdge: .bottom) {
            AudioRecordPopover(editor: editor, dismiss: { showRecorder = false }) { url, duration in
                editor.insertAudioAttachment(from: url, duration: duration)
                showRecorder = false
            }
        }
    }

    private func pickPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { editor.insertImage(from: url) }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { editor.insertFileAttachment(from: url) }
    }
}

private struct PageLinkPicker: View {
    @Query private var allPages: [Page]
    @ObservedObject var editor: EditorController
    var currentPage: Page?
    let dismiss: () -> Void
    @State private var query = ""

    private var candidates: [Page] {
        allPages.filter { !$0.isTrashed && $0 !== currentPage }
            .filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search pages", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
            Divider()
            if candidates.isEmpty {
                Text("No pages found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(candidates.prefix(30)) { candidate in
                            Button {
                                editor.insertPageLink(to: candidate)
                                dismiss()
                            } label: {
                                Text(candidate.displayTitle)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 240)
            }
        }
        .frame(width: 260)
    }
}

/// The record UI itself - just "record, then hand back a file and its
/// duration." Not `private` because it's reused from ContentView for the
/// "Add to Recording" flow, not just the Insert menu's "Record Audio...".
struct AudioRecordPopover: View {
    @ObservedObject var editor: EditorController
    @StateObject private var recorder = AudioRecorder()
    var title: LocalizedStringKey = "Record Audio"
    var confirmLabel: LocalizedStringKey = "Stop and Insert"
    let dismiss: () -> Void
    let onFinish: (URL, TimeInterval) -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            if let error = recorder.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel") { dismiss() }
            } else if recorder.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(pulse ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                    Text(formatted(recorder.elapsed))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Button("Cancel", role: .cancel) {
                        recorder.cancel()
                        dismiss()
                    }
                    Button(confirmLabel) {
                        let duration = recorder.elapsed
                        if let url = recorder.stop() {
                            onFinish(url, duration)
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(title).font(.system(size: 13, weight: .semibold))
                Button {
                    recorder.start()
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                Text("Click to start recording").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 220)
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
        }
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The "Add to Recording" flow: same record UI as inserting a brand new
/// recording, but on stop it hands the new audio to
/// `EditorController.appendToAudioAttachment`, which combines it with the
/// existing file via an offline export - so this shows a brief "combining"
/// state instead of dismissing immediately the way a fresh insert does.
struct AppendRecordingSheet: View {
    @ObservedObject var editor: EditorController
    let audioID: UUID
    let dismiss: () -> Void
    @State private var isProcessing = false

    var body: some View {
        if isProcessing {
            VStack(spacing: 14) {
                ProgressView()
                Text("Combining audio\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 220)
        } else {
            AudioRecordPopover(editor: editor, title: "Add to Recording", confirmLabel: "Stop and Add",
                               dismiss: dismiss) { url, _ in
                isProcessing = true
                Task {
                    await editor.appendToAudioAttachment(id: audioID, newAudioURL: url)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Share menu

struct ShareMenu: View {
    @ObservedObject var editor: EditorController
    var page: Page?
    // NSSharingServicePicker isn't retained by the system once `show`
    // returns, so it has to be held somewhere for the duration it's on
    // screen - @State survives across this view's redraws, an instance
    // property on a plain struct wouldn't.
    @State private var sharingPicker: NSSharingServicePicker?

    var body: some View {
        Menu {
            Button("Share...") { presentShareSheet() }
            Divider()
            Button("Find in Page...") { editor.showFindBar() }
            Divider()
            Button("Export as PDF...") { exportPDF() }
            Button("Export as RTF...") { exportRTF() }
            Divider()
            Button("Copy Page Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(editor.textView?.string ?? "", forType: .string)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("Export or share this page")
    }

    /// The system share sheet (AirDrop, Mail, Messages, and any installed
    /// share extensions) - exports the page to a throwaway temp PDF and
    /// hands that off, the same way "Export as PDF..." does except the
    /// destination is chosen by the share picker instead of a save panel.
    private func presentShareSheet() {
        guard let anchor = NSApp.keyWindow?.contentView else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(page?.displayTitle ?? "Page")
            .appendingPathExtension("pdf")
        editor.exportPDF(to: tempURL)
        let picker = NSSharingServicePicker(items: [tempURL])
        sharingPicker = picker
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .maxY)
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (page?.displayTitle ?? "Page") + ".pdf"
        if panel.runModal() == .OK, let url = panel.url { editor.exportPDF(to: url) }
    }

    private func exportRTF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = (page?.displayTitle ?? "Page") + ".rtf"
        guard panel.runModal() == .OK, let url = panel.url, let data = editor.currentRTF() else { return }
        do {
            try data.write(to: url)
        } catch {
            editor.errorMessage = "Couldn't save the RTF file."
        }
    }
}
