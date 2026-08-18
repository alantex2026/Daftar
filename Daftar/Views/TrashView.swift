//  TrashView.swift
//  Everything moved to the Trash: restore it, or delete it for good.
//  Deleting a Notebook/Section/Page only sets `deletedAt` (see the model files) -
//  this is the one place that turns that into a real `context.delete`.

import SwiftUI
import SwiftData

struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var notebooks: [Notebook]
    @Query private var sections: [NoteSection]
    @Query private var pages: [Page]

    @State private var pendingDelete: Row?
    @State private var confirmEmptyAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                List(rows) { row in
                    rowView(row)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 460, height: 420)
        .confirmationDialog(
            pendingDelete.map { "Delete \u{201C}\($0.name)\u{201D} Permanently?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let row = pendingDelete { deletePermanently(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Empty the Trash?",
            isPresented: $confirmEmptyAll,
            titleVisibility: .visible
        ) {
            Button("Empty Trash (\(rows.count))", role: .destructive) {
                rows.forEach(deletePermanently)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash will be deleted permanently. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Trash").font(.system(size: 18, weight: .semibold))
            Spacer()
            Button("Empty Trash") { confirmEmptyAll = true }
                .disabled(rows.isEmpty)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Trash Is Empty").font(.system(size: 14, weight: .medium))
            Text("Deleted notebooks, sections, and pages stay here until you empty the trash.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            icon(for: row.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text("Deleted \(row.deletedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { restore(row) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                pendingDelete = row
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete Permanently")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func icon(for kind: Row.Kind) -> some View {
        switch kind {
        case .notebook(let n): NotebookIcon(colorName: n.colorName)
        case .section(let s): SectionIcon(colorName: s.colorName, isGroup: s.isGroup)
        case .page:
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    // MARK: Rows: every notebook/section/page whose OWN deletedAt is set
    // (i.e. the thing the user actually chose to delete, not a descendant
    // swept along because its container is trashed).

    struct Row: Identifiable {
        enum Kind { case notebook(Notebook), section(NoteSection), page(Page) }
        let id: PersistentIdentifier
        let kind: Kind
        let name: String
        let deletedAt: Date
    }

    private var rows: [Row] {
        let nb = notebooks.compactMap { notebook -> Row? in
            guard let deletedAt = notebook.deletedAt else { return nil }
            return Row(id: notebook.persistentModelID, kind: .notebook(notebook), name: notebook.name, deletedAt: deletedAt)
        }
        let sec = sections.compactMap { section -> Row? in
            guard let deletedAt = section.deletedAt else { return nil }
            return Row(id: section.persistentModelID, kind: .section(section), name: section.name, deletedAt: deletedAt)
        }
        let pg = pages.compactMap { page -> Row? in
            guard let deletedAt = page.deletedAt else { return nil }
            return Row(id: page.persistentModelID, kind: .page(page), name: page.displayTitle, deletedAt: deletedAt)
        }
        return (nb + sec + pg).sorted { $0.deletedAt > $1.deletedAt }
    }

    // MARK: Actions

    /// Restoring also restores any trashed ancestor, so the item is
    /// actually reachable again instead of quietly staying hidden.
    private func restore(_ row: Row) {
        switch row.kind {
        case .notebook(let n):
            n.deletedAt = nil
        case .section(let s):
            s.deletedAt = nil
            restoreAncestors(of: s)
        case .page(let p):
            p.deletedAt = nil
            restoreAncestors(of: p)
        }
    }

    private func restoreAncestors(of section: NoteSection) {
        if let parent = section.parent {
            parent.deletedAt = nil
            restoreAncestors(of: parent)
        }
        section.notebook?.deletedAt = nil
    }

    private func restoreAncestors(of page: Page) {
        if let parent = page.parent {
            parent.deletedAt = nil
            restoreAncestors(of: parent)
        }
        if let section = page.section {
            section.deletedAt = nil
            restoreAncestors(of: section)
        }
    }

    private func deletePermanently(_ row: Row) {
        switch row.kind {
        case .notebook(let n): context.delete(n)
        case .section(let s): context.delete(s)
        case .page(let p): context.delete(p)
        }
    }
}
