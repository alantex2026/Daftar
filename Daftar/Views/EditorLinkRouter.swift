//  EditorLinkRouter.swift
//  What clicking an internal link does, shared by the continuous and the
//  paginated editor so both support the same links (pages, checklists,
//  audio recordings) instead of each keeping its own partial copy.

import AppKit

@MainActor
final class EditorLinkRouter: NSObject {
    weak var controller: EditorController?
    // NSSharingServicePicker isn't retained by the system once `show`
    // returns, so it has to be held for the duration it's on screen.
    private var sharingPicker: NSSharingServicePicker?

    /// Cmd-clicking (or clicking, depending on the field editor state)
    /// a page link navigates; Cmd-clicking a checklist glyph flips it;
    /// Cmd-clicking an audio recording's icon/caption brings up its
    /// actions menu (play, rename, add to recording, copy, share, delete).
    func handle(_ link: Any, at charIndex: Int, in textView: NSTextView) -> Bool {
        switch DaftarLink(link) {
        case .image?: return true
        case .audio(let id)?:
            showAudioActionsMenu(id: id, textView: textView, at: charIndex)
            return true
        case .page(let id)?:
            controller?.onNavigateToLink?(id)
            return true
        case .checklistToggle?:
            controller?.toggleChecklistItem(at: charIndex)
            return true
        case .file?, nil:
            return false
        }
    }

    // MARK: - Audio attachment actions

    // NSMenuItem/NSAlert titles are plain String, not LocalizedStringKey -
    // they don't go through the String Catalog automatically the way
    // SwiftUI's Text/Button do. String(localized:) does the same
    // catalog lookup explicitly, so this menu isn't silently English-only.
    private func showAudioActionsMenu(id: UUID, textView: NSTextView, at charIndex: Int) {
        guard let controller else { return }
        let menu = NSMenu()

        let playItem = NSMenuItem(
            title: String(localized: controller.isPlaying(audioID: id) ? "Pause" : "Play"),
            action: #selector(playPause(_:)), keyEquivalent: "")
        playItem.target = self
        playItem.representedObject = id
        menu.addItem(playItem)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(title: String(localized: "Rename\u{2026}"), action: #selector(rename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = (id, textView)
        menu.addItem(renameItem)

        let appendItem = NSMenuItem(title: String(localized: "Add to Recording\u{2026}"), action: #selector(appendRecording(_:)), keyEquivalent: "")
        appendItem.target = self
        appendItem.representedObject = id
        menu.addItem(appendItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: String(localized: "Copy"), action: #selector(copyAudio(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = id
        menu.addItem(copyItem)

        let shareItem = NSMenuItem(title: String(localized: "Share\u{2026}"), action: #selector(shareAudio(_:)), keyEquivalent: "")
        shareItem.target = self
        shareItem.representedObject = (id, textView)
        menu.addItem(shareItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: String(localized: "Delete Recording"), action: #selector(deleteAudio(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = id
        menu.addItem(deleteItem)

        let glyphIndex = textView.layoutManager?.glyphIndexForCharacter(at: charIndex) ?? charIndex
        var rect = textView.textContainer.map {
            textView.layoutManager?.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: $0) ?? .zero
        } ?? .zero
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: textView)
    }

    @objc private func playPause(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.togglePlayback(ofAudioID: id)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let (id, textView) = sender.representedObject as? (UUID, NSTextView) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Recording")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = controller?.currentAudioName(id: id) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.renameAudioAttachment(id: id, to: field.stringValue)
        }
        textView.window?.makeFirstResponder(textView)
    }

    @objc private func appendRecording(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.onRequestAudioAppend?(id)
    }

    @objc private func copyAudio(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.copyAudioAttachment(id: id)
    }

    @objc private func shareAudio(_ sender: NSMenuItem) {
        guard let (id, textView) = sender.representedObject as? (UUID, NSTextView),
              let url = controller?.exportAudioTempFile(id: id) else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        picker.show(relativeTo: .zero, of: textView, preferredEdge: .maxY)
    }

    @objc private func deleteAudio(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.deleteAudioAttachment(id: id)
    }
}
