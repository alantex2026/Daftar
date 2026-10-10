//  ContentView.swift
//  The whole window: three resizable columns plus the top toolbar.

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    // Deliberately NOT @ObservedObject: EditorController publishes on
    // nearly every keystroke and cursor move (word count, bold/italic
    // state, alignment...), and this view only ever reads `errorMessage`
    // from it. @ObservedObject would re-run this entire body - including
    // rebuilding the whole three-pane split view - on every one of those,
    // which is exactly what made navigation and typing feel laggy. The
    // views that actually display editor state (toolbar, status bar, the
    // editor pane itself) still observe it themselves, further down.
    let editor: EditorController

    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var selectedSection: NoteSection?
    @State private var selectedPage: Page?
    @State private var openTabs: [NoteSection] = []
    @State private var searchText = ""
    let sessionID: String
    @State private var restoredSession = false
    @State private var showOnboarding = false
    @State private var errorMessage: String?
    @State private var appendAudioID: UUID?
    @State private var showQuickOpen = false
    @StateObject private var contextSaver = SaveCoordinator()
    @StateObject private var undoToast = UndoToast()
    @EnvironmentObject private var sectionLock: SectionLockStore
    @EnvironmentObject private var folderSync: FolderSync

    var body: some View {
        SplitContainerView(isSidebarVisible: $showSidebar) {
            SidebarView(selectedSection: sectionSelection,
                        selectedPage: $selectedPage,
                        openTabs: $openTabs)
                .environmentObject(undoToast)
                .themedTint()
        } outline: {
            PageOutlineView(section: selectedSection,
                            selectedPage: $selectedPage,
                            searchText: $searchText)
                .environmentObject(undoToast)
                .themedTint()
        } detail: {
            DetailView(openTabs: $openTabs,
                       selectedSection: sectionSelection,
                       selectedPage: $selectedPage,
                       editor: editor)
                .themedTint()
        }
        // Classic keeps the system toolbar; other themes paint it so the
        // window reads as one surface instead of a grey bar over the panes.
        .toolbarBackground(AppTheme.toolbar ?? .clear, for: .windowToolbar)
        .toolbarBackground(AppTheme.toolbar == nil ? .automatic : .visible, for: .windowToolbar)
        // 640pt = half the width of a 13" MacBook Air, the smallest common
        // half-screen tile - keeping the window's own minimum at or below
        // that is what lets macOS's window snapping actually reach it.
        // Height is unaffected by side-by-side tiling, so it's untouched.
        .frame(minWidth: 640, minHeight: 620)
        .overlay(alignment: .bottom) { UndoToastView(toast: undoToast) }
        .animation(.easeOut(duration: 0.2), value: undoToast.notice?.id)
        .onDisappear {
            contextSaver.flush()
            editor.onNavigateToLink = nil
            editor.onRequestAudioAppend = nil
            editor.textView = nil
        }
        .task {
            let modelContext = context
            contextSaver.saveContext = { try modelContext.save() }
            contextSaver.onError = { [weak controller = editor] in controller?.errorMessage = $0 }
            do {
                try LibraryIdentity.normalize(context: context)
                try PagePayload.migrateLegacyColumns(context: context)
                try PagePayload.migrateHistoryToRevisions(context: context)
                let pageIDs = try context.fetch(FetchDescriptor<Page>()).map(\.linkID)
                SessionStore.pruneCursors(keeping: Set(pageIDs))
            }
            catch { editor.errorMessage = "Couldn't prepare the library. \(error.localizedDescription)"; return }
            folderSync.attach(context: context, locks: sectionLock)
            SampleData.seedIfNeeded(context: context)
            TrashMaintenance.purgeExpired(context: context)
            restoreSession()
            openFirstSectionIfNeeded()
            if !hasSeenOnboarding { showOnboarding = true }
            editor.onNavigateToLink = { linkID in navigateToPage(withLinkID: linkID) }
            editor.onRequestAudioAppend = { id in appendAudioID = id }
        }
        // File > Go to Page… (Cmd O).
        .focusedSceneValue(\.quickOpenAction, QuickOpenAction { showQuickOpen = true })
        .sheet(isPresented: $showQuickOpen) {
            QuickOpenView(onOpen: { navigateToPage(withLinkID: $0.linkID) },
                          dismiss: { showQuickOpen = false })
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { hasSeenOnboarding = true; showOnboarding = false }
        }
        .sheet(isPresented: Binding(get: { appendAudioID != nil }, set: { if !$0 { appendAudioID = nil } })) {
            if let appendAudioID {
                AppendRecordingSheet(editor: editor, audioID: appendAudioID, dismiss: { self.appendAudioID = nil })
            }
        }
        // Lets "Show Onboarding Tour Again" in Settings bring the tour up
        // immediately instead of only on the next launch.
        .onChange(of: hasSeenOnboarding) { _, seen in
            if !seen { showOnboarding = true }
        }
        .onChange(of: openTabs.map(\.stableID)) { _, _ in saveSession() }
        .onChange(of: selectedSection) { _, newSection in
            guard let newSection else { saveSession(); return }
            if !openTabs.contains(where: { $0 === newSection }) { openTabs.append(newSection) }
            if selectedPage?.section !== newSection {
                selectedPage = newSection.rootPages.first
            }
            saveSession()
        }
        .onChange(of: selectedPage) { _, _ in saveSession() }
        // Sync, Trash and auto-purge can delete models this window still
        // references; drop those references before anything reads them.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in pruneDeletedSelection() }
        // A scoped subscription instead of @ObservedObject - this is the
        // one piece of editor state ContentView itself needs to react to.
        .onReceive(editor.$errorMessage) { errorMessage = $0 }
        .alert("Something Went Wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil; editor.errorMessage = nil } })) {
            Button("Retry Saving") { SaveCoordinator.flushAll() }
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem { LibraryToolsView() }
            ToolbarItem(placement: .navigation) {
                Button {
                    // The actual collapse animation happens in
                    // SplitContainerView (AppKit-driven, not SwiftUI) since
                    // the sidebar is a real NSSplitView subview now.
                    showSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Show or hide the sidebar")
                .accessibilityLabel(Text("Toggle Sidebar"))
            }
            // The format/insert/share controls all act through `editor.textView`,
            // which spreadsheet pages never set - showing them there would let
            // people click Bold or Export on a page that can't use either, and
            // (worse) silently edit whatever page last owned the text view.
            if let selectedPage, selectedPage.kind != .spreadsheet, sectionLock.canShow(selectedPage) {
                ToolbarItem { InsertMenu(editor: editor, page: selectedPage) }
                ToolbarItem { StyleFormatGroup(editor: editor) }
                ToolbarItem { FontFormatGroup(editor: editor) }
                ToolbarItem { ParagraphFormatGroup(editor: editor) }
            }
            if let selectedPage, sectionLock.canShow(selectedPage) {
                ToolbarItem { TagBar(editor: editor, page: selectedPage) }
                ToolbarItem { PageToolsView(page: selectedPage) }
            }
            if let selectedPage, selectedPage.kind != .spreadsheet, sectionLock.canShow(selectedPage) {
                ToolbarItem { ShareMenu(editor: editor, page: selectedPage) }
            }
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 140)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear Search"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            }
        }
    }

    /// Resolves a page link's stable ID back to the actual Page and opens
    /// it, the same way clicking a sidebar row does.
    private func navigateToPage(withLinkID linkID: UUID) {
        let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.linkID == linkID })
        guard let target = try? context.fetch(descriptor).first, !target.isTrashed else { return }
        if let owner = target.section {
            if !openTabs.contains(where: { $0 === owner }) { openTabs.append(owner) }
            selectedSection = owner
        }
        selectedPage = target
    }

    private func restoreSession() {
        guard !restoredSession else { return }
        if let saved = SessionStore.load(sessionID),
           let sections = try? context.fetch(FetchDescriptor<NoteSection>()),
           let pages = try? context.fetch(FetchDescriptor<Page>()) {
            openTabs = saved.tabs.compactMap { id in sections.first { $0.stableID == id && !$0.isTrashed } }
            selectedSection = sections.first { $0.stableID == saved.section && !$0.isTrashed }
            selectedPage = pages.first { $0.linkID == saved.page && !$0.isTrashed }
        }
        restoredSession = true
    }

    /// Section selection for the sidebar and tabs. Picks the section's page in
    /// the same update, so the window redraws once with the new section and
    /// its page instead of first showing the old page under the new section.
    private var sectionSelection: Binding<NoteSection?> {
        Binding(get: { selectedSection }, set: { section in
            if let section, selectedPage?.section !== section { selectedPage = section.rootPages.first }
            selectedSection = section
        })
    }

    private func pruneDeletedSelection() {
        func gone(_ model: any PersistentModel) -> Bool { model.isDeleted || model.modelContext == nil }
        if openTabs.contains(where: gone) { openTabs.removeAll(where: gone) }
        if let section = selectedSection, gone(section) { selectedSection = nil }
        if let page = selectedPage, gone(page) { selectedPage = nil }
    }

    private func saveSession() {
        guard restoredSession else { return }
        SessionStore.save(WindowSession(tabs: openTabs.map(\.stableID),
            section: selectedSection?.stableID, page: selectedPage?.linkID), id: sessionID)
    }

    private func openFirstSectionIfNeeded() {
        guard selectedSection == nil else { return }
        let all = (try? context.fetch(FetchDescriptor<NoteSection>())) ?? []
        if let first = all.filter({ !$0.isGroup && !$0.isTrashed }).sorted(by: { $0.sortIndex < $1.sortIndex }).first {
            selectedSection = first
        }
    }
}

// MARK: - Right hand side: tab strip + paper

struct DetailView: View {
    @Binding var openTabs: [NoteSection]
    @Binding var selectedSection: NoteSection?
    @Binding var selectedPage: Page?
    // Same reasoning as ContentView: this view never reads editor's
    // published properties itself, only forwards it to PageEditorView,
    // which does observe it. No need to re-render this wrapper on every
    // keystroke too.
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(openTabs: $openTabs, selectedSection: $selectedSection)
            PageEditorView(page: selectedPage, editor: editor)
        }
        .background(AppTheme.tabStrip)
    }
}
