//  QuickOpenView.swift
//  File > Go to Page… (Cmd O): type part of a page's title to jump to it
//  from anywhere in the library. With no query it lists recent pages.

import SwiftUI
import SwiftData

/// Ranks pages for a Quick Open query.
enum QuickOpenRanking {
    /// Higher is better; nil when the page doesn't match at all. Title
    /// matches beat notebook/section matches; a title that starts with the
    /// query beats one with a word that starts with it, which beats any
    /// other occurrence, which beats the query's letters merely appearing
    /// in order ("mtg" finds "Meeting").
    static func score(title: String, path: String, query: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return 0 }
        if let range = SearchText.range(of: query, in: title) {
            if range.lowerBound == title.startIndex { return 400 }
            let before = title[title.index(before: range.lowerBound)]
            return before.isWhitespace || before.isPunctuation ? 300 : 200
        }
        if isSubsequence(query, of: title) { return 100 }
        if SearchText.matches(path, query) { return 50 }
        return nil
    }

    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        let needle = Array(SearchText.fold(query).lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return false }
        var index = 0
        for character in SearchText.fold(text).lowercased().folding(options: .diacriticInsensitive, locale: nil) where character == needle[index] {
            index += 1
            if index == needle.count { return true }
        }
        return false
    }
}

struct QuickOpenAction {
    let perform: () -> Void
}

struct FocusedQuickOpenKey: FocusedValueKey {
    typealias Value = QuickOpenAction
}

extension FocusedValues {
    var quickOpenAction: QuickOpenAction? {
        get { self[FocusedQuickOpenKey.self] }
        set { self[FocusedQuickOpenKey.self] = newValue }
    }
}

struct QuickOpenView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sectionLock: SectionLockStore
    let onOpen: (Page) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var pages: [Page] = []
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private struct Result: Identifiable {
        let page: Page
        let path: String
        var id: PersistentIdentifier { page.persistentModelID }
    }

    private var results: [Result] {
        let candidates = pages.map { Result(page: $0, path: Self.path(of: $0)) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(candidates.prefix(12)) }
        return candidates
            .compactMap { result in
                QuickOpenRanking.score(title: result.page.displayTitle, path: result.path, query: query).map { (result, $0) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.page.updatedAt > $1.0.page.updatedAt }
            .prefix(50)
            .map(\.0)
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to page", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($fieldFocused)
                    .onSubmit { open(results) }
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                Text(pages.isEmpty ? "No pages yet" : "No matching pages")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("RECENT")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 8)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture { selection = index; open(results) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, index in proxy.scrollTo(index) }
                }
            }
        }
        .frame(width: 520)
        .onExitCommand(perform: dismiss)  // Escape
        .onAppear {
            load()
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ result: Result, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.page.kind.symbol)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.page.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(result.path)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? AppTheme.controlAccent : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Notebook › Section › Parent page"
    private static func path(of page: Page) -> String {
        var parts: [String] = []
        var parent = page.parent
        while let current = parent { parts.insert(current.displayTitle, at: 0); parent = current.parent }
        var section = page.section
        while let current = section { parts.insert(current.name, at: 0); section = current.parent }
        if let notebook = page.section?.notebook { parts.insert(notebook.name, at: 0) }
        return parts.joined(separator: " \u{203A} ")
    }

    private func load() {
        var descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.deletedAt == nil },
                                               sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.title, \.updatedAt, \.pageKindRaw]
        let live = (try? context.fetch(descriptor)) ?? []
        // Locked sections stay hidden, the same as in search.
        pages = live.filter { !$0.isTrashed && sectionLock.canShow($0) }
    }

    private func move(_ delta: Int, in results: [Result]) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    private func open(_ results: [Result]) {
        guard results.indices.contains(selection) else { return }
        onOpen(results[selection].page)
        dismiss()
    }
}
