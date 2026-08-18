//  RichTextEditor.swift
//
//  SwiftUI does not have a full rich-text editor yet, so we borrow the one
//  macOS already has (NSTextView) and wrap it so SwiftUI can use it.
//  `NSViewRepresentable` is the official bridge between AppKit and SwiftUI.

import SwiftUI
import AppKit

struct RichTextEditor: NSViewRepresentable {

    /// The saved text of the page (RTFD data), loaded once when the view is created.
    let initialData: Data?

    /// Shared remote control used by the toolbar.
    @ObservedObject var controller: EditorController

    /// Called a moment after the user stops typing, so we can save. The
    /// third value is every other-page link found in the saved text, used
    /// to keep `Page.outgoingLinkIDs` (and so Linked Mentions) up to date.
    var onChange: (Data, String, [UUID]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    // Build the real macOS view.
    func makeNSView(context: Context) -> NSScrollView {
        PerfLog.mark("RichTextEditor.makeNSView START")
        defer { PerfLog.mark("RichTextEditor.makeNSView END") }
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = controller.spellCheckOn
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 46, height: 20)
        textView.font = EditorController.defaultFont
        textView.textColor = NSColor.textColor
        textView.typingAttributes = [
            .font: EditorController.defaultFont,
            .foregroundColor: NSColor.textColor
        ]

        // Full inline Writing Tools (proofread, rewrite, summarize), preserving
        // rich text formatting rather than flattening rewrites to plain text.
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table]
        }

        // Load the saved text of this page.
        var loadFailed = false
        if let data = initialData {
            PerfLog.measure("  RTFD decode (\(data.count) bytes)") {
                do {
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.rtfd],
                        documentAttributes: nil)
                    textView.textStorage?.setAttributedString(attributed)
                } catch {
                    loadFailed = true
                }
            }
        }
        // Self-healing: makes checklist glyphs clickable even if they got
        // there some other way than EditorController.toggleChecklist - a
        // Markdown import, or content from before this feature existed.
        if let storage = textView.textStorage, storage.length > 0 {
            EditorController.markChecklistGlyphs(in: NSRange(location: 0, length: storage.length), storage: storage)
        }

        context.coordinator.controller = controller

        // Done a tick later so we never change SwiftUI state while it is drawing.
        DispatchQueue.main.async {
            controller.textView = textView
            controller.refreshCounts()
            controller.refreshState()
            controller.saveState = .idle
            if loadFailed {
                controller.errorMessage = "This page's saved content couldn't be read. It may be damaged."
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if abs(scrollView.magnification - CGFloat(controller.zoom)) > 0.001 {
            scrollView.magnification = CGFloat(controller.zoom)
        }
        if let textView = scrollView.documentView as? NSTextView,
           controller.textView !== textView {
            controller.textView = textView
        }
        // Without this, opening a page never gives the text view first
        // responder status - the very first keystroke or paste lands on
        // whatever previously held focus (e.g. a sidebar row) and is
        // silently dropped, only working on a second attempt once the
        // user's own click has fixed it up. A single attempt right after
        // makeNSView isn't reliable because the scroll view isn't always
        // attached to a window yet at that point (it depends on SwiftUI's
        // transition/animation timing) - so keep retrying on every update
        // pass, which fires again as soon as the view is actually in a
        // window, until it succeeds once.
        if !context.coordinator.didFocusOnAppear,
           let window = scrollView.window,
           let textView = scrollView.documentView as? NSTextView {
            context.coordinator.didFocusOnAppear = true
            window.makeFirstResponder(textView)
        }
    }

    /// Called when the view goes away (for example when you switch pages).
    /// We save straight away so nothing is lost.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        PerfLog.measure("RichTextEditor.dismantleNSView (flush)") { coordinator.flush() }
    }

    // MARK: - Coordinator: listens to the text view

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (Data, String, [UUID]) -> Void
        weak var controller: EditorController?
        private var pendingSave: DispatchWorkItem?
        private var pendingEditLocation: Int?
        /// Set once `updateNSView` has successfully claimed first responder
        /// for a newly opened page, so we don't keep stealing focus back
        /// from e.g. the title field on every later SwiftUI update pass.
        var didFocusOnAppear = false
        // NSSharingServicePicker isn't retained by the system once `show`
        // returns, so it has to be held somewhere for the duration it's on
        // screen - the Coordinator (a class) outlives any single click.
        private var sharingPicker: NSSharingServicePicker?

        init(onChange: @escaping (Data, String, [UUID]) -> Void) {
            self.onChange = onChange
        }

        /// Cmd-clicking (or clicking, depending on the field editor state)
        /// a page link navigates; Cmd-clicking a checklist glyph flips it;
        /// Cmd-clicking an audio recording's icon/caption brings up its
        /// actions menu (play, rename, add to recording, copy, share, delete).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let urlString = (link as? URL)?.absoluteString ?? link as? String
            guard let urlString, let url = URL(string: urlString) else { return false }
            if url.scheme == "daftar-audio", let id = UUID(uuidString: url.host ?? "") {
                showAudioActionsMenu(id: id, textView: textView, at: charIndex)
                return true
            }
            guard url.scheme == "daftar" else { return false }
            if url.host == "page", let uuid = UUID(uuidString: url.lastPathComponent) {
                controller?.onNavigateToLink?(uuid)
                return true
            }
            if url.host == "checklist-toggle" {
                controller?.toggleChecklistItem(at: charIndex)
                return true
            }
            return false
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

        /// Remember where an edit (typed or pasted) is about to start, so
        /// `textDidChange` can tell exactly what text just landed.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            pendingEditLocation = affectedCharRange.location
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            normalizeColorOfLastEdit(in: textView)
            controller?.refreshCounts()
            controller?.saveState = .saving
            scheduleSave(for: textView)
        }

        /// Text pasted from another app brings its own color along (almost
        /// always a literal black) instead of adapting to the editor's
        /// theme the way typed text does. Force whatever was just inserted
        /// to the same adaptive color typing already uses.
        private func normalizeColorOfLastEdit(in textView: NSTextView) {
            guard let storage = textView.textStorage,
                  let start = pendingEditLocation else { return }
            pendingEditLocation = nil
            let end = textView.selectedRange().location
            guard end > start, end <= storage.length else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                  range: NSRange(location: start, length: end - start))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller?.refreshState()
        }

        /// Wait `controller.autoSaveDelay` seconds after the last keystroke, then save once.
        private func scheduleSave(for textView: NSTextView) {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak textView, weak self] in
                guard let self, let textView, let storage = textView.textStorage else { return }
                let full = NSRange(location: 0, length: storage.length)
                do {
                    let data = try PerfLog.measure("  RTFD encode (\(storage.length) chars)") {
                        try storage.data(from: full,
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                    }
                    self.onChange(data, storage.string, self.linkIDs(in: storage))
                    self.controller?.saveState = .saved
                } catch {
                    self.controller?.saveState = .idle
                    self.controller?.errorMessage = "Couldn't save your changes."
                }
            }
            pendingSave = work
            let delay = controller?.autoSaveDelay ?? 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// Every other page this text currently links to, read back out of
        /// the `.link` attributes `EditorController.insertPageLink` wrote.
        private func linkIDs(in storage: NSTextStorage) -> [UUID] {
            var ids: [UUID] = []
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.link, in: full, options: []) { value, _, _ in
                let urlString = (value as? URL)?.absoluteString ?? value as? String
                guard let urlString, let url = URL(string: urlString),
                      url.scheme == "daftar", url.host == "page",
                      let uuid = UUID(uuidString: url.lastPathComponent) else { return }
                ids.append(uuid)
            }
            return ids
        }

        func flush() {
            guard let work = pendingSave else { return }
            pendingSave = nil
            work.perform()
            work.cancel()
        }
    }
}
