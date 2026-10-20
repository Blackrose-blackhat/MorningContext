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

        // The whole script as SSML: pauses between sentences and paragraphs, breaths, slight variation.
        let u = AVSpeechUtterance(ssmlRepresentation: Humanize.document(clean)) ?? AVSpeechUtterance(string: clean)
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
        // No voice chosen in the app: the one you picked in System Settings → Accessibility → Spoken Content.
        // (Leaving the voice unset would give the *language* default instead, e.g. en-IN → "Rishi".)
        if let v = spokenContentVoice() { return v }
        return bestInstalledVoice()
    }

    /// Your Spoken Content voice for English (or the current language), read from the Accessibility preferences.
    static func spokenContentVoice() -> AVSpeechSynthesisVoice? {
        CFPreferencesAppSynchronize("com.apple.Accessibility" as CFString)   // pick up a change made while we're running
        guard let list = CFPreferencesCopyAppValue("SpokenContentDefaultVoiceSelectionsByLanguage" as CFString,
                                                   "com.apple.Accessibility" as CFString) as? [Any] else { return nil }
        // Stored as [language, {voiceId: …}, language, {…}, …]
        var byLanguage: [String: String] = [:]
        var i = 0
        while i + 1 < list.count {
            if let lang = list[i] as? String, let sel = list[i + 1] as? [String: Any], let id = sel["voiceId"] as? String {
                byLanguage[lang] = id
            }
            i += 2
        }
        let current = Locale.current.language.languageCode?.identifier ?? "en"
        for lang in [Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), current, "en"] {
            if let id = byLanguage[lang], let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        }
        return nil
    }

    /// The old automatic pick (best quality installed, then locale), kept for reference in Settings.
    static func bestInstalledVoice() -> AVSpeechSynthesisVoice? {
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
