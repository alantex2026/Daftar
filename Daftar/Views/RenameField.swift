//  RenameField.swift
//  The inline field for renaming a notebook, section or page: Return or
//  clicking away saves, Escape cancels, and an empty name keeps the old one.

import SwiftUI

struct RenameField: View {
    let placeholder: LocalizedStringKey
    let original: String
    var font: Font = .system(size: 14)
    var bordered = true
    /// Called only with a real change: trimmed, non-empty, different.
    let onCommit: (String) -> Void
    /// Called once when editing ends, whether or not anything changed.
    let onEnd: () -> Void

    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(_ placeholder: LocalizedStringKey, original: String, font: Font = .system(size: 14), bordered: Bool = true,
         onCommit: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        self.placeholder = placeholder
        self.original = original
        self.font = font
        self.bordered = bordered
        self.onCommit = onCommit
        self.onEnd = onEnd
        _text = State(initialValue: original)
    }

    /// The name to save for `draft`, or nil to keep `original`.
    static func resolvedName(draft: String, original: String) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == original ? nil : name
    }

    var body: some View {
        field
            .font(font)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }  // Escape
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }  // clicked elsewhere
            }
    }

    @ViewBuilder
    private var field: some View {
        if bordered {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        }
    }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        if save, let name = Self.resolvedName(draft: text, original: original) { onCommit(name) }
        onEnd()
    }
}
