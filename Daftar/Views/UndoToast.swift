//  UndoToast.swift
//  "Moved “Groceries” to Trash · Undo" - a short-lived notice at the bottom
//  of the window after a delete, so a misclick costs one click to fix
//  instead of a trip to the Trash.

import SwiftUI

@MainActor
final class UndoToast: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    @Published private(set) var notice: Notice?
    private var hideTask: Task<Void, Never>?
    /// Long enough to notice and react; short enough not to linger.
    static let duration: Duration = .seconds(6)

    func show(_ message: String, undo: @escaping () -> Void) {
        let notice = Notice(message: message, undo: undo)
        self.notice = notice
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled, self?.notice?.id == notice.id else { return }
            self?.notice = nil
        }
    }

    func performUndo() {
        guard let notice else { return }
        self.notice = nil
        hideTask?.cancel()
        notice.undo()
    }

    func dismiss() {
        notice = nil
        hideTask?.cancel()
    }

    /// Trash `name` and offer to put it back.
    func trashed(_ name: String, restore: @escaping () -> Void) {
        show(String(localized: "Moved \u{201C}\(name)\u{201D} to Trash"), undo: restore)
    }
}

struct UndoToastView: View {
    @ObservedObject var toast: UndoToast

    var body: some View {
        if let notice = toast.notice {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text(notice.message)
                    .lineLimit(1)
                Button("Undo") { toast.performUndo() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                Button { toast.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Dismiss"))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
            .accessibilityElement(children: .contain)
        }
    }
}
