//  AudioRecorder.swift
//  Records a short voice note to a temp .m4a file, for the Insert menu's
//  "Record Audio..." command. The temp file lives until it's either
//  attached to a page (EditorController copies it into the RTFD) or
//  cancelled, whichever comes first.

import AVFoundation
import CoreAudio

final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.errorMessage = "Microphone access was denied. Enable it in System Settings \u{203A} Privacy & Security \u{203A} Microphone."
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "Microphone access was denied. Enable it in System Settings \u{203A} Privacy & Security \u{203A} Microphone."
        @unknown default:
            errorMessage = "Couldn't access the microphone."
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                errorMessage = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            outputURL = url
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
        } catch {
            errorMessage = "Couldn't start recording."
        }
    }

    /// Stops and returns the recorded file's URL, or nil if nothing was
    /// recorded. The caller owns the file after this - it's on them to
    /// either consume it (attach it) or delete it.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate()
        timer = nil
        if let recorder { elapsed = recorder.currentTime }
        recorder?.stop()
        recorder = nil
        isRecording = false
        return outputURL
    }

    /// Stops (if needed) and discards the temp file - used when the user
    /// dismisses the recorder without inserting it.
    func cancel() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }
}
