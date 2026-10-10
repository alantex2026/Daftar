//  PageOutlineView.swift
//  Column 2: the pages of the current section, shown as an outline.
//  Pages can hold sub-pages, so this is a tree too - flattened again.
//  If the search box has text, this column shows search results instead.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PageOutlineView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.layoutDirection) private var layoutDirection
    @EnvironmentObject private var sectionLock: SectionLockStore
    @EnvironmentObject private var undoToast: UndoToast
    @Query private var allNotebooks: [Notebook]
    /// Pages searched while search is active. Not an @Query: this view is always
    /// visible, and a query over every page would refetch on each autosave.
    @State private var searchPool: [Page] = []

    var section: NoteSection?
    @Binding var selectedPage: Page?
    @Binding var searchText: String

    @State private var renamingID: PersistentIdentifier?
    @State private var draftName = ""
    @State private var dropTarget: (page: Page, zone: PageDropZone)?

    // Search: filtering runs against `debouncedQuery` instead of `searchText`
    // directly, so a fast typist isn't re-filtering every page on every
    // keystroke - only once typing pauses.
    @State private var debouncedQuery = ""
    @State private var filterNotebook: Notebook?
    @State private var filterTag: PageTag?
    @State private var customTag: String?
    @State private var savedSearches = SavedSearchStore.load()
    @State private var searchName = ""
    @State private var showSaveSearch = false
    @State private var searchError: String?
    @State private var showSearchResults = false
    private var searching: Bool { showSearchResults || !searchText.isEmpty || filterTag != nil || filterNotebook != nil || customTag != nil }

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            savedSearchBar
            if !searching {
                if let section, !sectionLock.isUnlocked(section) {
                    lockedPlaceholder(section)
                } else {
                    outlineList
                }
            } else {
                searchFilterBar
                searchList
            }
            Divider().opacity(0.2)
            footer
        }
        .background(AppTheme.outlineBack)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand(perform: moveSelection)
        .onReceive(NotificationCenter.default.publisher(for: .daftarSavedSearchesChanged)) { _ in
            savedSearches = SavedSearchStore.load()
        }
        .task(id: searching) { reloadSearchPool() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            if searching { reloadSearchPool() }
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
    }

    /// The pages in on-screen top-to-bottom order, whichever list is
    /// currently showing - the outline, or search results.
    private var navigablePages: [Page] {
        !searching ? rows.map(\.page) : hits
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let pages = navigablePages
        guard !pages.isEmpty else { return }
        let currentIndex = selectedPage.flatMap { page in pages.firstIndex { $0 === page } }
        switch direction {
        case .up:
            selectedPage = pages[currentIndex.map { max($0 - 1, 0) } ?? 0]
        case .down:
            selectedPage = pages[currentIndex.map { min($0 + 1, pages.count - 1) } ?? 0]
        default:
            break
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                addPage(under: nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    Text("New page").font(.system(size: 16, weight: .medium))
                }
                .foregroundStyle(AppTheme.sidebarText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Create a blank page in this section (Cmd N)")

            Menu {
                ForEach(PageTemplate.allCases.filter { $0 != .blank }) { template in
                    Button {
                        addPage(under: nil, template: template)
                    } label: {
                        Label(template.rawValue, systemImage: template.systemImage)
                    }
                }
                Divider()
                ForEach([PageKind.document, .spreadsheet]) { kind in
                    Button {
                        addPage(under: nil, kind: kind)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.sidebarText)
            }
            .menuStyle(.borderlessButton)
            // The label already is the chevron; without this macOS adds a second one.
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 14)
            .help("New page from template")
            .accessibilityLabel(Text("New Page from Template"))
        }
        .disabled(!canAddPage)
        // File > New Page (Cmd N) acts on this window's current section.
        .focusedSceneValue(\.newPageAction, canAddPage ? NewPageAction { addPage(under: nil) } : nil)
    }

    private var canAddPage: Bool {
        guard let section else { return false }
        return !section.isGroup && sectionLock.isUnlocked(section)
    }

    private func lockedPlaceholder(_ section: NoteSection) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundStyle(AppTheme.sidebarLabel.opacity(0.6))
            Text("Locked")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.sidebarLabel)
            Button("Unlock") {
                sectionLock.requestUnlock(section, reason: "unlock \u{201C}\(section.name)\u{201D}") { _ in }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The outline

    private var outlineList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    pageRow(row.page, depth: row.depth)
                }
                Color.clear.frame(height: 12)
            }
            .padding(.top, 2)
        }
    }

    private func pageRow(_ page: Page, depth: Int) -> some View {
        HStack(spacing: 0) {
            // The gutter on the far left holds the open/close triangle.
            Group {
                if page.hasChildren {
                    Button {
                        page.isExpanded.toggle()
                    } label: {
                        Image(systemName: AppTheme.disclosureIcon(isOpen: page.isExpanded, layoutDirection: layoutDirection))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.sidebarLabel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(page.isExpanded ? "Collapse Sub-pages" : "Expand Sub-pages"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)

            HStack(spacing: 8) {
                if page.kind != .richText {
                    Image(systemName: page.kind.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.pageCardText.opacity(0.55))
                        .help(page.kind.title)
                }
                if renamingID == page.persistentModelID {
                    TextField("Title", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.pageCardText)
                        .onSubmit { page.title = draftName; renamingID = nil }
                } else {
                    Text(page.displayTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.pageCardText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if page.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.sidebarLabel)
                }
                if page.tag != .none { TagBadge(tag: page.tag, size: 16) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedPage === page ? AppTheme.pageCardOn : AppTheme.pageCard)
            )
            .overlay { dropIndicator(for: page) }
            .padding(.leading, CGFloat(depth) * 20)
            .contentShape(Rectangle())
            .onSingleAndDoubleTap(single: { selectedPage = page; isFocused = true }, double: {
                selectedPage = page
                isFocused = true
                draftName = page.title
                renamingID = page.persistentModelID
            })
            .contextMenu { pageMenu(page) }
            .onDrag {
                PageDrag.current = page
                return NSItemProvider(item: NSString(string: page.linkID.uuidString), typeIdentifier: UTType.daftarPage.identifier)
            }
            .onDrop(of: [UTType.daftarPage], delegate: PageRowDropDelegate(target: page, indicator: $dropTarget) { dragged, zone in
                dropPage(dragged, on: page, zone: zone)
            })
        }
        .padding(.trailing, 0)
    }

    /// A line above or below the card, or an outline around it, showing
    /// where a dragged page will land.
    @ViewBuilder
    private func dropIndicator(for page: Page) -> some View {
        if let target = dropTarget, target.page === page {
            switch target.zone {
            case .before:
                VStack { AppTheme.controlAccent.frame(height: 2); Spacer() }.offset(y: -2)
            case .after:
                VStack { Spacer(); AppTheme.controlAccent.frame(height: 2) }.offset(y: 2)
            case .inside:
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppTheme.controlAccent, lineWidth: 2)
            }
        }
    }

    private func dropPage(_ dragged: Page, on target: Page, zone: PageDropZone) -> Bool {
        switch zone {
        case .before: return LibraryActions.place(dragged, beside: target)
        case .after: return LibraryActions.place(dragged, beside: target, after: true)
        case .inside: return LibraryActions.nest(dragged, under: target)
        }
    }

    // MARK: Search results

    private var savedSearchBar: some View {
        HStack {
            Menu("Saved Searches") {
                Button("All Pages") { showSearchResults = true; searchText = ""; filterTag = nil; customTag = nil; filterNotebook = nil }
                ForEach(savedSearches) { saved in
                    Button(saved.name) {
                        showSearchResults = true
                        searchText = saved.query
                        debouncedQuery = saved.query
                        filterNotebook = allNotebooks.first { $0.stableID == saved.notebookID }
                        filterTag = saved.tagRaw.flatMap(PageTag.init(rawValue:))
                        customTag = saved.customTag
                    }
                }
                if !savedSearches.isEmpty {
                    Menu("Delete Saved Search") {
                        ForEach(savedSearches) { saved in
                            Button(saved.name) {
                                savedSearches.removeAll { $0.id == saved.id }
                                persistSearches()
                            }
                        }
                    }
                }
            }.menuStyle(.borderlessButton)
            Spacer()
            Button { searchName = searchText; showSaveSearch = true } label: { Image(systemName: "bookmark") }
                .help("Save current search and filters")
                .accessibilityLabel(Text("Save Search"))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .alert("Save Search", isPresented: $showSaveSearch) {
            TextField("Name", text: $searchName)
            Button("Save") {
                let name = searchName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                savedSearches.append(SavedSearch(name: name, query: searchText, notebookID: filterNotebook?.stableID,
                    tagRaw: filterTag?.rawValue, customTag: customTag))
                persistSearches()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Save Search", isPresented: Binding(get: { searchError != nil }, set: { if !$0 { searchError = nil } })) {
            Button("OK") {}
        } message: { Text(searchError ?? "") }
    }

    private func persistSearches() {
        do { try SavedSearchStore.save(savedSearches) }
        catch { searchError = error.localizedDescription }
    }

    private var searchFilterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All Notebooks") { filterNotebook = nil }
                Divider()
                ForEach(allNotebooks.filter { !$0.isTrashed }) { notebook in
                    Button(notebook.name) { filterNotebook = notebook }
                }
            } label: {
                if let filterNotebook {
                    Text(filterNotebook.name)   // user-entered name: verbatim, not a catalog lookup
                } else {
                    Text("All Notebooks")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("All Tags") { filterTag = nil }
                Divider()
                ForEach(PageTag.allCases.filter { $0 != .none }) { tag in
                    Button(tag.title) { filterTag = tag }
                }
            } label: {
                Text(filterTag?.title ?? "All Tags")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu(customTag ?? "Custom Tag") {
                Button("Any Custom Tag") { customTag = nil }
                ForEach(Array(Set(searchPool.filter { sectionLock.canShow($0) }.flatMap(\.customTags))).sorted(), id: \.self) { tag in
                    Button(tag) { customTag = tag }
                }
            }.menuStyle(.borderlessButton)
            Button { showSearchResults = false; searchText = ""; filterNotebook = nil; filterTag = nil; customTag = nil } label: {
                Image(systemName: "xmark.circle")
            }.buttonStyle(.plain).help("Clear search filters").accessibilityLabel(Text("Clear Search Filters"))
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.sidebarLabel)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func reloadSearchPool() {
        searchPool = searching
            ? (try? context.fetch(FetchDescriptor<Page>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
            : []
    }

    private var hits: [Page] {
        return searchPool.filter { page in
            guard !page.isTrashed, sectionLock.canShow(page) else { return false }
            if let filterNotebook, page.section?.notebook !== filterNotebook { return false }
            if let filterTag, page.tag != filterTag { return false }
            if let customTag, !page.customTags.contains(customTag) { return false }
            return debouncedQuery.isEmpty || SearchText.matches(page.title, debouncedQuery)
                || SearchText.matches(page.plainText, debouncedQuery)
                || page.customTags.contains { SearchText.matches($0, debouncedQuery) }
        }
    }

    private var searchList: some View {
        let hits = self.hits  // Filter once per render, not once per use.
        return ScrollView {
            LazyVStack(spacing: 2) {
                if hits.isEmpty {
                    Text("No pages found")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.sidebarLabel)
                        .padding(.top, 30)
                }
                ForEach(hits) { page in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.displayTitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppTheme.pageCardText)
                        Text(searchResultSubtitle(for: page))
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.pageCardText.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedPage === page ? AppTheme.pageCardOn : AppTheme.pageCard)
                    )
                    .padding(.leading, 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        SearchHighlight.request(debouncedQuery, for: page.linkID)
                        selectedPage = page
                        isFocused = true
                    }
                }
                Color.clear.frame(height: 12)
            }
            .padding(.top, 2)
        }
    }

    /// "Section name — …a short excerpt around the match…"
    private func searchResultSubtitle(for page: Page) -> String {
        let sectionName = page.section?.name ?? ""
        guard let snippet = snippet(for: page) else { return sectionName }
        return sectionName.isEmpty ? snippet : "\(sectionName) — \(snippet)"
    }

    private func snippet(for page: Page) -> String? {
        let text = page.plainText
        guard let range = SearchText.range(of: debouncedQuery, in: text) else { return nil }
        let radius = 40
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var result = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        if start != text.startIndex { result = "…" + result }
        if end != text.endIndex { result += "…" }
        return result
    }

    private var footer: some View {
        Group {
            if !searching {
                let count = section?.pages.filter { !$0.isTrashed }.count ?? 0
                Text(count == 1 ? "1 page" : "\(count) pages")
            } else {
                Text(hits.isEmpty ? "No results" : (hits.count == 1 ? "1 result" : "\(hits.count) results"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.sidebarLabel)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Flatten the page tree

    struct Row: Identifiable {
        let id: PersistentIdentifier
        let page: Page
        let depth: Int
    }

    private var rows: [Row] {
        PerfLog.measure("PageOutlineView.rows") {
            guard let section, !section.isGroup else { return [] }
            var result: [Row] = []
            append(section.rootPages, depth: 0, into: &result)
            return result
        }
    }

    private func append(_ pages: [Page], depth: Int, into result: inout [Row]) {
        for page in pages {
            result.append(Row(id: page.persistentModelID, page: page, depth: depth))
            if page.isExpanded && page.hasChildren {
                append(page.sortedChildren, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: Menu + actions

    @ViewBuilder
    private func pageMenu(_ page: Page) -> some View {
        Menu("New Sub-page") {
            Button("Blank Page") { addPage(under: page) }
            Divider()
            ForEach(PageTemplate.allCases.filter { $0 != .blank }) { template in
                Button(template.rawValue) { addPage(under: page, template: template) }
            }
        }
        Button("Rename") { draftName = page.title; renamingID = page.persistentModelID }
        Button("Duplicate") { duplicate(page) }
        Button(page.isPinned ? "Unpin" : "Pin") { page.togglePinned() }
        Menu("Tag") {
            ForEach(PageTag.allCases) { tag in
                Button(tag.title) { page.tag = tag }
            }
        }
        Divider()
        if page.parent != nil {
            Button("Move Out One Level") { moveOut(page) }
        }
        Menu("Move to") {
            ForEach(allNotebooks.filter { !$0.isTrashed }.sorted { $0.sortIndex < $1.sortIndex }) { notebook in
                Section(notebook.name) {
                    ForEach(pageSections(in: notebook), id: \.section.persistentModelID) { entry in
                        Button(entry.title) { movePage(page, to: entry.section) }
                            .disabled(entry.section === page.section && page.parent == nil)
                    }
                }
            }
        }
        Button("Delete Page", role: .destructive) {
            if let selectedPage, selectedPage.isWithin(page) { self.selectedPage = nil }
            LibraryActions.trash(page)
            undoToast.trashed(page.displayTitle) {
                LibraryActions.restore(page)
                selectedPage = page
            }
        }
    }

    private func addPage(under parent: Page?, template: PageTemplate = .blank, kind: PageKind = .richText) {
        guard let section,
              let page = LibraryActions.addPage(to: section, under: parent, template: template, kind: kind, context: context) else { return }
        selectedPage = page
    }

    private func duplicate(_ page: Page) {
        selectedPage = LibraryActions.duplicate(page, context: context)
    }

    private func moveOut(_ page: Page) {
        LibraryActions.moveOut(page)
    }

    private func movePage(_ page: Page, to section: NoteSection) {
        sectionLock.requestUnlock(section, reason: "move this page to \u{201C}\(section.name)\u{201D}") { success in
            if success { LibraryActions.move(page, to: section) }
        }
    }

    /// Every section a page can live in (not groups, not trashed), with its
    /// path inside the notebook, for the "Move to" menu.
    private func pageSections(in notebook: Notebook) -> [(section: NoteSection, title: String)] {
        var result: [(NoteSection, String)] = []
        func add(_ sections: [NoteSection], prefix: String) {
            for section in sections {
                if section.isGroup { add(section.sortedChildren, prefix: prefix + section.name + " \u{203A} ") }
                else { result.append((section, prefix + section.name)) }
            }
        }
        add(notebook.topLevelSections, prefix: "")
        return result
    }
}

/// Where a page dropped on another page lands.
enum PageDropZone: Equatable {
    case before, inside, after

    /// Top and bottom edges place the page beside the row; the middle nests it.
    static func zone(atY y: CGFloat, rowHeight: CGFloat) -> PageDropZone {
        let edge = min(12, rowHeight / 3)
        if y < edge { return .before }
        if y > rowHeight - edge { return .after }
        return .inside
    }
}

private struct PageRowDropDelegate: DropDelegate {
    let target: Page
    @Binding var indicator: (page: Page, zone: PageDropZone)?
    let perform: (Page, PageDropZone) -> Bool
    /// The page cards are one line tall: 10pt padding around a 15pt title.
    private let rowHeight: CGFloat = 39

    private func zone(_ info: DropInfo) -> PageDropZone {
        PageDropZone.zone(atY: info.location.y, rowHeight: rowHeight)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let page = PageDrag.current else { return false }
        return page !== target && !target.isWithin(page)  // never into itself
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicator = (target, zone(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if indicator?.page === target { indicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { indicator = nil; PageDrag.current = nil }
        guard let page = PageDrag.current else { return false }
        return perform(page, zone(info))
    }
}
