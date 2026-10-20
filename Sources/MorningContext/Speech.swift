import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text on the shared, echo-cancelled audio engine (`AudioIO`).
/// Two modes:
/// - **turn**: you're talking; your turn ends on a natural pause (text stopped changing *and* you went quiet).
/// - **barge-in**: Morning Context is talking and the mic stays open; two or more of your words (that aren't
///   an echo of what it's saying) interrupt it and become your turn.
/// macOS 26+: Apple's SpeechAnalyzer, primed with names from today's brief. Older macOS: SFSpeechRecognizer.
final class Listener {
    enum Outcome { case heard(String), nothing, failed(String) }

    var onPartial: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    var onFinish: (Outcome) -> Void = { _ in }
    /// You started talking over the voice.
    var onBargeIn: (String) -> Void = { _ in }
    /// What the voice has just been saying, so its own echo is never mistaken for you.
    var recentlySpoken: () -> String = { "" }

    /// Names and jargon to bias recognition towards (people, repos, tickets).
    var vocabulary: [String] = []
    /// How long a pause ends your turn, and how long to wait for you to start.
    var endOfTurnPause: TimeInterval = 1.6
    var waitForSpeech: TimeInterval = 8

    private var backend: TranscriptionBackend?
    private var latest = ""
    private var heardSpeech = false
    private var silenceTimer: Timer?
    private var giveUpTimer: Timer?
    private(set) var isListening = false
    /// True while only watching for an interruption (the voice is talking).
    private(set) var bargeInMode = false

