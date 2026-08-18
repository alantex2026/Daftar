//  SidebarView.swift
//  Column 1: RECENTS at the top, then the NOTEBOOKS tree.
//
//  The tree is flattened into one simple list with a `depth` number,
//  because a view that contains itself forever is hard for SwiftUI.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var sectionLock: SectionLockStore
    @Query(sort: \Notebook.sortIndex) private var notebooks: [Notebook]
    @Query(sort: \Page.lastOpenedAt, order: .reverse) private var allPages: [Page]
    @Query private var allSections: [NoteSection]

    @Binding var selectedSection: NoteSection?
    @Binding var selectedPage: Page?
    @Binding var openTabs: [NoteSection]

    @State private var showRecents = true
    @State private var showPinned = true
    @State private var renamingID: PersistentIdentifier?
    @State private var draftName = ""
    @State private var showTrash = false
    @State private var draggedNotebook: Notebook?
    @State private var draggedSection: NoteSection?
    @State private var ioError: String?

    private var recents: [Page] {
        PerfLog.measure("SidebarView.recents (allPages.count=\(allPages.count))") {
            allPages.filter { !$0.isTrashed && $0.lastOpenedAt > Date.distantPast && sectionLock.canShow($0) }
                .prefix(6).map { $0 }
        }
    }

    private var pinned: [Page] {
        allPages.filter { !$0.isTrashed && $0.isPinned && sectionLock.canShow($0) }
            .sorted { $0.pinnedAt! > $1.pinnedAt! }
    }

    private var trashedCount: Int {
        notebooks.filter { $0.deletedAt != nil }.count
        + allSections.filter { $0.deletedAt != nil }.count
        + allPages.filter { $0.deletedAt != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinned.isEmpty {
                        pinnedHeader
                        if showPinned {
                            ForEach(pinned) { page in recentRow(page, icon: "pin.fill") }
                            Color.clear.frame(height: 14)
                            Divider().opacity(0.25)
                        }
                    }
                    recentsHeader
                    if showRecents {
                        ForEach(recents) { page in recentRow(page) }
                        Color.clear.frame(height: 14)
                        Divider().opacity(0.25)
                    }
                    notebooksHeader
                    ForEach(treeItems) { item in treeRow(item) }
                    Color.clear.frame(height: 20)
                }
                .padding(.bottom, 8)
            }
            Divider().opacity(0.25)
            footer
        }
        .background(AppTheme.sidebar)
        .alert("Something Went Wrong",
               isPresented: Binding(get: { ioError != nil }, set: { if !$0 { ioError = nil } })) {
            Button("OK") {}
        } message: {
            Text(ioError ?? "")
        }
    }

    // MARK: Headers

    private var pinnedHeader: some View {
        HStack {
            Text("PINNED")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.sidebarLabel)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPinned.toggle() }
            } label: {
                Image(systemName: AppTheme.disclosureIcon(isOpen: showPinned, layoutDirection: layoutDirection))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.sidebarLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var recentsHeader: some View {
        HStack {
            Text("RECENTS")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.sidebarLabel)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showRecents.toggle() }
            } label: {
                Image(systemName: AppTheme.disclosureIcon(isOpen: showRecents, layoutDirection: layoutDirection))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.sidebarLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var notebooksHeader: some View {
        HStack {
            Text("NOTEBOOKS")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.sidebarLabel)
            Spacer()
            Menu {
                Button("New Notebook") { addNotebook() }
                Divider()
                Button("Import Markdown Folder\u{2026}") { importMarkdownFolder() }
                Divider()
                Button("Expand All") { setAllExpanded(true) }
                Button("Collapse All") { setAllExpanded(false) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.sidebarLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: Rows

    private func recentRow(_ page: Page, icon: String = "doc.text") -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.sidebarLabel)
            Text(page.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.sidebarText)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(selectedPage === page ? AppTheme.sidebarRowOn : Color.clear)
        .animation(.easeInOut(duration: 0.15), value: selectedPage)
        .contentShape(Rectangle())
        .onTapGesture { open(page) }
        .contextMenu {
            Button(page.isPinned ? "Unpin" : "Pin") { page.togglePinned() }
        }
    }

    @ViewBuilder
    private func treeRow(_ item: TreeItem) -> some View {
        switch item.kind {
        case .notebook(let notebook):
            HStack(spacing: 7) {
                chevron(isOpen: notebook.isExpanded) { notebook.isExpanded.toggle() }
                NotebookIcon(colorName: notebook.colorName)
                nameOrField(id: notebook.persistentModelID,
                            text: notebook.name,
                            weight: .semibold) { notebook.name = $0 }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onSingleAndDoubleTap(single: { notebook.isExpanded.toggle() }, double: {
                startRename(notebook.persistentModelID, notebook.name)
            })
            .contextMenu { notebookMenu(notebook) }
            .onDrag {
                draggedNotebook = notebook
                return NSItemProvider(item: NSString(string: notebook.name), typeIdentifier: UTType.daftarNotebook.identifier)
            }
            .onDrop(of: [UTType.daftarNotebook], isTargeted: nil) { _ in
                guard let dragged = draggedNotebook else { return false }
                reorderNotebooks(dragged: dragged, target: notebook)
                draggedNotebook = nil
                return true
            }

        case .section(let section):
            HStack(spacing: 7) {
                if section.isGroup {
                    chevron(isOpen: section.isExpanded) { section.isExpanded.toggle() }
                } else {
                    Color.clear.frame(width: 12)
                }
                SectionIcon(colorName: section.colorName, isGroup: section.isGroup)
                nameOrField(id: section.persistentModelID,
                            text: section.name,
                            weight: .regular) { section.name = $0 }
                Spacer()
                if section.isLocked && !sectionLock.isUnlocked(section) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.sidebarLabel)
                }
                Text("\(section.totalPageCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.sidebarLabel)
            }
            .padding(.leading, 12 + CGFloat(item.depth - 1) * 15)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(selectedSection === section ? AppTheme.sidebarRowOn : Color.clear)
            .contentShape(Rectangle())
            .onSingleAndDoubleTap(single: {
                if section.isGroup { section.isExpanded.toggle() }
                else { selectSection(section) }
            }, double: {
                startRename(section.persistentModelID, section.name)
            })
            .contextMenu { sectionMenu(section) }
            .onDrag {
                draggedSection = section
                return NSItemProvider(item: NSString(string: section.name), typeIdentifier: UTType.daftarSection.identifier)
            }
            .onDrop(of: [UTType.daftarSection], isTargeted: nil) { _ in
                guard let dragged = draggedSection else { return false }
                reorderSections(dragged: dragged, target: section)
                draggedSection = nil
                return true
            }
        }
    }

    private func chevron(isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: AppTheme.disclosureIcon(isOpen: isOpen, layoutDirection: layoutDirection))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.sidebarLabel)
                .frame(width: 12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nameOrField(id: PersistentIdentifier,
                             text: String,
                             weight: Font.Weight,
                             commit: @escaping (String) -> Void) -> some View {
        if renamingID == id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .onSubmit { commit(draftName); renamingID = nil }
        } else {
            Text(text)
                .font(.system(size: 14, weight: weight))
                .foregroundStyle(AppTheme.sidebarText)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
            Text("Last Sync: \(Date().formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12))
            Spacer()
            Button { showTrash = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 12))
                    if trashedCount > 0 { Text("\(trashedCount)").font(.system(size: 12)) }
                }
            }
            .buttonStyle(.plain)
            .help("Trash")
        }
        .foregroundStyle(AppTheme.sidebarLabel)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .sheet(isPresented: $showTrash) { TrashView() }
    }

    // MARK: Flattening the tree

    struct TreeItem: Identifiable {
        enum Kind { case notebook(Notebook), section(NoteSection) }
        let id: PersistentIdentifier
        let kind: Kind
        let depth: Int
    }

    private var treeItems: [TreeItem] {
        PerfLog.measure("SidebarView.treeItems") {
            var result: [TreeItem] = []
            for notebook in notebooks where !notebook.isTrashed {
                result.append(TreeItem(id: notebook.persistentModelID, kind: .notebook(notebook), depth: 0))
                if notebook.isExpanded { append(notebook.topLevelSections, depth: 1, into: &result) }
            }
            return result
        }
    }

    private func append(_ sections: [NoteSection], depth: Int, into result: inout [TreeItem]) {
        for section in sections {
            result.append(TreeItem(id: section.persistentModelID, kind: .section(section), depth: depth))
            if section.isGroup && section.isExpanded {
                append(section.sortedChildren, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func notebookMenu(_ notebook: Notebook) -> some View {
        Button("New Section") { addSection(to: notebook, isGroup: false) }
        Button("New Section Group") { addSection(to: notebook, isGroup: true) }
        Divider()
        Button("Rename") { startRename(notebook.persistentModelID, notebook.name) }
        Menu("Color") {
            ForEach(PaletteColor.allCases) { c in
                Button(c.title) { notebook.colorName = c.rawValue }
            }
        }
        Divider()
        Button("Export Notebook\u{2026}") { exportNotebook(notebook) }
        Divider()
        Button("Delete Notebook", role: .destructive) {
            openTabs.removeAll { $0.notebook === notebook }
            if selectedSection?.notebook === notebook { selectedSection = nil; selectedPage = nil }
            notebook.deletedAt = Date()
        }
    }

    @ViewBuilder
    private func sectionMenu(_ section: NoteSection) -> some View {
        if section.isGroup {
            Button("New Section Inside") { addSection(inside: section) }
        } else {
            Button("Open in New Tab") {
                sectionLock.requestUnlock(section, reason: "unlock \u{201C}\(section.name)\u{201D}") { success in
                    guard success else { return }
                    if !openTabs.contains(where: { $0 === section }) { openTabs.append(section) }
                    selectedSection = section
                }
            }
        }
        Divider()
        Button("Rename") { startRename(section.persistentModelID, section.name) }
        if section.isLocked {
            Button("Lock Now") {
                sectionLock.lockNow(section)
                if selectedSection === section { selectedSection = nil; selectedPage = nil }
            }
            Button("Turn Off Touch ID Lock") {
                sectionLock.requestUnlock(section, reason: "turn off the lock on \u{201C}\(section.name)\u{201D}") { success in
                    if success { section.isLocked = false }
                }
            }
        } else {
            Button("Require Touch ID / Password") { section.isLocked = true }
        }
        Menu("Color") {
            ForEach(PaletteColor.allCases) { c in
                Button(c.title) { section.colorName = c.rawValue }
            }
        }
        Menu("Move to Notebook") {
            ForEach(notebooks.filter { !$0.isTrashed }) { target in
                Button(target.name) {
                    section.parent = nil
                    section.notebook = target
                    section.sortIndex = target.nextSectionIndex
                }
            }
        }
        Divider()
        Button("Delete Section", role: .destructive) {
            openTabs.removeAll { isDescendant($0, of: section) }
            if let selectedSection, isDescendant(selectedSection, of: section) {
                self.selectedSection = nil
                selectedPage = nil
            }
            section.deletedAt = Date()
        }
    }

    /// True if `candidate` is `section` itself or nested somewhere underneath it
    /// (a section inside a Section Group that is being deleted).
    private func isDescendant(_ candidate: NoteSection, of section: NoteSection) -> Bool {
        var current: NoteSection? = candidate
        while let c = current {
            if c === section { return true }
            current = c.parent
        }
        return false
    }

    // MARK: Actions

    /// Selects `section`, prompting Touch ID / the Mac password first if
    /// it's locked and hasn't been unlocked yet this session.
    private func selectSection(_ section: NoteSection) {
        sectionLock.requestUnlock(section, reason: "unlock \u{201C}\(section.name)\u{201D}") { success in
            if success { selectedSection = section }
        }
    }

    private func open(_ page: Page) {
        if let owner = page.section {
            if !openTabs.contains(where: { $0 === owner }) { openTabs.append(owner) }
            selectedSection = owner
        }
        selectedPage = page
    }

    private func startRename(_ id: PersistentIdentifier, _ current: String) {
        draftName = current
        renamingID = id
    }

    private func exportNotebook(_ notebook: Notebook) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to export \u{201C}\(notebook.name)\u{201D} as a folder of Markdown files."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try NotebookMarkdownIO.export(notebook, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            ioError = "Couldn't export \u{201C}\(notebook.name)\u{201D}. \(error.localizedDescription)"
        }
    }

    private func importMarkdownFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Import"
        panel.message = "Choose a folder of Markdown files to import as a new notebook."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let notebook = try NotebookMarkdownIO.importFolder(source, context: context)
            selectedSection = notebook.topLevelSections.first
        } catch {
            ioError = "Couldn't import \u{201C}\(source.lastPathComponent)\u{201D}. \(error.localizedDescription)"
        }
    }

    private func addNotebook() {
        let notebook = Notebook(name: "New Notebook",
                                colorName: PaletteColor.allCases.randomElement()!.rawValue,
                                sortIndex: (notebooks.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(notebook)
        let section = NoteSection(name: "New Section", sortIndex: 0)
        section.notebook = notebook
        context.insert(section)
        selectedSection = section
    }

    private func addSection(to notebook: Notebook, isGroup: Bool) {
        let section = NoteSection(name: isGroup ? "New Section Group" : "New Section",
                                  colorName: PaletteColor.allCases.randomElement()!.rawValue,
                                  sortIndex: notebook.nextSectionIndex,
                                  isGroup: isGroup)
        section.notebook = notebook
        context.insert(section)
        notebook.isExpanded = true
        if !isGroup { selectedSection = section }
    }

    private func addSection(inside group: NoteSection) {
        let section = NoteSection(name: "New Section",
                                  colorName: PaletteColor.allCases.randomElement()!.rawValue,
                                  sortIndex: (group.children.map(\.sortIndex).max() ?? -1) + 1)
        section.notebook = group.notebook
        section.parent = group
        context.insert(section)
        group.isExpanded = true
        selectedSection = section
    }

    private func setAllExpanded(_ open: Bool) {
        for notebook in notebooks {
            notebook.isExpanded = open
            for section in notebook.sections { section.isExpanded = open }
        }
    }

    /// Reorders `dragged` to sit where `target` currently is among the
    /// top-level notebooks. Trashed notebooks are excluded from the
    /// reordered list rather than reassigned, so they keep their old
    /// position if they're ever restored.
    private func reorderNotebooks(dragged: Notebook, target: Notebook) {
        guard dragged !== target else { return }
        var ordered = notebooks.filter { !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }
        ordered.removeAll { $0 === dragged }
        guard let targetIndex = ordered.firstIndex(where: { $0 === target }) else { return }
        ordered.insert(dragged, at: targetIndex)
        for (index, notebook) in ordered.enumerated() { notebook.sortIndex = index }
    }

    /// Reorders `dragged` to sit where `target` currently is, among their
    /// shared siblings (same notebook, same parent group). Does nothing if
    /// they aren't siblings - dragging only reorders, it doesn't move a
    /// section to a different notebook or group.
    private func reorderSections(dragged: NoteSection, target: NoteSection) {
        guard dragged !== target,
              dragged.notebook === target.notebook,
              dragged.parent === target.parent else { return }
        let siblings = target.parent?.sortedChildren ?? target.notebook?.topLevelSections ?? []
        var ordered = siblings
        ordered.removeAll { $0 === dragged }
        guard let targetIndex = ordered.firstIndex(where: { $0 === target }) else { return }
        ordered.insert(dragged, at: targetIndex)
        for (index, section) in ordered.enumerated() { section.sortIndex = index }
    }
}
