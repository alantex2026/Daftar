//  EditorController.swift
//
//  This is the "remote control" for the text editor.
//  The toolbar buttons call methods here, and this file talks to the
//  real macOS text view (NSTextView) that draws and edits the text.

import SwiftUI
import AppKit
import Combine
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// A minimal NSObject shim so EditorController - a plain ObservableObject,
/// not an NSObject subclass - can still receive AVAudioPlayer's delegate
/// callbacks without having to become one itself.
final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void = {}
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

@MainActor
final class EditorController: ObservableObject {

    /// The real macOS text view. `weak` means we do not keep it alive ourselves.
    weak var textView: NSTextView?

    // Values the toolbar reads to show which buttons are switched on.
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderlined = false
    @Published var isStrikethrough = false
    @Published var fontSize: CGFloat = 13
    @Published var alignment: NSTextAlignment = .left
    @Published var wordCount: Int = 0
    @Published var characterCount: Int = 0
    // Persisted in UserDefaults so they survive a relaunch instead of quietly
    // resetting - editable from the Settings window (Cmd+,).
    // UserDefaults is the source of truth (see `AppSettings`); these mirror it
    // so views update, and follow changes made in the Settings window.
    @Published var zoom: Double = AppSettings.zoom {
        didSet { if zoom != AppSettings.zoom { UserDefaults.standard.set(zoom, forKey: AppSettings.editorZoom) } }
    }
    @Published var spellCheckOn: Bool = AppSettings.spellCheck {
        didSet {
            if spellCheckOn != AppSettings.spellCheck { UserDefaults.standard.set(spellCheckOn, forKey: AppSettings.spellCheckEnabled) }
            textView?.isContinuousSpellCheckingEnabled = spellCheckOn
        }
    }
    /// How long the editors wait after the last keystroke before saving.
    @Published var autoSaveDelay: Double = AppSettings.saveDelay {
        didSet { if autoSaveDelay != AppSettings.saveDelay { UserDefaults.standard.set(autoSaveDelay, forKey: AppSettings.autoSaveDelay) } }
    }
    private var settingsObserver: AnyCancellable?
    private var countsWork: DispatchWorkItem?

    init() {
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadSettings() }
    }

    private func reloadSettings() {
        if zoom != AppSettings.zoom { zoom = AppSettings.zoom }
        if spellCheckOn != AppSettings.spellCheck { spellCheckOn = AppSettings.spellCheck }
        if autoSaveDelay != AppSettings.saveDelay { autoSaveDelay = AppSettings.saveDelay }
    }
    @Published var styleName: String = "Normal"

    /// Set whenever a save, load, export, or insert silently failed, so the
    /// UI has something to show instead of just losing the change.
    @Published var errorMessage: String?

    /// Shown in the status bar so typing has a visible "your words are safe" signal.
    enum SaveState { case idle, saving, saved, failed }
    @Published var saveState: SaveState = .idle

    /// Reads the user's chosen default font/size from Settings each time,
    /// so a change there is picked up by the next page without a relaunch.
    nonisolated static var defaultFont: NSFont {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.object(forKey: AppSettings.editorFontSize) as? Double ?? 13)
        guard let name = defaults.string(forKey: AppSettings.editorFontName), name != "System" else {
            return NSFont.systemFont(ofSize: size)
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    // MARK: - Reading the current state

    /// Look at where the cursor is and update the toolbar button states.
    func refreshState() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        var attrs: [NSAttributedString.Key: Any] = tv.typingAttributes

        if let storage = tv.textStorage, storage.length > 0 {
            let index = min(max(range.location, 0), storage.length - 1)
            attrs = storage.attributes(at: index, effectiveRange: nil)
        }

        let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
        let traits = NSFontManager.shared.traits(of: font)
        isBold = traits.contains(.boldFontMask)
        isItalic = traits.contains(.italicFontMask)
        isUnderlined = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        isStrikethrough = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        fontSize = font.pointSize
        alignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
    }

    /// Word counting is O(document length); while typing, do it once things
    /// settle instead of on every keystroke.
    func scheduleCountsRefresh() {
        countsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshCounts() }
        countsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refreshCounts() {
        let text = textView?.string ?? ""
        characterCount = text.count
        wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Small helpers

    /// Every "run" of text in a range that shares the same font.
    func fontRuns(in range: NSRange) -> [(NSRange, NSFont)] {
        guard let storage = textView?.textStorage else { return [] }
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            runs.append((sub, (value as? NSFont) ?? Self.defaultFont))
        }
        return runs
    }

    /// Safely change the selected text, keeping Undo working.
    func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        tv.didChangeText()
        refreshState()
    }

    /// The full paragraph (line) the cursor is sitting in.
    func currentParagraphRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        return (tv.string as NSString).paragraphRange(for: tv.selectedRange())
    }

    // MARK: - State owned by the feature extensions (EditorController+Images, +Audio, +Navigation).
    // Stored properties must live in the class body; treat them as private to their extension.

    /// Side table tracking each on-screen image attachment's last-known
    /// width, so `snapRecentlyResizedImages` can tell "the user just
    /// dragged this one" apart from "this is the same size it's always
    /// been" without attachments needing to carry that state themselves.
    var knownImageWidths: [ObjectIdentifier: CGFloat] = [:]
    var isApplyingImageSnap = false

    var audioPlayer: AVAudioPlayer?
    var playingAudioID: UUID?
    lazy var audioPlaybackDelegate: AudioPlaybackDelegate = {
        let delegate = AudioPlaybackDelegate()
        delegate.onFinish = { [weak self] in
            DispatchQueue.main.async {
                self?.playingAudioID = nil
                self?.audioPlayer = nil
            }
        }
        return delegate
    }()

    /// Set once by ContentView. "Add to Recording" needs the same
    /// record-audio UI the Insert menu already uses, which is a SwiftUI
    /// popover EditorController has no view hierarchy of its own to show -
    /// so it just asks, the same way page-link navigation does.
    var onRequestAudioAppend: ((UUID) -> Void)?

    /// Set once by ContentView. Fires when the user activates a link to
    /// another page (Cmd-click in the text, or a tap in Linked Mentions),
    /// so navigation can happen without EditorController needing to know
    /// about SwiftData or the sidebar's selection state.
    var onNavigateToLink: ((UUID) -> Void)?
}