    static func requestPermissions(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done("Speech recognition is off for Morning Context. Turn it on in System Settings → Privacy & Security → Speech Recognition.") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok ? nil : "Microphone access is off for Morning Context. Turn it on in System Settings → Privacy & Security → Microphone.") }
            }
        }
    }

    /// Start listening: `bargeIn: true` while the voice is talking, false for your turn.
    func start(bargeIn: Bool = false) {
        guard !isListening else { if !bargeIn { promote() }; return }
        do { try AudioIO.shared.start() } catch {
            if !bargeIn { onFinish(.failed("Couldn't start the microphone: \(error.localizedDescription)")) }
            return
        }
        let format = AudioIO.shared.inputFormat

        let b: TranscriptionBackend
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            b = AnalyzerBackend(vocabulary: vocabulary)
        } else {
            b = LegacyBackend()
        }
        b.onText = { [weak self] text in
            DispatchQueue.main.async { self?.heard(text) }
        }
        b.onError = { [weak self] msg in
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                if self.bargeInMode { self.cancel(); return }
                if self.latest.isEmpty { self.cancel(); self.onFinish(.failed(msg)) } else { self.finish() }
            }
        }
        do { try b.begin(inputFormat: format) } catch {
            if !bargeIn { onFinish(.failed("Speech recognition couldn't start: \(error.localizedDescription)")) }
            return
        }
        backend = b
        latest = ""; heardSpeech = false
        bargeInMode = bargeIn
        isListening = true

        AudioIO.shared.setInputHandler { [weak self, weak b] buffer in
            b?.append(buffer)
            let level = Listener.level(buffer)
            DispatchQueue.main.async {
                guard let self, self.isListening else { return }
                if !self.bargeInMode { self.onLevel(level) }
                // Still talking (loud enough) → don't end the turn yet, even if the text hasn't changed.
                if !self.bargeInMode, self.heardSpeech, level > 0.45 { self.armSilenceTimer() }
            }
        }
        if !bargeIn { armGiveUp() }
    }

    /// The voice finished: keep the same recognition running, now as your turn.
    func promote() {
        guard isListening, bargeInMode else { return }
        bargeInMode = false
        latest = ""; heardSpeech = false
        sessionOffset = lastFull.count   // ignore whatever was transcribed while the voice was talking
        armGiveUp()
    }

    /// Stop now and use the final transcript (or whatever was heard so far).
    func finish() {
        guard isListening else { return }
        let wasBargeIn = bargeInMode
        stopAudio()
        let fallback = latest
        let b = backend; backend = nil
        if wasBargeIn { b?.cancel(); return }
        guard let b else { deliver(fallback); return }
        let offset = sessionOffset
        b.end { [weak self] final in
            // The final transcript covers the whole session (including time the voice was talking): keep your part.
            let f = final ?? ""
            let mine = offset > 0 && f.count > offset ? String(f.dropFirst(offset)) : (offset > 0 ? "" : f)
            self?.deliver(mine.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : mine)
        }
    }

    func cancel() {
        guard isListening else { return }
        stopAudio()
        backend?.cancel(); backend = nil
    }

    private func heard(_ full: String) {
        guard isListening, !full.isEmpty else { return }
        lastFull = full
        if bargeInMode {
            // Only words that aren't an echo of the voice count.
            let mine = Listener.newWords(in: full, notIn: recentlySpoken())
            // Without hardware echo cancellation (e.g. sound on an external display), its own voice can be
            // misheard as new words, so ask for a bit more before treating it as you.
            guard mine.count >= (AudioIO.shared.echoCancelling ? 2 : 4) else { return }
            bargeInMode = false
            sessionOffset = full.count - mine.joined(separator: " ").count
            latest = mine.joined(separator: " ")
            heardSpeech = true
            onBargeIn(latest)
            onPartial(latest)
            armSilenceTimer()
            return
        }
        // Text since your turn began (barge-in sessions carry earlier, echo-filtered text).
        let text = sessionOffset > 0 && full.count > sessionOffset ? String(full.dropFirst(sessionOffset)).trimmingCharacters(in: .whitespaces) : full
        latest = text
        heardSpeech = true
        giveUpTimer?.invalidate()
        onPartial(text)
        armSilenceTimer()
    }

    private var sessionOffset = 0
    private var lastFull = ""

    /// Words in `heard` that don't appear in what the voice just said (lower-cased, 2+ letters). A misheard echo
    /// ("ranching" for "branching") counts as the voice too: anything within one or two letters of a spoken word.
    static func newWords(in heard: String, notIn spoken: String) -> [String] {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        }
        let said = Set(words(spoken))
        return heard.components(separatedBy: .whitespaces).filter { w in
            guard let core = words(w).first, !said.contains(core) else { return false }
            let tolerance = core.count >= 7 ? 2 : (core.count >= 4 ? 1 : 0)
            return !said.contains { abs($0.count - core.count) <= tolerance && editDistance($0, core) <= tolerance }
        }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }; if y.isEmpty { return x.count }
        var prev = Array(0...y.count), cur = prev
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    private func deliver(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onPartial(t) }
        onFinish(t.isEmpty ? .nothing : .heard(t))
    }

    private func armGiveUp() {
        giveUpTimer?.invalidate()
        giveUpTimer = Timer.scheduledTimer(withTimeInterval: waitForSpeech, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: endOfTurnPause, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func stopAudio() {
        isListening = false
        bargeInMode = false
        sessionOffset = 0
        lastFull = ""
        silenceTimer?.invalidate(); giveUpTimer?.invalidate()
        AudioIO.shared.setInputHandler(nil)
        onLevel(0)
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(max(n, 1)))
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))  // ~-50…-10 dBFS → 0…1
    }
}

protocol TranscriptionBackend: AnyObject {
    var onText: (String) -> Void { get set }
    var onError: (String) -> Void { get set }
    func begin(inputFormat: AVAudioFormat) throws
    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Flush and return the final transcript on the main queue (nil if none).
    func end(_ done: @escaping (String?) -> Void)
    func cancel()
}

@available(macOS 26.0, *)
final class AnalyzerBackend: TranscriptionBackend {
    var onText: (String) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    private let vocabulary: [String]
    private var raw: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var task: Task<String, Error>?

