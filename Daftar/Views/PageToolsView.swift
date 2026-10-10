import SwiftUI
import SwiftData

struct PageToolsView: View {
    @Bindable var page: Page
    @State private var showHistory = false

    var body: some View {
        Button { if SaveCoordinator.flushAll() { showHistory = true } } label: { Image(systemName: "clock.arrow.circlepath") }
            .help("Page version history")
            .accessibilityLabel(Text("Version History"))
            .sheet(isPresented: $showHistory) { PageHistoryView(page: page) }
    }
}

/// Adds and removes a page's custom tags. Opened from the toolbar's tag menu.
struct CustomTagsEditor: View {
    @Bindable var page: Page
    @Environment(\.modelContext) private var context
    @State private var draftTag = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Tags").font(.headline)
            ForEach(page.customTags, id: \.self) { tag in
                HStack {
                    Text(tag)
                    Spacer()
                    Button { updateTags(page.customTags.filter { $0 != tag }) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(tag)"))
                }
            }
            HStack {
                TextField("New tag", text: $draftTag).onSubmit(addTag)
                Button("Add", action: addTag).disabled(draftTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 270)
    }
    private func addTag() {
        let tag = draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !page.customTags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) else { return }
        updateTags(page.customTags + [tag]); draftTag = ""
    }
    private func updateTags(_ tags: [String]) {
        do { try PageHistory.capture(page); page.customTags = tags; page.updatedAt = Date(); try context.save() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct PageHistoryView: View {
    let page: Page
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [PageRevision] = []
    @State private var selected: UUID?
    @State private var errorMessage: String?
    @State private var confirmRestore = false
    private var revision: PageRevision? { revisions.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Version History").font(.title2)
                Spacer()
                Button("Save Snapshot") {
                    do { try PageHistory.capture(page, force: true); try context.save(); load() }
                    catch { errorMessage = error.localizedDescription }
                }
                Button("Done") { dismiss() }
            }
            Text("Up to 50 snapshots are retained. Restore keeps the current version in history.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(revisions, selection: $selected) { item in
                    VStack(alignment: .leading) {
                        Text(item.capturedAt, style: .date)
                        Text(item.capturedAt, style: .time).font(.caption)
                        Text(item.title).lineLimit(1)
                    }.tag(item.id)
                }.frame(minWidth: 190)
                ScrollView {
                    if let revision {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(revision.title).font(.headline)
                            Text(revision.plainText.isEmpty ? "Empty page or attachments only" : revision.plainText)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding()
                    } else { Text("Select a snapshot to preview it.").padding() }
                }.frame(minWidth: 340)
            }
            HStack {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Restore Selected Version") { confirmRestore = true }.disabled(revision == nil)
            }
        }.padding(20).frame(width: 720, height: 490)
        .task { load() }
        .confirmationDialog("Restore this version? Your current version will remain in history.", isPresented: $confirmRestore) {
            Button("Restore") {
                guard let revision, SaveCoordinator.flushAll() else { return }
                do { try PageHistory.restore(revision, to: page, context: context); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
    private func load() {
        do { revisions = try PageHistory.revisions(page); selected = revisions.first?.id }
        catch { errorMessage = error.localizedDescription }
    }
}
