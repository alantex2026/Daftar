//  EditorController+Audio.swift
//  Recorded voice notes embedded as clickable chips.

import AppKit
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

extension EditorController {
    // MARK: - Audio attachments

    /// A recorded voice note is stored as [icon attachment][separator]
    /// [caption text], all three sharing one `daftar-audio://<id>` link
    /// attribute. That shared link is what lets Cmd-clicking any part of
    /// the chip bring up its actions menu (see RichTextEditor.Coordinator),
    /// and what lets later actions re-find the right spot in the document
    /// by id rather than by character position - a raw index captured at
    /// click time would go stale by the time an async append finishes.
    private static func audioActionURL(_ id: UUID) -> URL {
        DaftarLink.audio(id).url
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
}