    init(vocabulary: [String]) { self.vocabulary = vocabulary }

    func begin(inputFormat: AVAudioFormat) throws {
        let (rawStream, rawCont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        raw = rawCont
        let vocab = vocabulary
        let emit = { [weak self] (s: String) in self?.onText(s) }
        task = Task {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocab.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = vocab
                try? await analyzer.setContext(ctx)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw NSError(domain: "MorningContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format for speech analysis"])
            }
            let results = Task { () -> String in
                var finalized = "", volatile = ""
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal { finalized += text; volatile = "" } else { volatile = text }
                    emit((finalized + volatile).trimmingCharacters(in: .whitespaces))
                }
                return finalized.trimmingCharacters(in: .whitespaces)
            }
            let (input, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: input)
            var converter: AVAudioConverter?
            for await buf in rawStream {
                if let out = Self.convert(buf, to: format, converter: &converter) { inputCont.yield(AnalyzerInput(buffer: out)) }
            }
            inputCont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let copy = buffer.copied() { raw?.yield(copy) }
    }

    func end(_ done: @escaping (String?) -> Void) {
        raw?.finish(); raw = nil
        let t = task
        var delivered = false
        let deliver = { (s: String?) in DispatchQueue.main.async { if !delivered { delivered = true; done(s) } } }
        Task {
            let final = try? await t?.value
            deliver(final)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { deliver(nil) }   // never hang the conversation
        Task { [weak self] in
            if case .failure(let e)? = await t?.result { self?.onError(e.localizedDescription) }
        }
    }

    func cancel() {
        raw?.finish(); raw = nil
        task?.cancel()
    }

    private static func convert(_ b: AVAudioPCMBuffer, to fmt: AVAudioFormat, converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if b.format == fmt { return b }
        if converter == nil {
            converter = AVAudioConverter(from: b.format, to: fmt)
            converter?.downmix = true   // echo-cancelled mic input can arrive as several channels
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * fmt.sampleRate / b.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return b
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

final class LegacyBackend: TranscriptionBackend {
    var onText: (String) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalDone: ((String?) -> Void)?
    private var latest = ""

    func begin(inputFormat: AVAudioFormat) throws {
        guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable else {
            throw NSError(domain: "MorningContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available right now."])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                self.onText(self.latest)
                if result.isFinal { self.complete(self.latest) }
            } else if let error {
                self.complete(nil)
                self.onError(error.localizedDescription)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }

    func end(_ done: @escaping (String?) -> Void) {
        finalDone = done
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.complete(self?.latest) }
    }

    func cancel() { task?.cancel(); task = nil; request = nil }

    private func complete(_ s: String?) {
        DispatchQueue.main.async {
            guard let done = self.finalDone else { return }
            self.finalDone = nil
            self.task?.cancel()
            done(s)
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Tap buffers are reused by the audio engine; take a copy before handing one to another thread.
    func copied() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for (s, d) in zip(src, dst) where s.mData != nil && d.mData != nil {
            memcpy(d.mData, s.mData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return c
    }
}

/// Names and jargon from today's brief, to prime speech recognition ("atlas", "Siobhan", "INFRA"…).
enum Vocabulary {
    static func from(_ text: String, limit: Int = 100) -> [String] {
        var score: [String: Int] = [:]
        func add(_ pattern: String, weight: Int) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let w = String(text[r]).trimmingCharacters(in: .whitespaces)
                // Spoken words only: no paths, flags, hashes, snake_case or other code clutter.
                guard w.count >= 3, w.count <= 30, !stop.contains(w), w.first?.isLetter == true,
                      w.range(of: "[0-9_/:=\\\\.\"@]|--", options: .regularExpression) == nil else { continue }
                score[w, default: 0] += weight
            }
        }
        add("`([^`\\n]{3,40})`", weight: 3)                  // repos, branches, identifiers
        add("\\b([A-Z][a-z]+(?: [A-Z][a-z]+)?)\\b", weight: 1) // people, products
        add("\\b([A-Z]{2,6}[0-9]*)\\b", weight: 2)              // INFRA, API, PBI
        add("\\b([a-z]+[A-Z][A-Za-z]+)\\b", weight: 2)          // camelCase names
        return score.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private static let stop: Set<String> = ["The", "This", "That", "Today", "Yesterday", "Tuesday", "Monday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday", "October", "Also", "Open", "Last", "One", "Use", "Ask", "Finish", "Chase", "Sort", "Review",
        "What", "Worth", "Meetings", "Morning", "No", "Not", "All", "And", "But", "For", "Here", "Branch", "Resolve", "TL", "DR"]
}

/// Streaming text-to-speech for the conversation: starts talking on the first sentence while the rest is still
/// arriving. Uses ElevenLabs when a key is set (the next sentence is fetched while the current one plays),
/// otherwise — or if a request fails — the Mac voice from Settings → Voice.
/// During a conversation everything plays through `AudioIO` (echo-cancelled, so you can talk over it);
/// outside one (Settings → Test voice) it plays directly.
final class StreamingVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onSentenceStart: (String) -> Void = { _ in }
    var onAllDone: () -> Void = {}
    var onNotice: (String) -> Void = { _ in }

    private final class Item {
        let caption: String   // as written, for the on-screen caption
        let text: String      // as spoken
        var pcm: Data?        // ElevenLabs audio (16-bit, 24 kHz)
        var rendered: AVAudioPCMBuffer?   // Mac voice, rendered ahead of time for the engine
        var rendering = false
        var useMacVoice: Bool
        var task: URLSessionDataTask?
        var index = 0         // position in the reply, for natural variation between sentences
        init(caption: String, text: String, useMacVoice: Bool) { self.caption = caption; self.text = text; self.useMacVoice = useMacVoice }
    }
    private var sentenceIndex = 0

    private let synth = AVSpeechSynthesizer()
    private let renderer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [Item] = []
    private var playing = false
    private var generation = 0
    private var cloudFailed = false
    private var spoken: [String] = []

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { playing || !queue.isEmpty }

    /// The last few sentences actually played, for telling your voice apart from its echo.
    var recentlySpoken: String { spoken.suffix(3).joined(separator: " ") }

    private var viaEngine: Bool { AudioIO.shared.running }

    func say(_ sentence: String) {
        let s = Pronunciation.normalize(sentence)
        guard !s.isEmpty else { return }
        let item = Item(caption: Humanize.caption(sentence.trimmingCharacters(in: .whitespacesAndNewlines)), text: s,
                        useMacVoice: !Settings.useElevenLabs || cloudFailed || !ElevenLabs.isConfigured)
        item.index = sentenceIndex
        sentenceIndex += 1
        queue.append(item)
        if item.useMacVoice { renderIfNeeded(item) } else { fetch(item) }
        pump()
    }

    func stop() {
        generation += 1
        sentenceIndex = 0
        queue.forEach { $0.task?.cancel() }
        queue.removeAll()
        playing = false
        player?.stop(); player = nil
        synth.stopSpeaking(at: .immediate)
        if viaEngine { AudioIO.shared.stopPlayback() }
    }

    private func fetch(_ item: Item) {
        let gen = generation
        let started = Date()
        let s = Humanize.caption(item.text)   // ElevenLabs gets plain text (no stress markers)
        item.task = ElevenLabs.synthesize(s) { [weak self, weak item] result in
            guard let self, let item, gen == self.generation else { return }
            switch result {
            case .success(let data):
                item.pcm = data
                AppLog().info(String(format: "elevenlabs %.2fs %dKB (%d chars)", Date().timeIntervalSince(started), data.count / 1024, s.count))
            case .failure(let e):
                AppLog().info("elevenlabs failed: \(e.localizedDescription)")
                item.useMacVoice = true
                if !self.cloudFailed { self.onNotice("\(e.localizedDescription) Using the Mac voice for now.") }
                self.cloudFailed = true
                self.renderIfNeeded(item)
            }
            self.pump()
        }
    }

    /// For the engine, the Mac voice is rendered to audio first (so it can be echo-cancelled like ElevenLabs).
    private func renderIfNeeded(_ item: Item) {
        guard viaEngine, item.useMacVoice, item.rendered == nil, !item.rendering else { return }
        item.rendering = true
        let gen = generation
        var chunks: [AVAudioPCMBuffer] = []
        let text = item.text, index = item.index
        renderer.write(utterance(text, index: index)) { [weak self, weak item] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 { chunks.append(pcm); return }
            // The engine doesn't apply postUtteranceDelay, so the natural pause is added as silence.
            let joined = AudioIO.shared.convert(chunks).map { StreamingVoice.padded($0, frames: Humanize.silence(after: text, index: index, format: $0.format)) }
            DispatchQueue.main.async {
                guard let self, let item, gen == self.generation else { return }
                item.rendering = false
                item.rendered = joined
                if joined == nil { item.useMacVoice = true }
                self.pump()
            }
        }
    }

    /// Mac voice: SSML with breaths, pauses, stress and slight variation (see `Humanize`).
    private func utterance(_ text: String, index: Int) -> AVSpeechUtterance {
        Humanize.utterance(text, voice: Speaker.resolveVoice(), rate: Settings.speechRate, index: index)
    }

    static func padded(_ b: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength + frames),
              let src = b.floatChannelData?[0], let dst = out.floatChannelData?[0] else { return b }
        memcpy(dst, src, Int(b.frameLength) * MemoryLayout<Float>.size)
        memset(dst + Int(b.frameLength), 0, Int(frames) * MemoryLayout<Float>.size)
        out.frameLength = b.frameLength + frames
        return out
    }

    /// Play the next sentence once it's ready, strictly in order.
    private func pump() {
        guard !playing, let next = queue.first else { return }
        if viaEngine {
            let buffer: AVAudioPCMBuffer?
            if next.useMacVoice { buffer = next.rendered; if buffer == nil { renderIfNeeded(next); return } }
            else if let pcm = next.pcm { buffer = AudioIO.shared.buffer(pcm16: pcm) }
            else { return }   // still downloading — its completion calls pump() again
            queue.removeFirst()
            guard let buffer else { pump(); return }
            playing = true
            began(next)
            let gen = generation
            AudioIO.shared.play(buffer) { [weak self] in
                guard let self, gen == self.generation, self.playing else { return }
                self.finishedOne()
            }
            return
        }
        if next.useMacVoice {
            queue.removeFirst()
            playing = true
            began(next)
            synth.speak(utterance(next.text, index: next.index))
        } else if let pcm = next.pcm {
            queue.removeFirst()
            guard let p = try? AVAudioPlayer(data: AudioIO.wav(pcm16: pcm)) else { next.useMacVoice = true; queue.insert(next, at: 0); pump(); return }
            p.delegate = self
            player = p
            playing = true
            began(next)
            p.play()
        }
    }

    private func began(_ item: Item) {
        spoken.append(item.text)
        if spoken.count > 6 { spoken.removeFirst(spoken.count - 6) }
        onSentenceStart(item.caption)
    }

    private func finishedOne() {
        playing = false
        if queue.isEmpty { onAllDone() } else { pump() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.playing, !self.viaEngine { self.finishedOne() } }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if p === self.player { self.player = nil; self.finishedOne() } }
    }

    /// Lets "Test voice" in Settings retry ElevenLabs after a failure.
    func resetCloud() { cloudFailed = false }

    /// False when only the robotic default-quality voices are installed.
    static var hasNaturalVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix("en") && $0.quality != .default }
    }
}

