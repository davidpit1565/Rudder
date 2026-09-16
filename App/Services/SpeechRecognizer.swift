import Foundation
import Speech
import AVFoundation

/// Turns speech into text for the decision prompt field. Wraps SFSpeechRecognizer
/// and AVAudioEngine behind a small start/stop API so HomeView only needs "is it
/// listening" and "here is the latest transcript" -- not the framework's own
/// permission/session/tap plumbing.
@MainActor
@Observable
final class SpeechRecognizer {
    enum Failure: LocalizedError {
        case notAuthorized
        case notAvailable
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Turn on Speech Recognition and Microphone access in Settings to use voice input."
            case .notAvailable:
                return "Speech recognition isn't available on this device right now."
            case .couldNotStart:
                return "Couldn't start listening. Try again."
            }
        }
    }

    private(set) var isRecording = false
    private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Starts listening. `onTranscript` is called on the main actor with the
    /// best transcription so far every time it updates -- there is no fixed
    /// duration, the caller decides when enough is enough via `stop()`.
    func start(onTranscript: @escaping @MainActor (String) -> Void) {
        errorMessage = nil
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = Failure.notAvailable.localizedDescription
            return
        }

        Task {
            async let speechAuthorized = requestSpeechAuthorization()
            async let microphoneAuthorized = requestMicrophoneAuthorization()
            guard await speechAuthorized, await microphoneAuthorized else {
                errorMessage = Failure.notAuthorized.localizedDescription
                return
            }
            do {
                try beginRecording(recognizer: recognizer, onTranscript: onTranscript)
            } catch {
                errorMessage = Failure.couldNotStart.localizedDescription
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func beginRecording(
        recognizer: SFSpeechRecognizer,
        onTranscript: @escaping @MainActor (String) -> Void
    ) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Stays on-device when the platform supports it for this locale -- no
        // audio leaves the phone just to fill a text field.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        // SFSpeechRecognitionTask's result handler is a plain, framework-owned
        // callback, not guaranteed to land on the main actor -- pull only the
        // Sendable values out of `result` here, then hop with those, rather than
        // carrying the (non-Sendable) result object or `self` across untracked.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let transcript {
                    onTranscript(transcript)
                }
                if failed || isFinal {
                    self.stop()
                }
            }
        }
    }
}
