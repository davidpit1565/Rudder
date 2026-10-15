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
        case recognitionFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Turn on Speech Recognition and Microphone access in Settings to use voice input."
            case .notAvailable:
                return "Speech recognition isn't available on this device right now."
            case .couldNotStart:
                return "Couldn't start listening. Try again."
            case .recognitionFailed:
                return "I didn't catch that. Try again."
            }
        }
    }

    private(set) var isRecording = false
    private(set) var errorMessage: String?
    /// True from the moment `start()` is called until `isRecording` would
    /// normally flip true -- closes a real window where tapping the mic
    /// button twice quickly (e.g. once while still waiting on the
    /// permission prompts to resolve) ran `beginRecording()` twice
    /// concurrently. The second call's `installTap` then hit a bus that
    /// already had one installed, which AVAudioEngine reports as an
    /// uncatchable Objective-C exception, not a Swift error -- confirmed
    /// live as the app being killed outright on tapping the mic, not a
    /// graceful failure. `isRecording` alone doesn't close this window: it
    /// only becomes true at the very end of `beginRecording`, after the
    /// async permission checks above have already had time to run twice.
    private var isStarting = false

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set once per `start()` call, the first time the on-device attempt fails
    /// outright -- guards the one-shot fallback below from retrying forever.
    private var hasFallenBackToServerBasedRecognition = false

    /// Starts listening. `onTranscript` is called on the main actor with the
    /// best transcription so far every time it updates -- there is no fixed
    /// duration, the caller decides when enough is enough via `stop()`.
    func start(onTranscript: @escaping @MainActor (String) -> Void) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        hasFallenBackToServerBasedRecognition = false
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = Failure.notAvailable.localizedDescription
            isStarting = false
            return
        }

        Task {
            async let speechAuthorized = requestSpeechAuthorization()
            async let microphoneAuthorized = requestMicrophoneAuthorization()
            guard await speechAuthorized, await microphoneAuthorized else {
                errorMessage = Failure.notAuthorized.localizedDescription
                isStarting = false
                return
            }
            do {
                try beginRecording(recognizer: recognizer, onTranscript: onTranscript, forceServerBased: false)
            } catch {
                errorMessage = Failure.couldNotStart.localizedDescription
            }
            isStarting = false
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
        onTranscript: @escaping @MainActor (String) -> Void,
        forceServerBased: Bool
    ) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Stays on-device when the platform supports it for this locale -- no
        // audio leaves the phone just to fill a text field. But
        // `supportsOnDeviceRecognition` only reports whether the *capability*
        // exists for this locale, not whether its language data is actually
        // downloaded -- a less common on-device locale (confirmed: Hebrew)
        // reliably fails outright (error 1101) when it isn't, with nothing the
        // user did wrong and no on-device fallback of its own. The one-shot
        // retry below (`forceServerBased`) is what actually recovers that case.
        request.requiresOnDeviceRecognition = forceServerBased ? false : recognizer.supportsOnDeviceRecognition
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // AVAudioEngine's installTap crashes outright -- an uncatchable
        // Objective-C assertion, not a Swift error -- when given a format
        // with no sample rate or no channels, which the input route can
        // briefly report right after the audio session activates. Refusing
        // here is the only safe response; the one-shot server-based retry
        // above still has a path to recover a transient case like this.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.couldNotStart
        }
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
        let wasOnDevice = request.requiresOnDeviceRecognition
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let transcript {
                    onTranscript(transcript)
                }
                if failed, wasOnDevice, !self.hasFallenBackToServerBasedRecognition,
                   transcript == nil || transcript?.isEmpty == true {
                    // The on-device attempt never produced anything before
                    // failing -- most likely its language data isn't
                    // downloaded. Retry once over the network rather than
                    // leaving voice input dead for this locale.
                    self.hasFallenBackToServerBasedRecognition = true
                    self.stop()
                    do {
                        try self.beginRecording(recognizer: recognizer, onTranscript: onTranscript, forceServerBased: true)
                    } catch {
                        self.errorMessage = Failure.couldNotStart.localizedDescription
                    }
                    return
                }
                if failed {
                    self.errorMessage = Failure.recognitionFailed.localizedDescription
                }
                if failed || isFinal {
                    self.stop()
                }
            }
        }
    }
}