/// Small fixes so a speech engine says things the way a person would.
enum Pronunciation {
    /// Parsed from Settings → Pronunciation ("word = how to say it"); longest words first so
    /// "atlas-web" can be listed separately from "atlas".
    static func rules(_ text: String = Settings.pronunciations) -> [(word: String, say: String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].hasPrefix("#") else { return nil }
            return (parts[0], parts[1])
        }.sorted { $0.word.count > $1.word.count }
    }

    static func normalize(_ s: String, rules: [(word: String, say: String)] = rules()) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Your pronunciations first, whole words, any capitalisation ("Atlas", "atlas's").
        for r in rules {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: r.word) + "(?![A-Za-z0-9])"
            t = t.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: r.say),
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Dashes and arrows are pauses, not words.
        for (from, to) in [(" — ", ", "), (" – ", ", "), ("—", ", "), (" → ", " to "), ("→", " to "), ("&", " and ")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        // CamelCase product names: "PayFlow" → "Pay Flow", "MorningContext" → "Morning Context".
        t = t.replacingOccurrences(of: "\\b([A-Z][a-z]+)([A-Z][a-z]+)\\b", with: "$1 $2", options: .regularExpression)
        // "PR #42" / "#42" → "PR 42"
        t = t.replacingOccurrences(of: "#(\\d)", with: "$1", options: .regularExpression)
        return t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }
}

