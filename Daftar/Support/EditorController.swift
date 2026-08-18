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

/// A minimal NSObject shim so EditorController - a plain ObservableObject,
/// not an NSObject subclass - can still receive AVAudioPlayer's delegate
/// callbacks without having to become one itself.
private final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void = {}
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

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
    @Published var zoom: Double = UserDefaults.standard.object(forKey: "editorZoom") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(zoom, forKey: "editorZoom") }
    }
    @Published var spellCheckOn: Bool = UserDefaults.standard.object(forKey: "spellCheckEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spellCheckOn, forKey: "spellCheckEnabled")
            textView?.isContinuousSpellCheckingEnabled = spellCheckOn
        }
    }
    /// How long RichTextEditor waits after the last keystroke before saving.
    @Published var autoSaveDelay: Double = UserDefaults.standard.object(forKey: "autoSaveDelay") as? Double ?? 0.4 {
        didSet { UserDefaults.standard.set(autoSaveDelay, forKey: "autoSaveDelay") }
    }
    @Published var styleName: String = "Normal"

    /// Set whenever a save, load, export, or insert silently failed, so the
    /// UI has something to show instead of just losing the change.
    @Published var errorMessage: String?

    /// Shown in the status bar so typing has a visible "your words are safe" signal.
    enum SaveState { case idle, saving, saved }
    @Published var saveState: SaveState = .idle

    /// Reads the user's chosen default font/size from Settings each time,
    /// so a change there is picked up by the next page without a relaunch.
    static var defaultFont: NSFont {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.object(forKey: "editorFontSize") as? Double ?? 13)
        guard let name = defaults.string(forKey: "editorFontName"), name != "System" else {
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

    func refreshCounts() {
        let text = textView?.string ?? ""
        characterCount = text.count
        wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Small helpers

    /// Every "run" of text in a range that shares the same font.
    private func fontRuns(in range: NSRange) -> [(NSRange, NSFont)] {
        guard let storage = textView?.textStorage else { return [] }
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            runs.append((sub, (value as? NSFont) ?? Self.defaultFont))
        }
        return runs
    }

    /// Safely change the selected text, keeping Undo working.
    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
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
    private func currentParagraphRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        return (tv.string as NSString).paragraphRange(for: tv.selectedRange())
    }

    // MARK: - Bold / Italic

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()

        // Nothing selected: change what the NEXT typed characters will look like.
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
            attrs[.font] = fm.traits(of: font).contains(trait)
                ? fm.convert(font, toNotHaveTrait: trait)
                : fm.convert(font, toHaveTrait: trait)
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        let runs = fontRuns(in: range)
        let allHave = runs.allSatisfy { fm.traits(of: $0.1).contains(trait) }
        edit(range) { storage in
            for (r, f) in runs {
                let newFont = allHave ? fm.convert(f, toNotHaveTrait: trait)
                                      : fm.convert(f, toHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: r)
            }
        }
    }

    func toggleBold()   { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    // MARK: - Underline

    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = (attrs[.underlineStyle] as? Int) ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allUnderlined = false }
        }
        edit(range) { storage in
            storage.addAttribute(.underlineStyle,
                                 value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
    }

    // MARK: - Strikethrough

    func toggleStrikethrough() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let current = (attrs[.strikethroughStyle] as? Int) ?? 0
            attrs[.strikethroughStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            refreshState()
            return
        }

        var allStruck = true
        storage.enumerateAttribute(.strikethroughStyle, in: range, options: []) { value, _, _ in
            if ((value as? Int) ?? 0) == 0 { allStruck = false }
        }
        edit(range) { storage in
            storage.addAttribute(.strikethroughStyle,
                                 value: allStruck ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
    }

    // MARK: - Font size

    func setFontSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()

        if range.length == 0 {
            var attrs = tv.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
            attrs[.font] = fm.convert(font, toSize: size)
            tv.typingAttributes = attrs
            fontSize = size
            return
        }

        let runs = fontRuns(in: range)
        edit(range) { storage in
            for (r, f) in runs {
                storage.addAttribute(.font, value: fm.convert(f, toSize: size), range: r)
            }
        }
    }

    func stepFontSize(by delta: CGFloat) {
        setFontSize(max(6, min(200, fontSize + delta)))
    }

    // MARK: - Colors

    func setTextColor(_ color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.foregroundColor] = color
            tv.typingAttributes = attrs
            return
        }
        edit(range) { $0.addAttribute(.foregroundColor, value: color, range: range) }
    }

    func setHighlight(_ color: NSColor?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if let color { attrs[.backgroundColor] = color }
            else { attrs.removeValue(forKey: .backgroundColor) }
            tv.typingAttributes = attrs
            return
        }
        edit(range) { storage in
            if let color { storage.addAttribute(.backgroundColor, value: color, range: range) }
            else { storage.removeAttribute(.backgroundColor, range: range) }
        }
    }

    // MARK: - Paragraph styles (Normal, Heading 1, ...)

    enum TextStyle: String, CaseIterable, Identifiable {
        case normal    = "Normal"
        case heading1  = "Heading 1"
        case heading2  = "Heading 2"
        case heading3  = "Heading 3"
        case monospace = "Code"

        var id: String { rawValue }

        var font: NSFont {
            switch self {
            case .normal:    return NSFont.systemFont(ofSize: 13)
            case .heading1:  return NSFont.systemFont(ofSize: 26, weight: .bold)
            case .heading2:  return NSFont.systemFont(ofSize: 20, weight: .semibold)
            case .heading3:  return NSFont.systemFont(ofSize: 16, weight: .semibold)
            case .monospace: return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            }
        }
    }

    func applyStyle(_ style: TextStyle) {
        guard let tv = textView else { return }
        styleName = style.rawValue
        var range = tv.selectedRange()
        if range.length == 0 { range = currentParagraphRange() }

        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = style.font
            tv.typingAttributes = attrs
            fontSize = style.font.pointSize
            return
        }
        edit(range) { $0.addAttribute(.font, value: style.font, range: range) }
        var attrs = tv.typingAttributes
        attrs[.font] = style.font
        tv.typingAttributes = attrs
    }

    // MARK: - Alignment

    func setAlignment(_ newAlignment: NSTextAlignment) {
        guard let tv = textView else { return }
        let range = currentParagraphRange()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        tv.setAlignment(newAlignment, range: range)
        tv.didChangeText()
        alignment = newAlignment
    }

    // MARK: - Simple bullet / numbered lists

    /// If `line` starts with a numbered-list marker ("1. "), the text after the marker. Otherwise nil.
    private func numberedListContent(of line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              line.distance(from: line.startIndex, to: dot) <= 2,
              Int(line[line.startIndex..<dot]) != nil,
              line.count > line.distance(from: line.startIndex, to: dot) + 1 else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    func toggleBullet(numbered: Bool = false) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = currentParagraphRange()
        let text = (storage.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")

        var counter = 1
        let rebuilt = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }

            // Strip whatever marker is already there, and remember whether it
            // was the SAME kind we were asked for (in which case we turn it off)
            // or the OTHER kind (in which case we convert it below).
            let bareLine: String
            let sameKindAlreadyApplied: Bool
            if line.hasPrefix("• ") {
                bareLine = String(line.dropFirst(2))
                sameKindAlreadyApplied = !numbered
            } else if let content = numberedListContent(of: line) {
                bareLine = content
                sameKindAlreadyApplied = numbered
            } else if let checklist = Self.checklistContent(of: line) {
                bareLine = checklist.text
                sameKindAlreadyApplied = false
            } else {
                bareLine = line
                sameKindAlreadyApplied = false
            }

            if sameKindAlreadyApplied { return bareLine }
            if numbered {
                let out = "\(counter). " + bareLine
                counter += 1
                return out
            }
            return "• " + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
    }

    // MARK: - Checklists

    private static let checklistToggleURL = URL(string: "daftar://checklist-toggle")!

    /// If `line` starts with a checklist marker, whether it's checked and
    /// the text after the marker. Otherwise nil. Static (like the glyph
    /// marker below) so RichTextEditor can call it too, when it re-marks
    /// checklist glyphs clickable right after loading a page.
    static func checklistContent(of line: String) -> (checked: Bool, text: String)? {
        if line.hasPrefix("\u{2610} ") { return (false, String(line.dropFirst(2))) }
        if line.hasPrefix("\u{2611} ") { return (true, String(line.dropFirst(2))) }
        return nil
    }

    /// Marks every checklist glyph in `range` as a clickable link, so
    /// Cmd-clicking it can flip checked state via the same link-click
    /// mechanism page links use (see RichTextEditor.Coordinator). Only run
    /// when checklist lines are created or a page is loaded - not on every
    /// keystroke, which a full-document scan would be too costly for.
    static func markChecklistGlyphs(in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let nsString = storage.string as NSString
        nsString.enumerateSubstrings(in: range, options: .byParagraphs) { substring, subRange, _, _ in
            guard let substring, subRange.length > 0, checklistContent(of: substring) != nil else { return }
            storage.addAttribute(.link, value: checklistToggleURL, range: NSRange(location: subRange.location, length: 1))
        }
    }

    /// Converts the current line(s) to checklist items, or - if every
    /// selected line already is one - back to plain text. Mirrors
    /// `toggleBullet`'s on/off contract exactly, for the same reason: one
    /// button, press again to undo.
    func toggleChecklist() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = currentParagraphRange()
        let text = (storage.string as NSString).substring(with: range)
        let lines = text.components(separatedBy: "\n")

        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allAlreadyChecklist = !nonBlank.isEmpty && nonBlank.allSatisfy { Self.checklistContent(of: $0) != nil }

        let rebuilt = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allAlreadyChecklist {
                return Self.checklistContent(of: line)?.text ?? line
            }
            let bareLine: String
            if let checklist = Self.checklistContent(of: line) {
                bareLine = checklist.text
            } else if line.hasPrefix("• ") {
                bareLine = String(line.dropFirst(2))
            } else if let numbered = numberedListContent(of: line) {
                bareLine = numbered
            } else {
                bareLine = line
            }
            return "\u{2610} " + bareLine
        }.joined(separator: "\n")

        guard tv.shouldChangeText(in: range, replacementString: rebuilt) else { return }
        let attrs = storage.length > 0
            ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
            : tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: rebuilt, attributes: attrs))
        tv.didChangeText()
        Self.markChecklistGlyphs(in: NSRange(location: range.location, length: (rebuilt as NSString).length), storage: storage)
    }

    /// Flips one checklist line's checked state - called when its glyph is
    /// Cmd-clicked. Also strikes through (or un-strikes) the item's text,
    /// without touching any other formatting already on that line.
    func toggleChecklistItem(at charIndex: Int) {
        guard let tv = textView, let storage = tv.textStorage,
              charIndex >= 0, charIndex < storage.length else { return }
        let lineRange = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        let line = (storage.string as NSString).substring(with: lineRange)
        guard let content = Self.checklistContent(of: line) else { return }

        let hasTrailingNewline = line.hasSuffix("\n")
        let textLength = max(0, lineRange.length - 2 - (hasTrailingNewline ? 1 : 0))
        let newGlyph = content.checked ? "\u{2610}" : "\u{2611}"

        guard tv.shouldChangeText(in: lineRange, replacementString: nil) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: newGlyph)
        storage.addAttribute(.link, value: Self.checklistToggleURL, range: NSRange(location: lineRange.location, length: 1))
        if textLength > 0 {
            let textRange = NSRange(location: lineRange.location + 2, length: textLength)
            storage.addAttribute(.strikethroughStyle,
                                 value: content.checked ? 0 : NSUnderlineStyle.single.rawValue,
                                 range: textRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: - Inserting things

    func insert(_ attributed: NSAttributedString) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: attributed.string) else { return }
        storage.replaceCharacters(in: range, with: attributed)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        refreshCounts()
    }

    func insertDate(includeTime: Bool) {
        guard let tv = textView else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = includeTime ? .short : .none
        insert(NSAttributedString(string: formatter.string(from: Date()),
                                  attributes: tv.typingAttributes))
    }

    func applyLink(_ urlString: String) {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let tv = textView else { return }

        let range = tv.selectedRange()
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        if range.length == 0 {
            var attrs = tv.typingAttributes
            linkAttrs.forEach { attrs[$0.key] = $0.value }
            insert(NSAttributedString(string: text, attributes: attrs))
        } else {
            edit(range) { $0.addAttributes(linkAttrs, range: range) }
        }
    }

    func insertImage(from url: URL) {
        guard let wrapper = try? FileWrapper(url: url, options: .immediate) else {
            errorMessage = "Couldn't insert \u{201C}\(url.lastPathComponent)\u{201D}."
            return
        }
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        if let image = NSImage(contentsOf: url) {
            let maxWidth: CGFloat = 520
            var size = image.size
            if size.width > maxWidth {
                size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width)
            }
            attachment.bounds = NSRect(origin: .zero, size: size)
        }
        insert(NSAttributedString(attachment: attachment))
    }

    // MARK: - Audio attachments

    /// A recorded voice note is stored as [icon attachment][separator]
    /// [caption text], all three sharing one `daftar-audio://<id>` link
    /// attribute. That shared link is what lets Cmd-clicking any part of
    /// the chip bring up its actions menu (see RichTextEditor.Coordinator),
    /// and what lets later actions re-find the right spot in the document
    /// by id rather than by character position - a raw index captured at
    /// click time would go stale by the time an async append finishes.
    private static func audioActionURL(_ id: UUID) -> URL {
        URL(string: "daftar-audio://\(id.uuidString)")!
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Filenames look like "My Recording (0:42).m4a" - the parenthesized
    /// (m:ss) suffix is the duration, kept in sync automatically; only the
    /// part before it is what Rename actually edits.
    private static func audioFilename(base: String, duration: TimeInterval) -> String {
        "\(base) (\(formattedDuration(duration))).m4a"
    }

    private static func parseAudioFilename(_ filename: String) -> (base: String, duration: TimeInterval)? {
        guard filename.hasSuffix(".m4a") else { return nil }
        let withoutExt = String(filename.dropLast(4))
        guard let openParen = withoutExt.lastIndex(of: "("), withoutExt.hasSuffix(")") else { return nil }
        let base = withoutExt[withoutExt.startIndex..<openParen].trimmingCharacters(in: .whitespaces)
        let timeString = withoutExt[withoutExt.index(after: openParen)..<withoutExt.index(before: withoutExt.endIndex)]
        let parts = timeString.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        return (base, TimeInterval(m * 60 + s))
    }

    private static let audioIcon: NSImage? = {
        NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Audio recording")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
    }()

    private var audioPlayer: AVAudioPlayer?
    private var playingAudioID: UUID?
    private lazy var audioPlaybackDelegate: AudioPlaybackDelegate = {
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

    /// Embeds a recorded voice note as a small clickable chip: an icon
    /// followed by its name and length. Cmd-click it for playback, rename,
    /// appending more audio, copy, share, and delete.
    func insertAudioAttachment(from url: URL, duration: TimeInterval) {
        guard let wrapper = try? FileWrapper(url: url, options: .immediate) else {
            errorMessage = "Couldn't insert the recording."
            return
        }
        let id = UUID()
        let baseName = "Audio Recording"
        wrapper.preferredFilename = Self.audioFilename(base: baseName, duration: duration)
        insertAudioChip(id: id, wrapper: wrapper, name: baseName, duration: duration)
    }

    private func insertAudioChip(id: UUID, wrapper: FileWrapper, name: String, duration: TimeInterval) {
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.image = Self.audioIcon
        attachment.bounds = NSRect(x: 0, y: -5, width: 18, height: 18)

        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(
            string: "  \(name) \u{00B7} \(Self.formattedDuration(duration))",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        result.addAttribute(.link, value: Self.audioActionURL(id), range: NSRange(location: 0, length: result.length))
        insert(result)
    }

    /// Finds a recording's current icon+caption range by its stable id,
    /// wherever it's ended up after any other edits.
    private func audioChipRange(for id: UUID) -> NSRange? {
        guard let storage = textView?.textStorage else { return nil }
        let target = Self.audioActionURL(id).absoluteString
        var found: NSRange?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            let urlString = (value as? URL)?.absoluteString ?? value as? String
            if urlString == target { found = range; stop.pointee = true }
        }
        return found
    }

    private func audioAttachment(for id: UUID) -> (range: NSRange, wrapper: FileWrapper)? {
        guard let range = audioChipRange(for: id), let storage = textView?.textStorage,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              let wrapper = attachment.fileWrapper else { return nil }
        return (range, wrapper)
    }

    func togglePlayback(ofAudioID id: UUID) {
        if playingAudioID == id, let player = audioPlayer {
            if player.isPlaying { player.pause() } else { player.play() }
            return
        }
        guard let (_, wrapper) = audioAttachment(for: id), let data = wrapper.regularFileContents else {
            errorMessage = "Couldn't play this recording."
            return
        }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = audioPlaybackDelegate
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingAudioID = id
        } catch {
            errorMessage = "Couldn't play this recording."
        }
    }

    func isPlaying(audioID id: UUID) -> Bool {
        playingAudioID == id && (audioPlayer?.isPlaying ?? false)
    }

    /// The recording's current display name, for pre-filling Rename's
    /// text field instead of making the user retype it from scratch.
    func currentAudioName(id: UUID) -> String? {
        guard let (_, wrapper) = audioAttachment(for: id) else { return nil }
        return Self.parseAudioFilename(wrapper.preferredFilename ?? "")?.base
    }

    func renameAudioAttachment(id: UUID, to newBase: String) {
        let trimmed = newBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let (range, wrapper) = audioAttachment(for: id),
              let parsed = Self.parseAudioFilename(wrapper.preferredFilename ?? "") else { return }
        wrapper.preferredFilename = Self.audioFilename(base: trimmed, duration: parsed.duration)
        replaceCaption(in: range, id: id, name: trimmed, duration: parsed.duration)
    }

    /// Swaps just the "Name · m:ss" text after the icon - used by both
    /// Rename and, once its export finishes, Add to Recording.
    private func replaceCaption(in range: NSRange, id: UUID, name: String, duration: TimeInterval) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let captionRange = NSRange(location: range.location + 1, length: range.length - 1)
        guard captionRange.location >= 0, NSMaxRange(captionRange) <= storage.length,
              tv.shouldChangeText(in: captionRange, replacementString: nil) else { return }
        let newCaption = NSAttributedString(
            string: "  \(name) \u{00B7} \(Self.formattedDuration(duration))",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                        .link: Self.audioActionURL(id)])
        storage.replaceCharacters(in: captionRange, with: newCaption)
        tv.didChangeText()
    }

    func copyAudioAttachment(id: UUID) {
        guard let url = exportAudioTempFile(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    /// A throwaway file holding the recording's current bytes, for Share
    /// (which needs a real file on disk, not in-memory data) and Copy.
    func exportAudioTempFile(id: UUID) -> URL? {
        guard let (_, wrapper) = audioAttachment(for: id), let data = wrapper.regularFileContents else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(wrapper.preferredFilename ?? "Recording.m4a")
        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    func deleteAudioAttachment(id: UUID) {
        guard let tv = textView, let storage = tv.textStorage, let range = audioChipRange(for: id) else { return }
        if playingAudioID == id { audioPlayer?.stop(); audioPlayer = nil; playingAudioID = nil }
        guard tv.shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        tv.didChangeText()
    }

    /// Records more audio and appends it to an existing recording via an
    /// offline audio composition/export, then swaps the attachment's file
    /// and caption for the combined result. Re-finds the chip by id when
    /// the (multi-second) export finishes rather than trusting a
    /// character position captured before it started, since the document
    /// may have changed in the meantime.
    func appendToAudioAttachment(id: UUID, newAudioURL: URL) async {
        guard let (_, wrapper) = audioAttachment(for: id), let existingData = wrapper.regularFileContents else {
            try? FileManager.default.removeItem(at: newAudioURL)
            errorMessage = "Couldn't find that recording anymore."
            return
        }
        let existingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            try existingData.write(to: existingURL)
        } catch {
            try? FileManager.default.removeItem(at: newAudioURL)
            errorMessage = "Couldn't extend this recording."
            return
        }
        defer {
            try? FileManager.default.removeItem(at: existingURL)
            try? FileManager.default.removeItem(at: newAudioURL)
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            errorMessage = "Couldn't extend this recording."
            return
        }

        var combinedDuration = CMTime.zero
        do {
            for sourceURL in [existingURL, newAudioURL] {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: combinedDuration)
                combinedDuration = CMTimeAdd(combinedDuration, duration)
            }
        } catch {
            errorMessage = "Couldn't extend this recording."
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            errorMessage = "Couldn't extend this recording."
            return
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard export.status == .completed, let combinedData = try? Data(contentsOf: outputURL) else {
            errorMessage = "Couldn't extend this recording."
            return
        }

        guard let (range, currentWrapper) = audioAttachment(for: id),
              let storage = textView?.textStorage,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else {
            errorMessage = "That recording's page changed before the extended audio finished."
            return
        }
        let name = Self.parseAudioFilename(currentWrapper.preferredFilename ?? "")?.base ?? "Audio Recording"
        let newWrapper = FileWrapper(regularFileWithContents: combinedData)
        newWrapper.preferredFilename = Self.audioFilename(base: name, duration: combinedDuration.seconds)
        attachment.fileWrapper = newWrapper
        replaceCaption(in: range, id: id, name: name, duration: combinedDuration.seconds)
    }

    func insertFileAttachment(from url: URL) {
        guard let wrapper = try? FileWrapper(url: url, options: .immediate) else {
            errorMessage = "Couldn't attach \u{201C}\(url.lastPathComponent)\u{201D}."
            return
        }
        wrapper.preferredFilename = url.lastPathComponent
        insert(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    }

    func insertTable(rows: Int, columns: Int) {
        guard let tv = textView else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let font = (tv.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
        let result = NSMutableAttributedString()

        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table,
                                             startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                result.append(NSAttributedString(string: " \n",
                                                 attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        insert(result)
    }

    // MARK: - Table of Contents

    struct HeadingItem: Identifiable {
        let id = UUID()
        let range: NSRange
        let text: String
        let level: Int   // 1 = Heading 1, 2 = Heading 2, 3 = Heading 3
    }

    /// Scans the page for paragraphs styled as one of the built-in heading
    /// sizes (see `TextStyle`). A heuristic, not a stored outline - cheap
    /// enough to run on demand when the Table of Contents is opened, no
    /// need to keep it up to date on every keystroke.
    func headings() -> [HeadingItem] {
        guard let storage = textView?.textStorage, storage.length > 0 else { return [] }
        var result: [HeadingItem] = []
        let full = NSRange(location: 0, length: storage.length)
        (storage.string as NSString).enumerateSubstrings(in: full, options: .byParagraphs) { substring, subRange, _, _ in
            guard let substring, subRange.location < storage.length else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let font = (storage.attribute(.font, at: subRange.location, effectiveRange: nil) as? NSFont) ?? Self.defaultFont
            let level: Int
            switch font.pointSize {
            case 22...:   level = 1
            case 18..<22: level = 2
            case 15..<18: level = 3
            default: return
            }
            result.append(HeadingItem(range: subRange, text: trimmed, level: level))
        }
        return result
    }

    /// Scrolls to and places the cursor at the start of a heading.
    func goTo(_ heading: HeadingItem) {
        guard let tv = textView else { return }
        tv.scrollRangeToVisible(heading.range)
        tv.setSelectedRange(NSRange(location: heading.range.location, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - Page links (internal linking)

    /// Set once by ContentView. Fires when the user activates a link to
    /// another page (Cmd-click in the text, or a tap in Linked Mentions),
    /// so navigation can happen without EditorController needing to know
    /// about SwiftData or the sidebar's selection state.
    var onNavigateToLink: ((UUID) -> Void)?

    /// Inserts a clickable link to another page at the cursor, styled the
    /// same way `applyLink` styles a web link.
    func insertPageLink(to page: Page) {
        guard let url = URL(string: "daftar://page/\(page.linkID.uuidString)") else { return }
        var attrs = textView?.typingAttributes ?? [:]
        attrs[.link] = url
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        insert(NSAttributedString(string: page.displayTitle, attributes: attrs))
    }

    // MARK: - Find bar, spell check, export

    func showFindBar() {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performFindPanelAction(item)
    }

    func toggleSpellCheck() {
        spellCheckOn.toggle()
    }

    /// Save the current page as a PDF file.
    func exportPDF(to url: URL) {
        guard let tv = textView else { return }
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            errorMessage = "Couldn't export as PDF."
            return
        }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        info.horizontalPagination = .fit
        info.topMargin = 40; info.bottomMargin = 40
        info.leftMargin = 40; info.rightMargin = 40

        let operation = NSPrintOperation(view: tv, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        if !operation.run() {
            errorMessage = "Couldn't export as PDF."
        }
    }

    /// Give back the current text as RTF data (for "Export as RTF").
    func currentRTF() -> Data? {
        guard let storage = textView?.textStorage else { return nil }
        let full = NSRange(location: 0, length: storage.length)
        do {
            return try storage.data(from: full,
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            errorMessage = "Couldn't export as RTF."
            return nil
        }
    }
}
