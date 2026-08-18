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
    @Query private var allPages: [Page]
    @Query private var allNotebooks: [Notebook]

    var section: NoteSection?
    @Binding var selectedPage: Page?
    @Binding var searchText: String

    @State private var renamingID: PersistentIdentifier?
    @State private var draftName = ""
    @State private var draggedPage: Page?

    // Search: filtering runs against `debouncedQuery` instead of `searchText`
    // directly, so a fast typist isn't re-filtering every page on every
    // keystroke - only once typing pauses.
    @State private var debouncedQuery = ""
    @State private var filterNotebook: Notebook?
    @State private var filterTag: PageTag?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if searchText.isEmpty {
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
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
    }

    /// The pages in on-screen top-to-bottom order, whichever list is
    /// currently showing - the outline, or search results.
    private var navigablePages: [Page] {
        searchText.isEmpty ? rows.map(\.page) : hits
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
            .keyboardShortcut("n", modifiers: .command)
            .help("Create a blank page in this section")

            Menu {
                ForEach(PageTemplate.allCases.filter { $0 != .blank }) { template in
                    Button {
                        addPage(under: nil, template: template)
                    } label: {
                        Label(template.rawValue, systemImage: template.systemImage)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.sidebarText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 14)
            .help("New page from template")
        }
        .disabled(section == nil || section?.isGroup == true || section.map { !sectionLock.isUnlocked($0) } == true)
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
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)

            HStack(spacing: 8) {
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
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedPage === page ? AppTheme.pageCardOn : AppTheme.pageCard)
            )
            .animation(.easeInOut(duration: 0.15), value: selectedPage)
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
                draggedPage = page
                return NSItemProvider(item: NSString(string: page.title), typeIdentifier: UTType.daftarPage.identifier)
            }
            .onDrop(of: [UTType.daftarPage], isTargeted: nil) { _ in
                guard let dragged = draggedPage else { return false }
                reorderPages(dragged: dragged, target: page)
                draggedPage = nil
                return true
            }
        }
        .padding(.trailing, 0)
    }

    // MARK: Search results

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

            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.sidebarLabel)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var hits: [Page] {
        guard !debouncedQuery.isEmpty else { return [] }
        return allPages.filter { page in
            guard !page.isTrashed, sectionLock.canShow(page) else { return false }
            if let filterNotebook, page.section?.notebook !== filterNotebook { return false }
            if let filterTag, page.tag != filterTag { return false }
            return page.title.localizedCaseInsensitiveContains(debouncedQuery)
                || page.plainText.localizedCaseInsensitiveContains(debouncedQuery)
        }
    }

    private var searchList: some View {
        ScrollView {
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
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedPage === page ? AppTheme.pageCardOn : AppTheme.pageCard)
                    )
                    .animation(.easeInOut(duration: 0.15), value: selectedPage)
                    .padding(.leading, 18)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPage = page; isFocused = true }
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
        guard !debouncedQuery.isEmpty,
              let range = text.range(of: debouncedQuery, options: .caseInsensitive) else { return nil }
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
            if searchText.isEmpty {
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
        Button("Delete Page", role: .destructive) {
            if let selectedPage, isDescendant(selectedPage, of: page) { self.selectedPage = nil }
            page.deletedAt = Date()
        }
    }

    /// True if `candidate` is `page` itself or nested somewhere underneath it.
    private func isDescendant(_ candidate: Page, of page: Page) -> Bool {
        var current: Page? = candidate
        while let c = current {
            if c === page { return true }
            current = c.parent
        }
        return false
    }

    private func addPage(under parent: Page?, template: PageTemplate = .blank) {
        guard let section, !section.isGroup else { return }
        let page: Page
        if let parent {
            page = Page(title: "Untitled", sortIndex: parent.nextChildIndex)
            page.parent = parent
            parent.isExpanded = true
        } else {
            page = Page(title: "Untitled", sortIndex: section.nextRootPageIndex)
        }
        page.section = section
        if let title = template.pageTitle { page.title = title }
        page.contentData = template.contentData
        page.plainText = template.plainText
        context.insert(page)
        selectedPage = page
    }

    private func duplicate(_ page: Page) {
        guard let section else { return }
        let copy = duplicatePage(page, title: page.title + " copy",
                                 sortIndex: section.nextRootPageIndex, parent: page.parent)
        selectedPage = copy
    }

    /// Copies a page and, recursively, all of its sub-pages.
    @discardableResult
    private func duplicatePage(_ page: Page, title: String, sortIndex: Int, parent: Page?) -> Page {
        let copy = Page(title: title, sortIndex: sortIndex)
        copy.contentData = page.contentData
        copy.plainText = page.plainText
        copy.tagRaw = page.tagRaw
        copy.section = section
        copy.parent = parent
        context.insert(copy)
        for child in page.sortedChildren {
            duplicatePage(child, title: child.title, sortIndex: copy.nextChildIndex, parent: copy)
        }
        return copy
    }

    private func moveOut(_ page: Page) {
        page.parent = page.parent?.parent
    }

    /// Reorders `dragged` to sit where `target` currently is, among their
    /// shared siblings. Does nothing if they aren't siblings (same parent
    /// page, same section) - dragging only reorders, it doesn't reparent.
    private func reorderPages(dragged: Page, target: Page) {
        guard dragged !== target,
              dragged.parent === target.parent,
              dragged.section === target.section else { return }
        var siblings = target.parent?.sortedChildren ?? (section?.rootPages ?? [])
        siblings.removeAll { $0 === dragged }
        guard let targetIndex = siblings.firstIndex(where: { $0 === target }) else { return }
        siblings.insert(dragged, at: targetIndex)
        for (index, page) in siblings.enumerated() { page.sortIndex = index }
    }
}
