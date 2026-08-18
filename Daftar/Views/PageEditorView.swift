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
                        .transition(.opacity)
                } else if let page {
                    PaperView(page: page, editor: editor)
                        // A new id tells SwiftUI: different document, rebuild the editor.
                        .id(page.persistentModelID)
                        .transition(.opacity)
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
                    .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: 0))
            .padding(.leading, 4)
        }
        // Fires on any change of which page is open - wherever selectedPage
        // was set from - not just clicks made directly in this view.
        .animation(.easeInOut(duration: 0.16), value: page?.persistentModelID)
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

struct PaperView: View {
    @Bindable var page: Page
    @ObservedObject var editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            // Title with the thin rule underneath it.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TextField("Untitled", text: $page.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 34, weight: .regular, design: .rounded))
                        .foregroundStyle(AppTheme.paperText)
                        .onChange(of: page.title) { _, _ in page.updatedAt = Date() }
                    if page.tag != .none { TagBadge(tag: page.tag, size: 22) }
                }
                Rectangle()
                    .fill(AppTheme.paperText.opacity(0.25))
                    .frame(height: 1)
            }
            .padding(.horizontal, 52)
            .padding(.top, 30)
            .padding(.bottom, 8)

            RichTextEditor(initialData: page.contentData, controller: editor) { data, plain, linkIDs in
                page.contentData = data
                page.plainText = plain
                page.outgoingLinkIDs = linkIDs
                page.updatedAt = Date()
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
    @Query private var allPages: [Page]
    let page: Page
    @ObservedObject var editor: EditorController
    @EnvironmentObject private var sectionLock: SectionLockStore

    private var backlinks: [Page] {
        allPages.filter {
            !$0.isTrashed && $0 !== page && $0.outgoingLinkIDs.contains(page.linkID) && sectionLock.canShow($0)
        }
    }

    var body: some View {
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

struct StatusBar: View {
    @ObservedObject var editor: EditorController

    var body: some View {
        HStack(spacing: 16) {
            saveStateLabel

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

            Text("\(editor.wordCount) word(s)")
                .font(.system(size: 12))

            Button { editor.toggleSpellCheck() } label: {
                HStack(spacing: 3) {
                    Image(systemName: editor.spellCheckOn ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(editor.spellCheckOn ? Color.green : Color.secondary)
                    Text("Abc").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .help("Turn spell checking on or off")

            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Full screen")
        }
        .foregroundStyle(AppTheme.paperText.opacity(0.6))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(AppTheme.paper)
    }

    @ViewBuilder
    private var saveStateLabel: some View {
        switch editor.saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Saving\u{2026}").font(.system(size: 12))
            }
        case .saved:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("Saved").font(.system(size: 12))
            }
        }
    }
}
