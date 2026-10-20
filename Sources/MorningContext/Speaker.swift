import Foundation
import AVFoundation
import Combine

/// Reads the brief aloud with macOS's built-in speech synthesizer (offline, no key).
/// Tip: download a Premium/Enhanced voice in System Settings → Accessibility →
/// Spoken Content → System Voice → Manage Voices; it sounds dramatically better.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override private init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let clean = Speaker.stripMarkdown(text)
        guard !clean.isEmpty else { return }

        let u = AVSpeechUtterance(string: clean)
        u.voice = Speaker.resolveVoice()
        u.rate = Settings.speechRate
        u.prefersAssistiveTechnologySettings = false
        u.preUtteranceDelay = 0.3
        current = u
        synth.speak(u)
        isSpeaking = true
        isPaused = false
    }

    func stop() {
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPaused = false
    }

    func togglePause() {
        if synth.isPaused { synth.continueSpeaking(); isPaused = false }
        else if synth.isSpeaking { synth.pauseSpeaking(at: .word); isPaused = true }
    }

    // MARK: Voices

    /// Voices suitable for the picker: English voices, best quality first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func resolveVoice() -> AVSpeechSynthesisVoice? {
        let wanted = Settings.voiceIdentifier
        if !wanted.isEmpty, let v = AVSpeechSynthesisVoice(identifier: wanted) { return v }
        // Default: quality first (Premium > Enhanced > compact), then your locale. Among the compact voices,
        // locale alone picks badly (en-IN → "Rishi", one of the most robotic), so prefer the clearest ones.
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let clearest = ["Samantha", "Daniel", "Karen", "Moira", "Tessa"]
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 100
            if v.quality != .default, v.language == locale { s += 20 }
            if v.quality == .default, let i = clearest.firstIndex(of: v.name) { s += 20 - i }
            if v.language == "en-US" { s += 1 }
            return s
        }
        return availableVoices().max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }

    // MARK: Markdown → speakable text

    static func stripMarkdown(_ s: String) -> String {
        var out: [String] = []
        for raw in s.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<!--") || line == "---" || line == "***" || line.hasPrefix("```") { continue }
            line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^- \[[ xX]\]\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            if line.isEmpty { continue }
            // Make sure each line ends as a sentence so the voice pauses naturally.
            if let last = line.last, !".!?:;".contains(last) { line += "." }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: AVSpeechSynthesizerDelegate

    private func ended(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.current else { return }   // ignore callbacks from a superseded utterance
            self.current = nil; self.isSpeaking = false; self.isPaused = false
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { ended(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { ended(utterance) }
}
