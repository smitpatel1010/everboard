import AVFoundation
import Observation
import Speech

/// Push-to-talk speech recognition with Apple's Speech framework. When the Mac supports it and the setting is on,
/// recognition runs on-device, so audio never leaves the Mac. No third-party or open-source models are involved.
@MainActor @Observable
final class VoiceInput {
    static let shared = VoiceInput()

    enum State: Equatable { case idle, listening, unavailable(String) }

    private(set) var state: State = .idle
    /// Live transcript while listening.
    private(set) var transcript = ""
    /// Audio level 0…1 for the mic animation.
    private(set) var level: Double = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinal: ((String) -> Void)?

    var isListening: Bool { state == .listening }

    /// Whether this Mac can recognise speech without sending audio to Apple.
    static var supportsOnDevice: Bool { SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false }

    /// Asks for microphone and speech permission the first time. Returns a message if either is refused.
    func authorize() async -> String? {
        let speech = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        guard speech == .authorized else {
            return "Speech recognition is off for Everboard. Turn it on in System Settings → Privacy & Security → Speech Recognition."
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return "Microphone access is off for Everboard. Turn it on in System Settings → Privacy & Security → Microphone." }
        return nil
    }

    /// Starts listening; `onFinal` gets the transcript when you stop (or recognition ends on its own).
    func start(onDeviceOnly: Bool, onFinal: @escaping (String) -> Void) async {
        guard !isListening else { return }
        if let problem = await authorize() { state = .unavailable(problem); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available right now.")
            return
        }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            state = .unavailable("This Mac can't recognise speech on-device for \(recognizer.locale.identifier). Allow Apple's server recognition in Settings → Voice, or type instead.")
            return
        }
        self.onFinal = onFinal
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDeviceOnly
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.level = level }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if isFinal || error != nil { self.finish() }
            }
        }
    }

    /// Stops listening and delivers what was heard.
    func stop() {
        guard isListening else { return }
        request?.endAudio()
        // The final result arrives shortly after endAudio; finish() also runs if it never does.
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            finish()
        }
    }

    func cancel() {
        onFinal = nil
        finish()
    }

    private func finish() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        state = .idle
        level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = onFinal
        onFinal = nil
        if !text.isEmpty { deliver?(text) }
    }

    func clearProblem() { if case .unavailable = state { state = .idle } }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(Double(sqrt(sum / Float(buffer.frameLength))) * 8, 1)
    }
}
