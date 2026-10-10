//  SidebarView.swift
//  Column 1: pinned pages and the notebook tree.
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
    @EnvironmentObject private var folderSync: FolderSync
    @EnvironmentObject private var undoToast: UndoToast
    @Query(sort: \Notebook.sortIndex) private var notebooks: [Notebook]
    // Narrow queries: the sidebar is always on screen and every query here
    // re-runs on every autosave, so never fetch the whole page table.
    @Query(filter: #Predicate<Page> { $0.pinnedAt != nil }, sort: \Page.pinnedAt, order: .reverse)
    private var pinnedPages: [Page]
    @Query(filter: #Predicate<Page> { $0.deletedAt != nil }) private var trashedPages: [Page]
    @Query(filter: #Predicate<NoteSection> { $0.deletedAt != nil }) private var trashedSections: [NoteSection]

    @Binding var selectedSection: NoteSection?
    @Binding var selectedPage: Page?
    @Binding var openTabs: [NoteSection]

    @State private var showPinned = true
    @State private var renamingID: PersistentIdentifier?
    @State private var showTrash = false
    @State private var draggedNotebook: Notebook?
    @State private var draggedSection: NoteSection?
    /// The section a dragged page is hovering over, for its highlight.
    @State private var pageDropSectionID: PersistentIdentifier?
    @State private var ioError: String?

    private var pinned: [Page] {
        pinnedPages.filter { !$0.isTrashed && sectionLock.canShow($0) }
    }

    private var trashedCount: Int {
        notebooks.filter { $0.deletedAt != nil }.count
        + trashedSections.count
        + trashedPages.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinned.isEmpty {
                        pinnedHeader
                        if showPinned {
                            ForEach(pinned) { page in pinnedRow(page) }
                            Color.clear.frame(height: 14)
                            Divider().opacity(0.25)
                        }
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
        .sidebarBackground()
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
            .accessibilityLabel(Text(showPinned ? "Collapse Pinned" : "Expand Pinned"))
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
            .help("New notebook and import")
            .accessibilityLabel(Text("Add Notebook"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: Rows

    private func pinnedRow(_ page: Page) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "pin.fill")
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
        .selectionBackground(selectedPage === page, color: AppTheme.sidebarRowOn)
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
                Text("\(item.pageCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.sidebarLabel)
            }
            .padding(.leading, 12 + CGFloat(item.depth - 1) * 15)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .selectionBackground(selectedSection === section, color: AppTheme.sidebarRowOn)
            .contentShape(Rectangle())
            .onSingleAndDoubleTap(single: {
                if section.isGroup { section.isExpanded.toggle() }
                else { selectSection(section) }
            }, double: {
                startRename(section.persistentModelID, section.name)
            })
            .contextMenu { sectionMenu(section) }
            .overlay {
                if pageDropSectionID == section.persistentModelID {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppTheme.controlAccent, lineWidth: 2)
                        .padding(.horizontal, 6)
                }
            }
            .onDrag {
                draggedSection = section
                return NSItemProvider(item: NSString(string: section.name), typeIdentifier: UTType.daftarSection.identifier)
            }
            // Sections reorder among themselves; a page dropped here moves into this section.
            .onDrop(of: [UTType.daftarSection, UTType.daftarPage], isTargeted: Binding(
                get: { pageDropSectionID == section.persistentModelID },
                set: { targeted in
                    if targeted, PageDrag.current != nil, !section.isGroup { pageDropSectionID = section.persistentModelID }
                    else if !targeted, pageDropSectionID == section.persistentModelID { pageDropSectionID = nil }
                })) { providers in
                if let page = PageDrag.page(from: providers) {
                    PageDrag.current = nil
                    guard !section.isGroup else { return false }
                    movePage(page, to: section)
                    return true
                }
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
        .accessibilityLabel(Text(isOpen ? "Collapse" : "Expand"))
    }

    @ViewBuilder
    private func nameOrField(id: PersistentIdentifier,
                             text: String,
                             weight: Font.Weight,
                             commit: @escaping (String) -> Void) -> some View {
        if renamingID == id {
            RenameField("Name", original: text, onCommit: commit) {
                if renamingID == id { renamingID = nil }
            }
        } else {
            Text(text)
                .font(.system(size: 14, weight: weight))
                .foregroundStyle(AppTheme.sidebarText)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if folderSync.enabled {
                Image(systemName: folderSync.needsAttention ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                Group {
                    if folderSync.busy || folderSync.needsAttention {
                        Text(folderSync.status)
                    } else if let lastSync = folderSync.lastSync {
                        Text("Last Sync: \(lastSync.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text(folderSync.status)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .help(folderSync.status)
            }
            Spacer()
            Button { showTrash = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 12))
                    if trashedCount > 0 { Text("\(trashedCount)").font(.system(size: 12)) }
                }
            }
            .buttonStyle(.plain)
            .help("Trash")
            .accessibilityLabel(Text("Trash"))
            .accessibilityValue(Text(trashedCount == 0 ? "Empty" : "\(trashedCount) items"))
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
        /// Live pages in a section, sub-sections included; 0 for notebooks.
        var pageCount = 0
    }

    private var treeItems: [TreeItem] {
        PerfLog.measure("SidebarView.treeItems") {
            var result: [TreeItem] = []
            for notebook in notebooks where !notebook.isTrashed {
                result.append(TreeItem(id: notebook.persistentModelID, kind: .notebook(notebook), depth: 0))
                guard notebook.isExpanded else { continue }
                // Counted once per section here, instead of each row (and
                // each enclosing group again) recounting on every redraw.
                var counts: [ObjectIdentifier: Int] = [:]
                for section in notebook.topLevelSections { _ = Self.countPages(in: section, into: &counts) }
                append(notebook.topLevelSections, depth: 1, counts: counts, into: &result)
            }
            return result
        }
    }

    /// Live pages in `section` and everything inside it, recording each
    /// section's total along the way.
    static func countPages(in section: NoteSection, into counts: inout [ObjectIdentifier: Int]) -> Int {
        let own = section.pages.reduce(0) { $0 + ($1.isTrashed ? 0 : 1) }
        let total = section.sortedChildren.reduce(own) { $0 + countPages(in: $1, into: &counts) }
        counts[ObjectIdentifier(section)] = total
        return total
    }

    private func append(_ sections: [NoteSection], depth: Int, counts: [ObjectIdentifier: Int], into result: inout [TreeItem]) {
        for section in sections {
            result.append(TreeItem(id: section.persistentModelID, kind: .section(section), depth: depth,
                                   pageCount: counts[ObjectIdentifier(section)] ?? 0))
            if section.isGroup && section.isExpanded {
                append(section.sortedChildren, depth: depth + 1, counts: counts, into: &result)
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
            LibraryActions.trash(notebook)
            undoToast.trashed(notebook.name) { LibraryActions.restore(notebook) }
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
            Button("Require Touch ID / Password") {
                sectionLock.lockNow(section)
                section.isLocked = true
            }
        }
        Menu("Color") {
            ForEach(PaletteColor.allCases) { c in
                Button(c.title) { section.colorName = c.rawValue }
            }
        }
        Menu("Move to Notebook") {
            ForEach(notebooks.filter { !$0.isTrashed }) { target in
                Button(target.name) {
                    sectionLock.requestUnlock(section, reason: "move this section") { success in
                        guard success else { return }
                        section.move(to: target)
                        do { try context.save() }
                        catch { ioError = "Couldn't save the move. \(error.localizedDescription)" }
                    }
                }
            }
        }
        Divider()
        Button("Delete Section", role: .destructive) {
            openTabs.removeAll { $0.isWithin(section) }
            if let selectedSection, selectedSection.isWithin(section) {
                self.selectedSection = nil
                selectedPage = nil
            }
            LibraryActions.trash(section)
            undoToast.trashed(section.name) { LibraryActions.restore(section) }
        }
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
        renamingID = id
    }

    private func exportNotebook(_ notebook: Notebook) {
        sectionLock.requestUnlock(sections: notebook.sections.filter { !$0.isTrashed },
                                  reason: "export this notebook") { success in
            guard success else { return }
            performExport(notebook)
        }
    }

    private func performExport(_ notebook: Notebook) {
        guard SaveCoordinator.flushAll() else {
            ioError = "Save your pending changes before exporting. Please retry."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to export \u{201C}\(notebook.name)\u{201D} as a folder of Markdown files."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard SaveCoordinator.flushAll() else {
                ioError = "Save your pending changes before exporting. Please retry."
                return
            }
            let folder = try NotebookMarkdownIO.export(notebook, to: destination, locks: sectionLock)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
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
        selectedSection = LibraryActions.addNotebook(after: notebooks, context: context).section
    }

    private func addSection(to notebook: Notebook, isGroup: Bool) {
        let section = LibraryActions.addSection(to: notebook, isGroup: isGroup, context: context)
        if !isGroup { selectedSection = section }
    }

    private func addSection(inside group: NoteSection) {
        selectedSection = LibraryActions.addSection(inside: group, context: context)
    }

    private func setAllExpanded(_ open: Bool) {
        for notebook in notebooks {
            notebook.isExpanded = open
            for section in notebook.sections { section.isExpanded = open }
        }
    }

    private func reorderNotebooks(dragged: Notebook, target: Notebook) {
        LibraryActions.reorderNotebooks(notebooks, moving: dragged, to: target)
    }

    /// A locked destination asks to be unlocked first, so a page can't be
    /// dropped somewhere its owner can't then see it.
    private func movePage(_ page: Page, to section: NoteSection) {
        guard page.section !== section || page.parent != nil else { return }
        sectionLock.requestUnlock(section, reason: "move this page to \u{201C}\(section.name)\u{201D}") { success in
            guard success else { return }
            LibraryActions.move(page, to: section)
        }
    }

    private func reorderSections(dragged: NoteSection, target: NoteSection) {
        LibraryActions.reorderSections(moving: dragged, to: target)
    }
}
