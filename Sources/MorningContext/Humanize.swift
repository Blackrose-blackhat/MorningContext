import Foundation
import AVFoundation

/// Makes Apple's on-device voices sound less like a machine reading text: SSML with breaths at commas, real pauses
/// between thoughts, a little natural variation in pace and pitch from sentence to sentence, and stress on the one
/// word Claude marks with *asterisks*. Used for every Mac-voice sentence (live conversation and "Read aloud").
enum Humanize {

    /// The caption: the sentence as written, without stress markers.
    static func caption(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "")
    }

    /// A ready-to-speak utterance for one sentence, or a plain one if the voice can't take SSML.
    static func utterance(_ sentence: String, voice: AVSpeechSynthesisVoice?, rate: Float, index: Int = 0) -> AVSpeechUtterance {
        // SSML ignores `utterance.rate`, so the speed setting goes into the markup's prosody instead.
        let u = AVSpeechUtterance(ssmlRepresentation: ssml(sentence, index: index, speed: rate)) ?? AVSpeechUtterance(string: caption(sentence))
        u.voice = voice
        u.rate = rate
        u.prefersAssistiveTechnologySettings = false
        u.pitchMultiplier = 1
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = pauseAfter(sentence, index: index)
        return u
    }

    /// SSML for one sentence. `index` gives each sentence in a reply its own small, repeatable variation.
    /// `speed` is an AVSpeechUtterance rate (0.5 = normal), applied as SSML prosody.
    static func ssml(_ sentence: String, index: Int = 0, speed: Float = AVSpeechUtteranceDefaultSpeechRate) -> String {
        var body = escape(sentence.trimmingCharacters(in: .whitespacesAndNewlines))

        // Stress: *word* → emphasis (at most a couple per sentence; the rest stay plain).
        var stressed = 0
        while stressed < 2, let r = body.range(of: "\\*([^*]{1,40})\\*", options: .regularExpression) {
            let word = body[r].dropFirst().dropLast()
            body.replaceSubrange(r, with: "<emphasis level=\"moderate\">\(word)</emphasis>")
            stressed += 1
        }
        body = body.replacingOccurrences(of: "*", with: "")

        // Breaths: commas a beat, colons / dashes / semicolons a longer one.
        body = body.replacingOccurrences(of: ", ", with: ", <break time=\"\(jitter(110, index, 1))ms\"/> ")
        for mark in [": ", "; ", " — ", " – "] {
            body = body.replacingOccurrences(of: mark, with: "\(mark.trimmingCharacters(in: .whitespaces)) <break time=\"\(jitter(260, index, 2))ms\"/> ")
        }
        // Lead-ins people pause after: "So", "Okay", "Right", "Also", "One more thing".
        for lead in ["So", "Okay", "Right", "Also", "Now", "First", "Second", "Finally", "One more thing"] where body.hasPrefix(lead + " ") {
            body = lead + " <break time=\"\(jitter(140, index, 3))ms\"/>" + body.dropFirst(lead.count)
        }

        // Slight, natural drift in pace and pitch between sentences (never the same flat line twice).
        let base = Int((Double(speed) / Double(AVSpeechUtteranceDefaultSpeechRate) * 100).rounded())
        let rate = max(50, min(200, base + [-3, 1, -1, 2, -2, 0][abs(index) % 6]))
        let pitch = [0, 2, -1, 1, -2, 1][abs(index) % 6]
        return "<speak><prosody rate=\"\(rate)%\" pitch=\"\(pitch >= 0 ? "+" : "")\(pitch)%\">\(body)</prosody></speak>"
    }

    /// The silence after a sentence: longer after a question or a full stop, shorter inside a run of thought.
    static func pauseAfter(_ sentence: String, index: Int) -> TimeInterval {
        let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: Double = t.hasSuffix("?") ? 0.38 : (t.hasSuffix("!") ? 0.26 : (t.hasSuffix(".") ? 0.24 : 0.12))
        return base + [0.0, 0.05, -0.03, 0.08, 0.02, -0.02][abs(index) % 6]
    }

    /// Silence to append to rendered audio (the engine path doesn't apply postUtteranceDelay).
    static func silence(after sentence: String, index: Int, format: AVAudioFormat) -> AVAudioFrameCount {
        AVAudioFrameCount(max(0, pauseAfter(sentence, index: index)) * format.sampleRate)
    }

    /// The written brief as one SSML document for "Read aloud": a pause between paragraphs and sentences.
    static func document(_ text: String, speed: Float = Settings.speechRate) -> String {
        var parts: [String] = []
        var i = 0
        for paragraph in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !paragraph.isEmpty {
            for s in sentences(paragraph) {
                let inner = ssml(s, index: i, speed: speed).replacingOccurrences(of: "<speak>", with: "").replacingOccurrences(of: "</speak>", with: "")
                parts.append(inner + "<break time=\"\(Int(pauseAfter(s, index: i) * 1000))ms\"/>")
                i += 1
            }
            parts.append("<break time=\"450ms\"/>")
        }
        return "<speak>" + parts.joined(separator: " ") + "</speak>"
    }

    static func sentences(_ paragraph: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in paragraph {
            cur.append(ch)
            if ".!?".contains(ch), cur.count > 12 {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private static func jitter(_ ms: Int, _ index: Int, _ salt: Int) -> Int {
        ms + [-20, 10, 0, 25, -10, 15][abs(index &* 7 &+ salt) % 6]
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
