//  PageEditorView.swift
//  The white "paper" on the right: title, underline, text, status bar.

import SwiftUI
import SwiftData

struct PageEditorView: View {
    var page: Page?
    @ObservedObject var editor: EditorController
    @EnvironmentObject private var sectionLock: SectionLockStore

    var body: some View {
        ZStack {
            AppTheme.tabStrip
            VStack(spacing: 0) {
                if let page, let section = page.section, !sectionLock.isUnlocked(section) {
                    LockedPageView(section: section)
                        .id(page.persistentModelID)
                } else if let page {
                    ValidatedPageEditor(page: page, editor: editor)
                    // A new id tells SwiftUI: different document, rebuild the editor.
                    .id(page.persistentModelID)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 34))
                            .foregroundStyle(AppTheme.paperText.opacity(0.25))
                        Text("No page selected")
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.paperText.opacity(0.45))
                        Text("Pick a section from the sidebar, then choose or create a page.")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.paperText.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.paper)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: 0))
            .padding(.leading, 4)
        }
        // Fires on any change of which page is open - wherever selectedPage
        // was set from - not just clicks made directly in this view.
        // No crossfade between pages: it delayed every switch by 160 ms and
        // kept the previous page's editor alive while fading it out.
    }
}

/// Shown instead of a page's real content while its section is locked and
/// hasn't been unlocked yet this session.
struct LockedPageView: View {
    let section: NoteSection
    @EnvironmentObject private var sectionLock: SectionLockStore
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(AppTheme.paperText.opacity(0.3))
            Text("\u{201C}\(section.name)\u{201D} Is Locked")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.paperText.opacity(0.6))
            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
            if didFail {
                Text("Couldn't verify who you are.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.paper)
    }

    private func unlock() {
        sectionLock.requestUnlock(section, reason: "unlock \u{201C}\(section.name)\u{201D}") { success in
            didFail = !success
        }
    }
}

/// The title field + thin underline rule shared by every page editor -
/// only the body underneath differs (rich text, paginated, spreadsheet).
struct PageTitleHeader: View {
    @State private var historyError: String?
    @Bindable var page: Page
    @Environment(\.modelContext) private var context
    @StateObject private var saver = SaveCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Untitled", text: Binding(get: { page.title }, set: { title in
                    do { try PageHistory.capture(page); page.title = title }
                    catch { historyError = error.localizedDescription }
                }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.paperText)
                    .onChange(of: page.title) { _, title in
                        page.updatedAt = Date()
                        let context = context
                        // Debounced like body text: one save per pause, not per keystroke.
                        saver.rescue = { folder in
                            let url = SaveCoordinator.rescueURL(named: title + " (title)", extension: "txt", in: folder)
                            try title.write(to: url, atomically: true, encoding: .utf8)
                            return url
                        }
                        saver.schedule(delay: AppSettings.saveDelay) { try context.save() }
                    }
                    .onDisappear { saver.flush() }
                if let historyError { Text(historyError).font(.caption).foregroundStyle(.red) }
                if saver.state == .failed { SaveStateIndicator(state: .failed) }
                if page.tag != .none { TagBadge(tag: page.tag, size: 22) }
            }
            Rectangle()
                .fill(AppTheme.paperText.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.horizontal, 52)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }
}

struct PaperView: View {
    @Environment(\.modelContext) private var context
    @Bindable var page: Page
    @ObservedObject var editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            PageTitleHeader(page: page)

            RichTextEditor(initialData: page.contentData, controller: editor, pageID: page.linkID) { data, plain, links in
                try page.saveRichText(data, plainText: plain, links: links, in: context)
            }

            BacklinksView(page: page, editor: editor)

            Divider()
            StatusBar(editor: editor)
        }
        .background(AppTheme.paper)
    }
}

/// The editor for a `.document` page - same title header as a regular
/// note, but the body is `PaginatedTextEditor` instead of `RichTextEditor`.
struct DocumentPaperView: View {
    @StateObject private var saver = SaveCoordinator()
    @Environment(\.modelContext) private var context
    @Bindable var page: Page
    @ObservedObject var editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            PageTitleHeader(page: page)

            HStack {
                Picker("Paper size", selection: Binding(get: { page.paperSize }, set: { value in
                    do { try PageHistory.capture(page); page.paperSize = value }
                    catch { editor.errorMessage = error.localizedDescription }
                })) {
                    Text("US Letter").tag("letter")
                    Text("A4").tag("a4")
                    Text("Legal").tag("legal")
                }
                .frame(width: 200)
                .onChange(of: page.paperSize) { _, _ in
                    saver.schedule(delay: 0) { try context.save() }
                    saver.flush()
                }
                Spacer()
            }.padding(.horizontal, 52)