/// Splits Claude's token stream into speakable sentences, and pulls out `ACTION:` lines (shown, never spoken).
struct SpeechChunker {
    struct Action: Identifiable, Equatable {
        enum Kind: String { case copy, open, claude, claudeStart = "claude-start", remember, recheck }
        let id = UUID()
        let label: String
        let kind: Kind
        let payload: String
    }

    private var buffer = ""
    private var lineFresh = true   // buffer holds the start of a line (so it could still become an ACTION line)

    mutating func feed(_ text: String) -> (sentences: [String], actions: [Action]) {
        var sentences: [String] = []
        var actions: [Action] = []
        for ch in text {
            if ch == "\n" {
                let (s, a) = flush()
                sentences += s; actions += a
                continue
            }
            buffer.append(ch)
            let t = buffer.trimmingCharacters(in: .whitespaces)
            // Hold anything that is, or might still turn into, an ACTION line.
            if t.hasPrefix("ACTION:") || (lineFresh && "ACTION:".hasPrefix(t)) { continue }
            // Sentence end = . ! ? followed by a space (so "3.5" and "v1.2" don't split).
            if ch == " ", let prev = buffer.dropLast().last, ".!?".contains(prev), t.count > 12 {
                sentences.append(Self.clean(buffer)); buffer = ""; lineFresh = false
            }
        }
        return (sentences, actions)
    }

    mutating func flush() -> (sentences: [String], actions: [Action]) {
        defer { buffer = ""; lineFresh = true }
        let s = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return ([], []) }
        if s.hasPrefix("ACTION:") { return ([], Self.parseAction(s).map { [$0] } ?? []) }
        return ([Self.clean(s)], [])
    }

    static func parseAction(_ line: String) -> Action? {
        let body = line.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("ACTION:".count)
        let parts = body.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let kind = Action.Kind(rawValue: parts[1].lowercased()), !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
        if kind == .open, !(parts[2].hasPrefix("https://") || parts[2].hasPrefix("http://")) { return nil }
        if kind == .claude || kind == .claudeStart || kind == .recheck, !parts[2].contains("::") { return nil }
        return Action(label: parts[0], kind: kind, payload: parts[2].replacingOccurrences(of: "\\n", with: "\n"))
    }

    /// Strip Markdown the model slipped in, so the voice doesn't say "asterisk".
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["**", "__", "`", "#"] { t = t.replacingOccurrences(of: token, with: "") }
        if t.hasPrefix("- ") || t.hasPrefix("* ") { t = String(t.dropFirst(2)) }
        return t
    }
}
