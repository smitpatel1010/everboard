import AVFoundation
import Observation

/// Reads briefs aloud with the on-device voices (nothing leaves the Mac).
@MainActor @Observable
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()

    private(set) var speakingID: String?
    private(set) var paused = false
    @ObservationIgnored private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(id: String, text: String, voice: String, rate: Double) {
        if speakingID == id {
            if synth.isPaused { synth.continueSpeaking(); paused = false } else { synth.pauseSpeaking(at: .word); paused = true }
            return
        }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: Self.spoken(text))
        u.voice = AVSpeechSynthesisVoice(identifier: voice) ?? Self.bestEnglishVoice
        u.rate = Float(rate)
        u.postUtteranceDelay = 0.2
        speakingID = id
        paused = false
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speakingID = nil
        paused = false
    }

    /// Premium/enhanced English voices sound far better than the compact defaults.
    static var bestEnglishVoice: AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Markdown → speakable prose: drop symbols, link targets and list markers; pause at headings.
    static func spoken(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("#") { l = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) + "." }
            l = l.replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            l = l.replacingOccurrences(of: "→", with: " to ").replacingOccurrences(of: "!", with: " MR ")
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil; self.paused = false }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.speakingID = nil } }
    }
}
