import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Validate once per mounted page, before creating any editable AppKit views.
struct ValidatedPageEditor: View {
    let page: Page
    @ObservedObject var editor: EditorController
    @Environment(\.modelContext) private var context
    @State private var validated = false
    @State private var editorGeneration = UUID()
    @State private var loadError: String?
    @State private var confirmReset = false
    @State private var recoveryError: String?

    var body: some View {
        Group {
            if let loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.doc").font(.largeTitle)
                    Text("This page couldn't be opened").font(.headline)
                    Text("Your original data is preserved. Save a copy before replacing this page.")
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    Button("Save Original Data…") { saveOriginal(reset: false) }
                    Button("Try Again") { validate() }
                    Button("Save Original and Reset…", role: .destructive) { confirmReset = true }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.paper)
            } else if validated {
                Group {
                    switch page.kind {
                    case .richText: PaperView(page: page, editor: editor)
                    case .document: DocumentPaperView(page: page, editor: editor)
                    case .spreadsheet: SpreadsheetPaperView(page: page)
                    }
                }
                .id(editorGeneration)
                .focusedSceneValue(\.notebookEditor, page.kind == .spreadsheet ? nil : editor)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { validate() }
        .onReceive(NotificationCenter.default.publisher(for: .daftarReloadEditors)) { note in
            // `object` is the set of changed page IDs (sync), or nil for "all".
            guard page.modelContext != nil, !page.isDeleted else { return }
            if let changed = note.object as? Set<UUID>, !changed.contains(page.linkID) { return }
            editorGeneration = UUID()
            validate()
        }
        .confirmationDialog("Replace this page with a blank page after saving its original data?",
                            isPresented: $confirmReset) {
            Button("Save Original and Reset…", role: .destructive) { saveOriginal(reset: true) }
        }
        .alert("Recovery Failed", isPresented: Binding(get: { recoveryError != nil },
                                                       set: { if !$0 { recoveryError = nil } })) {
            Button("OK") {}
        } message: { Text(recoveryError ?? "") }
    }

    private func validate() {
        do {
            try PageContentCodec.validate(page)
            loadError = nil
            validated = true
        } catch {
            loadError = error.localizedDescription
            validated = false
            editor.textView = nil
        }
    }

    private func saveOriginal(reset: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "Recovered Page.data"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if reset {
                try PageContentCodec.backUpAndReset(page, to: url, context: context)
                validate()
            } else {
                let data = page.kind == .spreadsheet ? page.spreadsheetData : page.contentData
                try (data ?? Data()).write(to: url, options: .atomic)
            }
        } catch { recoveryError = error.localizedDescription }
    }
}
