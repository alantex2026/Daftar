import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryToolsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var locks: SectionLockStore
    @EnvironmentObject private var sync: FolderSync
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var restoring = false

    var body: some View {
        Menu {
            Button("Back Up Entire Library…") { authorize { backup() } }
            Button(restoring ? "Restoring…" : "Restore Library Backup…") { restore() }.disabled(restoring)
            Divider()
            if sync.enabled {
                // Asks for Touch ID at most once per launch, and never
                // unlocks locked sections on screen.
                Button("Sync Now") { sync.authorizeAndSync() }.disabled(sync.busy)
                Text(sync.status)
                if let last = sync.lastSync { Text("Last sync: \(last.formatted())") }
                Button("Turn Off Folder Sync") { sync.disable() }
            } else {
                Button("Set Up Folder Sync…") { chooseSyncFolder() }
            }
            Button("Show Recovery Backups") {
                do {
                    try FileManager.default.createDirectory(at: sync.recoveryDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(sync.recoveryDirectory)
                } catch { errorMessage = error.localizedDescription }
            }
        } label: {
            Image(systemName: sync.enabled && sync.needsAttention ? "externaldrive.badge.exclamationmark" : "externaldrive")
                .symbolRenderingMode(.multicolor)
        }
        .help(sync.enabled && sync.needsAttention ? sync.status : "Library backup, restore, and device sync")
        .accessibilityLabel(Text("Library Backup and Sync"))
        .alert("Library", isPresented: Binding(get: { errorMessage != nil || notice != nil }, set: { if !$0 { errorMessage = nil; notice = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? notice ?? "") }
    }

    private func authorize(_ action: @escaping () -> Void) {
        do {
            let sections = try context.fetch(FetchDescriptor<NoteSection>())
            locks.requestUnlock(sections: sections, reason: "back up or sync your library") { allowed in if allowed { action() } }
        } catch { errorMessage = error.localizedDescription }
    }
    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Daftar-\(Date().formatted(.iso8601.year().month().day())).daftarbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Capturing reads the models (main thread); packing and writing don't.
            let backup = try LibraryBackup.capture(context: context, locks: locks, includeHistory: false)
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try backup.write(to: url) }.value
                    notice = "Your library was backed up, including Trash. Page history isn't included."
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func restore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "daftarbackup") { panel.allowedContentTypes = [type] }
        panel.message = "Restore adds notebooks without replacing existing notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoring = true
        Task {
            defer { restoring = false }
            do {
                let backup = try await LibraryBackup.load(from: url)
                let notebooks = try backup.restore(context: context)
                notice = "Restored \(notebooks.count) notebook(s). Existing notes were kept."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func chooseSyncFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Choose the same private iCloud Drive or other synced folder on each Mac. Notes and attachments will be stored there unencrypted. Concurrent edits are kept as conflict copies."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try sync.chooseFolder(url); sync.authorizeAndSync() }
        catch { errorMessage = error.localizedDescription }
    }
}