            PaginatedTextEditor(initialData: page.contentData, controller: editor, pageID: page.linkID, paperSize: page.paperSize) { data, plain, links in
                try page.saveRichText(data, plainText: plain, links: links, in: context)
            }

            BacklinksView(page: page, editor: editor)
            Divider()
            StatusBar(editor: editor)
        }
        .background(AppTheme.paper)
    }
}

/// A row of chips for every other page whose text currently links to this
/// one - the reverse of a link, so following a thread of notes works both
/// ways instead of only forward from wherever the link was written.
struct BacklinksView: View {
    @Environment(\.modelContext) private var context
    let page: Page
    // Only used for navigation. Not observed: observing would recompute
    // backlinks across every page on every keystroke (word count changes).
    let editor: EditorController
    @EnvironmentObject private var sectionLock: SectionLockStore
    /// Pages whose saved text links here. Not an @Query: that refetched every
    /// page on each autosave of the page being typed in. SwiftData can't
    /// filter on the `outgoingLinkIDs` array in the store, so this is a
    /// fetch plus an in-memory filter, redone only when another page saves.
    @State private var linkingPages: [Page] = []

    private var backlinks: [Page] {
        linkingPages.filter { !$0.isDeleted && !$0.isTrashed && sectionLock.canShow($0) }
    }

    private func reload() {
        let linkID = page.linkID
        let live = (try? context.fetch(FetchDescriptor<Page>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        linkingPages = live.filter { $0 !== page && $0.outgoingLinkIDs.contains(linkID) }
    }

    /// Whether a save may have changed who links to `page`: any page other
    /// than `page` itself inserted, updated or deleted. Autosaves of the page
    /// being edited (with its payload and history rows) don't qualify.
    static func needsReload(after note: Notification, for page: PersistentIdentifier) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let lists = keys.map { note.userInfo?[$0.rawValue] as? [PersistentIdentifier] }
        guard lists.contains(where: { $0 != nil }) else { return true }  // No details: assume it matters.
        return lists.compactMap { $0 }.joined().contains { $0.entityName == "Page" && $0 != page }
    }

    var body: some View {
        // The zero-height view keeps this on screen (so `onAppear` fires)
        // even while there are no backlinks to show.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            content
        }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
                if Self.needsReload(after: note, for: page.persistentModelID) { reload() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("LINKED MENTIONS (\(backlinks.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.paperText.opacity(0.4))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(backlinks) { linkedPage in
                            Button {
                                editor.onNavigateToLink?(linkedPage.linkID)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text").font(.system(size: 11))
                                    Text(linkedPage.displayTitle).font(.system(size: 12)).lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 12)
        }
    }
}

/// "Saving…" / "Saved" (or nothing yet), the same look wherever a page
/// shows its persistence state - the format-toolbar-backed editors via
/// `StatusBar`, and the spreadsheet's own lighter-weight footer.
struct SaveStateIndicator: View {
    let state: EditorController.SaveState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Saving\u{2026}").font(.system(size: 12))
            }
        case .failed:
            Button("Save failed — Retry") { SaveCoordinator.flushAll() }
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .saved:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.success)
                Text("Saved").font(.system(size: 12))
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var editor: EditorController

    var body: some View {
        HStack(spacing: 16) {
            SaveStateIndicator(state: editor.saveState)

            Spacer()

            HStack(spacing: 3) {
                Text("\(Int(editor.zoom * 100))%")
                    .font(.system(size: 12))
                    .frame(width: 38, alignment: .trailing)
                VStack(spacing: 0) {
                    Button { editor.zoom = min(2.0, editor.zoom + 0.1) } label: {
                        Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                    }
                    Button { editor.zoom = max(0.5, editor.zoom - 0.1) } label: {
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            }
            .help("Zoom")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Zoom"))
            .accessibilityValue(Text("\(Int(editor.zoom * 100))%"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: editor.zoom = min(2.0, editor.zoom + 0.1)
                case .decrement: editor.zoom = max(0.5, editor.zoom - 0.1)
                @unknown default: break
                }
            }

            Text("\(editor.wordCount) word(s)")
                .font(.system(size: 12))

            Button { editor.toggleSpellCheck() } label: {
                HStack(spacing: 3) {
                    Image(systemName: editor.spellCheckOn ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(editor.spellCheckOn ? AppTheme.success : Color.secondary)
                    Text("Abc").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .help("Turn spell checking on or off")
            .accessibilityLabel(Text("Spell Checking"))
            .accessibilityValue(Text(editor.spellCheckOn ? "On" : "Off"))

            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Full screen")
            .accessibilityLabel(Text("Full Screen"))
        }
        .foregroundStyle(AppTheme.paperText.opacity(0.6))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(AppTheme.paper)
    }
}
