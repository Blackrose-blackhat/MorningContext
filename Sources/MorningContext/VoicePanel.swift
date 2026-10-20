import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The talk-to-it morning companion: a glass pill at the top of the screen that walks you through
/// yesterday out loud, lets you cut in any time (tap the orb, press Space, or ⌃⌥M), and answers follow-ups.
final class VoiceSession: ObservableObject {

    enum State: Equatable {
        case preparing(String)
        case thinking
        case checking(String)
        case speaking
        case listening
        case idle
        case error(String)
    }

    @Published var state: State = .idle
    @Published var caption = ""
    @Published var previousCaption = ""
    @Published var userLine = ""
    @Published var actions: [SpeechChunker.Action] = []
    @Published var level: Float = 0
    @Published var typed = ""
    @Published var notice: String?
    /// The conversation so far, for the message bubbles (your turns and what it actually said aloud).
    @Published var messages: [ChatLine] = []
    /// Recent loudness (yours while listening, its own while speaking) for the waveform and bars.
    @Published var levels: [Float] = Array(repeating: 0, count: 48)
    @Published var outputLevel: Float = 0
    /// When the current caption started being spoken, and how long it takes: drives word-by-word highlighting.
    @Published var captionStart = Date()
    @Published var captionDuration: Double = 1
    /// Orb only (arriving / leaving) vs. the full pill.
    @Published var expanded = false
    /// Muted: it won't listen while it talks or after it finishes (tap the orb to talk anyway).
    @Published var micMuted = false {
        didSet { if micMuted, listener.isListening, listener.bargeInMode { listener.cancel() } }
    }

    struct ChatLine: Identifiable, Equatable {
        let id = UUID()
        let role: ChatRole
        var text: String
    }
    private var assistantOpen = false

    private func pushLevel(_ v: Float) {
        levels.append(v)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
    }

    var onShowBrief: () -> Void = {}
    var onClose: () -> Void = {}

    private let engine = ConversationEngine()
    private let listener = Listener()
    private let voice = StreamingVoice()
    private var chunker = SpeechChunker()
    private var turnDone = true
    private var lastReply = ""
    private var permissionsAsked = false
    private var repos: [LiveChecks.Repo] = []
    /// What you actually heard of the current reply, and — if you cut in — where it stopped.
    private var spokenThisTurn: [String] = []
    private var interruptedAfter: String?
    private var pendingReports: [String] = []
    private var micAllowed = false

    init() {
        engine.onEvent = { [weak self] in self?.handle($0) }
        voice.onSentenceStart = { [weak self] s, duration in
            guard let self else { return }
            if !self.caption.isEmpty { self.previousCaption = self.caption }
            self.captionStart = Date()
            self.captionDuration = duration
            self.caption = s
            self.spokenThisTurn.append(s)
            if self.assistantOpen, let last = self.messages.indices.last, self.messages[last].role == .assistant {
                self.messages[last].text += (self.messages[last].text.isEmpty ? "" : " ") + s
            } else {
                self.messages.append(ChatLine(role: .assistant, text: s))
                self.assistantOpen = true
                if self.messages.count > 30 { self.messages.removeFirst(self.messages.count - 30) }
            }
        }
        voice.onAllDone = { [weak self] in
            guard let self, self.turnDone else { return }
            self.afterReply()
        }
        voice.onNotice = { [weak self] in self?.notice = $0 }
        listener.onPartial = { [weak self] in self?.userLine = $0 }
        listener.recentlySpoken = { [weak self] in self?.voice.recentlySpoken ?? "" }
        // You started talking over it: stop mid-sentence, remember where, and make it your turn.
        listener.onBargeIn = { [weak self] text in
            guard let self else { return }
            AppLog().info("barge-in: \(text)")
            self.voice.stop()
            self.engine.interrupt()
            self.interruptedAfter = self.spokenThisTurn.suffix(2).joined(separator: " ")
            self.userLine = text
            self.state = .listening
        }
        listener.onLevel = { [weak self] in self?.level = $0; self?.pushLevel($0) }
        AudioIO.shared.onOutputLevel = { [weak self] v in
            guard let self, self.state == .speaking else { return }
            self.outputLevel = v
            self.pushLevel(v)
        }
        listener.onFinish = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .heard(let text): self.send(text)
            case .nothing: self.state = .idle
            case .failed(let msg): self.state = .error(msg)
            }
        }
    }

    var isActive: Bool { engine.isRunning }

    func prepare(_ message: String) {
        reset()
        state = .preparing(message)
        askPermissionsEarly()
    }

    /// Start the conversation with today's brief and the raw digest it was written from.
    func begin(briefMarkdown: String, rawContext: String, snapshot: Date = Date()) {
        reset()
        if Settings.useElevenLabs, !ElevenLabs.isConfigured {
            // You picked an ElevenLabs voice but the key is gone: say so instead of quietly sounding worse.
            notice = "ElevenLabs key not set, so this is the Mac voice. Add your key in Control Panel → Voice."
        } else if !ElevenLabs.isConfigured, !StreamingVoice.hasNaturalVoice {
            notice = "Tip: add an ElevenLabs API key in Settings, or download a Premium voice (System Settings → Accessibility → Spoken Content → Manage Voices), so I sound less robotic."
        }
        askPermissionsEarly()
        startAudioIfAllowed()
        listener.vocabulary = Vocabulary.from(briefMarkdown + "\n" + rawContext.prefix(40_000))
        do {
            repos = LiveChecks.discover()
            AppLog().info("live checks: \(repos.map { $0.slug ?? $0.name }.joined(separator: ", "))")
            try engine.start(systemPrompt: ConversationPrompt.system(briefMarkdown: briefMarkdown, rawContext: rawContext,
                                                                     snapshot: snapshot, repos: repos),
                             repos: repos)
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        Speaker.shared.stop()
        state = .thinking
        turnDone = false
        engine.ask("[start]")
    }

    // MARK: User input

    /// The orb: interrupts while it's talking, ends your turn while listening, starts listening otherwise.
    func tapOrb() {
        switch state {
        case .speaking, .thinking, .checking: listen()
        case .listening: listener.finish()
        case .idle, .error: listen()
        case .preparing: break
        }
    }

    func listen() {
        guard isActive else { return }
        if voice.isSpeaking { interruptedAfter = spokenThisTurn.suffix(2).joined(separator: " ") }
        voice.stop()
        engine.interrupt()
        guard micAllowed else {
            Listener.requestPermissions { [weak self] err in
                guard let self else { return }
                if let err { self.state = .error(err) } else { self.micAllowed = true; self.listen() }
            }
            return
        }
        userLine = ""
        state = .listening
        listener.start()   // promotes the interruption watcher if it's already running
    }

    /// The shared echo-cancelled engine, so the mic can stay open while it talks.
    private func startAudioIfAllowed() {
        guard Settings.handsFree else { return }
        Listener.requestPermissions { [weak self] err in
            guard let self, err == nil else { return }
            self.micAllowed = true
            do { try AudioIO.shared.start() } catch { AppLog().info("audio engine failed: \(error.localizedDescription)") }
        }
    }

    func submitTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        listener.cancel()
        send(t)
    }

    func send(_ text: String) {
        voice.stop()
        if listener.isListening { listener.cancel() }
        var message = text
        if let cut = interruptedAfter, !text.hasPrefix("[") {
            message = "[Interrupted: they cut in while you were saying: \"\(cut)\"] " + text
        }
        interruptedAfter = nil
        spokenThisTurn = []
        assistantOpen = false
        if !text.hasPrefix("[") { messages.append(ChatLine(role: .user, text: text)) }
        userLine = text
        actions = []
        chunker = SpeechChunker()
        turnDone = false
        lastReply = ""
        state = .thinking
        engine.ask(message)
    }

    func perform(_ a: SpeechChunker.Action) {
        switch a.kind {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.payload, forType: .string)
            notice = "Copied “\(a.label)” to your clipboard."
        case .open:
            if let url = URL(string: a.payload) { NSWorkspace.shared.open(url) }
        case .claude, .claudeStart:
            startJob(a)
        case .remember:
            IntakePlanner.addRule(a.payload)
            notice = "Got it. From tomorrow's brief: \(a.payload)"
        case .recheck:
            recheck(a)
        }
    }

    /// "Check Azure again": a fresh read-only check, run the same way the brief gathers it (Claude in that repo with
    /// its own setup, or Codex for email/calendar). Runs in the background; the answer is spoken when it lands.
    private func recheck(_ a: SpeechChunker.Action) {
        let parts = a.payload.components(separatedBy: "::")
        let target = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let question = parts.dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let repo = repos.first { $0.name.lowercased() == target || ($0.slug?.lowercased() == target) }
        let engine = target == "codex" ? "codex" : "claude"
        let folder = repo?.path ?? Settings.claudeWorkDir.path
        let source = Gather.Source(id: "live:\(UUID().uuidString.prefix(8))", name: a.label, folder: folder,
                                   question: Gather.readOnlyRule
                                       + (engine == "codex" ? "\nUse your connected apps/connectors only; never a browser, computer use or screen control."
                                                            : "\nIf a connector can't reach something, try the signed-in CLI that covers it, read-only, before giving up.")
                                       + "\n" + question + "\nAnswer in plain text under 1500 characters.",
                                   engine: engine)
        liveChecks += 1
        notice = "Checking \(a.label) live (\(engine == "codex" ? "Codex" : "Claude")\(repo.map { " in \($0.name)" } ?? ""))… about a minute."
        AppLog().info("live re-check: \(a.label) via \(engine) in \(repo?.name ?? "neutral folder")")
        let since = BriefEngine.window().0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let answer = Gather.Run(sources: [source], since: since, timeout: 240).wait().first
            DispatchQueue.main.async {
                guard let self else { return }
                self.liveChecks -= 1
                if self.liveChecks == 0 { self.notice = nil }
                let body = answer?.text ?? "couldn't check: \(answer?.error ?? "no answer")"
                AppLog().info("live re-check done: \(a.label) in \(Int(answer?.seconds ?? 0))s, ok: \(answer?.text != nil)")
                self.pendingReports.append("[Live check] \(a.label), checked just now (\(Dates.time.string(from: Date()))): \(Secrets.redact(body))")
                if self.state == .idle || self.isError { self.flushReports() }
            }
        }
    }
    private var liveChecks = 0

    /// "repo :: task" → a background Claude Code job in a fresh worktree of that repo.
    private func startJob(_ a: SpeechChunker.Action) {
        guard Settings.handoffEnabled else { notice = "Handing work to Claude is switched off in the control panel."; return }
        let parts = a.payload.components(separatedBy: "::")
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let task = parts.dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repo = repos.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.slug?.caseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "I couldn't find a repo called “\(name)” to hand this to."
            return
        }
        do {
            let job = try ClaudeJobs.shared.start(repo: repo, title: a.label, task: task)
            notice = "Claude is working on “\(job.title)” in \(repo.name) (worktree \(job.worktreeName)). I'll tell you when it's done."
            actions.removeAll { $0.id == a.id }
        } catch {
            notice = "Couldn't start Claude: \(error.localizedDescription)"
        }
    }

    /// A background job ended: let Claude tell you about it as soon as the conversation is free.
    func report(_ job: ClaudeJobs.Job) {
        let msg = """
        [Job finished] repo: \(job.repo); task: \(job.title); status: \(job.status.rawValue); branch: \(job.branch ?? "unknown"); \
        changes: \(job.changes ?? "unknown"); took \(Int((job.finished ?? Date()).timeIntervalSince(job.started) / 60)) min; \
        Claude's summary: \(job.summary ?? "none")
        """
        pendingReports.append(msg)
        if state == .idle || isError { flushReports() }
    }

    private var isError: Bool { if case .error = state { return true }; return false }

    @discardableResult
    private func flushReports() -> Bool {
        guard isActive, !pendingReports.isEmpty else { return false }
        let msg = pendingReports.removeFirst()
        send(msg)
        userLine = ""
        return true
    }

    func close() {
        listener.cancel()
        voice.stop()
        engine.stop()
        AudioIO.shared.stop()
        state = .idle
        onClose()
    }

    // MARK: Claude events

    private func handle(_ e: ConversationEngine.Event) {
        switch e {
        case .delta(let text):
            let (sentences, acts) = chunker.feed(text)
            speak(sentences)
            take(acts)
        case .turnDone(let text, let interrupted):
            let (sentences, acts) = chunker.flush()
            if !interrupted { speak(sentences); take(acts) }
            lastReply = text
            turnDone = true
            if !voice.isSpeaking, state != .listening { afterReply() }
        case .checking(let what):
            AppLog().info("live check: \(what)")
            if !voice.isSpeaking, state != .listening { state = .checking(what) }
        case .failed(let msg):
            turnDone = true
            voice.stop()
            state = .error(msg)
        }
    }

    /// Buttons, except claude-start, which you already said yes to: that one just starts.
    private func take(_ acts: [SpeechChunker.Action]) {
        for a in acts {
            if a.kind == .claudeStart || a.kind == .remember || a.kind == .recheck { perform(a) } else { actions.append(a) }
        }
    }

    private func speak(_ sentences: [String]) {
        guard state != .listening else { return }
        for s in sentences where !s.isEmpty {
            voice.say(s)
            state = .speaking
        }
        // Keep listening while it talks, so you can just cut in.
        if Settings.handsFree, !micMuted, micAllowed, AudioIO.shared.running, !sentences.isEmpty, !listener.isListening {
            listener.start(bargeIn: true)
        }
    }

    private func afterReply() {
        guard state != .listening else { return }
        if flushReports() { return }
        // Hands-free: when it finishes, the interruption watcher becomes your turn (quietly ends after a few seconds).
        if listener.isListening, listener.bargeInMode {
            if Settings.autoListen, !micMuted { listener.promote(); userLine = ""; state = .listening } else { listener.cancel(); state = .idle }
            return
        }
        let endsInQuestion = lastReply.components(separatedBy: "\n").filter { !$0.hasPrefix("ACTION:") }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        if Settings.autoListen, endsInQuestion, micAllowed { listen() } else { state = .idle }
    }

    private func reset() {
        messages = []; assistantOpen = false; outputLevel = 0
        listener.cancel()
        voice.stop()
        caption = ""; previousCaption = ""; userLine = ""; actions = []; notice = nil; typed = ""
        chunker = SpeechChunker()
    }

    private func askPermissionsEarly() {
        guard !permissionsAsked else { return }
        permissionsAsked = true
        Listener.requestPermissions { [weak self] err in
            self?.micAllowed = (err == nil)
            if let err { self?.notice = err }
        }
    }
}

// MARK: - Window

/// Borderless, see-through floating panel pinned to the top centre of the screen.
final class VoicePanelController {
    let session = VoiceSession()
    private var panel: VoicePanel?
    private var leaving = false

    var isVisible: Bool { panel?.isVisible == true && !leaving }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show() {
        if panel == nil {
            let p = VoicePanel()
            p.onEscape = { [weak self] in self?.session.close() }
            p.onSpace = { [weak self] in self?.session.tapOrb() }
            let host = NSHostingView(rootView: VoiceView(session: session) { [weak self] size in self?.resize(to: size) })
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            p.contentView = host
            resize(to: host.fittingSize)
            session.onClose = { [weak self] in self?.dismiss() }
            panel = p
        }
        guard let panel else { return }
        if panel.isVisible && !leaving { panel.orderFrontRegardless(); panel.makeKey(); return }
        leaving = false
        arrive(panel)
        AppLog().info("voice panel shown at \(NSStringFromRect(panel.frame)) on \(NSScreen.main?.localizedName ?? "?")")
    }

    func hide() { session.close() }

    /// Springs up from below the screen to just above the Dock, as the orb; then the pill unfurls.
    private func arrive(_ panel: NSPanel) {
        session.expanded = false
        place()
        let rest = panel.frame
        if Settings.sounds { NSSound(named: "Pop")?.play() }
        if reduceMotion {
            panel.alphaValue = 0
            panel.orderFrontRegardless(); panel.makeKey()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
            session.expanded = true
            return
        }
        var start = rest
        start.origin.y -= rest.height + 40
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless(); panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.64, 1)   // a little overshoot
            panel.animator().setFrame(rest, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { self?.session.expanded = true }
        }
    }

    /// The pill folds back into the orb, which dips down and fades.
    private func dismiss() {
        guard let panel, panel.isVisible, !leaving else { panel?.orderOut(nil); return }
        leaving = true
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in self?.finishDismiss() })
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { session.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let panel = self.panel else { return }
            var end = panel.frame
            end.origin.y -= 70
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.finishDismiss() })
        }
    }

    private func finishDismiss() {
        guard leaving else { return }
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        leaving = false
    }

    /// The SwiftUI content reports its size; stay centred and grow upward from the bottom edge.
    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let had = panel.frame.height > 1
        var frame = panel.frame
        let midX = frame.midX
        frame.size = size
        if had { frame.origin.x = midX - size.width / 2 }   // bottom (origin.y) stays put
        panel.setFrame(frame, display: true)
        if !had { place() }
    }

    /// Bottom centre of the screen you're working on, just above the Dock.
    private func place() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 18))
    }
}

final class VoicePanel: NSPanel {
    var onEscape: () -> Void = {}
    var onSpace: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let typing = firstResponder is NSTextView
        switch Int(event.keyCode) {
        case kVK_Escape: onEscape()
        case kVK_Space where !typing: onSpace()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

// MARK: - SwiftUI

struct VoiceView: View {
    @ObservedObject var session: VoiceSession
    var onSize: (CGSize) -> Void = { _ in }
    @State private var typing = false
    @FocusState private var fieldFocused: Bool
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        // Sits at the bottom of the screen: the caption strip grows upward above the pill.
        VStack(spacing: 8) {
            if showsStrip && session.expanded { strip.transition(stripTransition) }
            pill
        }
        .frame(width: 460, alignment: .bottom)
        .padding(14)   // room for the glass shadow
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { onSize($0) }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82), value: showsStrip)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78), value: session.expanded)
    }

    private var stripTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom))
    }

    private var isError: Bool { if case .error = session.state { return true }; return false }
    private var showsStrip: Bool {
        !caption.isEmpty || !session.actions.isEmpty || session.notice != nil || isError || typing
    }

    /// One line, never a transcript: what you're saying while you talk, otherwise the sentence it's on.
    private var caption: String {
        if session.state == .listening { return session.userLine }
        if session.state == .speaking { return session.caption }
        return ""
    }

    private var orbState: OrbState {
        switch session.state {
        case .speaking: return .talking
        case .listening: return .listening
        case .thinking, .checking, .preparing: return .thinking
        case .idle, .error: return .idle
        }
    }

    private var barState: BarState {
        switch session.state {
        case .speaking: return .speaking
        case .listening: return .listening
        case .thinking, .checking: return .thinking
        case .preparing: return .connecting
        case .idle, .error: return .idle
        }
    }

    /// You're talking: the orb leans in (a touch bigger, with a glow).
    private var leaning: Bool { session.state == .listening && !session.userLine.isEmpty }

    private var orb: some View {
        Button { session.tapOrb() } label: {
            OrbView(state: orbState, inputLevel: session.level, outputLevel: session.outputLevel)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .scaleEffect(reduceMotion ? 1 : (leaning ? 1.14 : 1))
                .shadow(color: Color(hex: 0xA0B9D1).opacity(leaning ? 0.7 : 0), radius: leaning ? 10 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: leaning)
        }
        .buttonStyle(.plain)
        .help("Tap to talk or interrupt (Space)")
    }

    // Arriving / leaving: just the orb. Otherwise orb · status · bars · mute · type · brief · close.
    private var pill: some View {
        HStack(spacing: 10) {
            orb
            if session.expanded {
                Group {
                    status.lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    Spacer(minLength: 4)
                    if barState != .idle {
                        BarVisualizer(state: barState, levels: Array(session.levels.suffix(12)), barCount: 9, height: 18, barWidth: 3, gap: 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                    if session.isActive {
                        icon(session.micMuted ? "mic.slash" : "mic", on: session.micMuted,
                             help: session.micMuted ? "Unmute" : "Mute: don't listen while it talks") { session.micMuted.toggle() }
                        icon("keyboard", on: typing, help: "Type instead") {
                            typing.toggle()
                            if typing { DispatchQueue.main.async { fieldFocused = true } }
                        }
                    }
                    icon("doc.text", on: false, help: "Open the written brief") { session.onShowBrief() }
                    icon("xmark", on: false, help: "Close (Esc)") { session.close() }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, session.expanded ? 12 : 8).padding(.vertical, 8)
        .frame(maxWidth: session.expanded ? .infinity : nil)
        .glass(Capsule(), interactive: true)
        .animation(.easeOut(duration: 0.2), value: barState)
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .preparing(let s): ShimmeringText(text: s)
        case .thinking: ShimmeringText(text: "Thinking…")
        case .checking(let what): ShimmeringText(text: "Checking · " + what)
        case .speaking: Text("Speaking").font(.system(size: 13, weight: .medium))
        case .listening: Text("Listening…").font(.system(size: 13, weight: .medium))
        case .idle: Text(session.isActive ? (session.micMuted ? "Muted" : "Listening when you talk") : "Morning Context")
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        case .error: Text("Something went wrong").font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
        }
    }

    // A slim strip above the pill: the current line, buttons it offers, a notice, or a text box.
    private var strip: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .error(let msg) = session.state {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            if !caption.isEmpty {
                Group {
                    if session.state == .speaking {
                        SpokenCaption(text: caption, start: session.captionStart, duration: session.captionDuration)
                    } else {
                        Text(caption).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .id(caption)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if !session.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(session.actions.enumerated()), id: \.element.id) { i, a in
                        Button { session.perform(a) } label: {
                            Label(a.label, systemImage: a.kind == .copy ? "doc.on.clipboard" : (a.kind == .open ? "arrow.up.right" : "hammer"))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .glass(Capsule(), interactive: true)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7).delay(Double(i) * 0.06), value: session.actions.count)
                    }
                }
            }
            if let n = session.notice {
                Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if typing && session.isActive {
                HStack(spacing: 8) {
                    TextField("Type a message…", text: $session.typed)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($fieldFocused)
                        .onSubmit { session.submitTyped() }
                    Button { session.submitTyped() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .background(Color.primary.opacity(session.typed.isEmpty ? 0.3 : 0.92), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(session.typed.isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
        .animation(.easeOut(duration: 0.18), value: caption)
    }

    private func icon(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(on ? Color.primary.opacity(0.1) : .clear, in: Circle())
                .foregroundStyle(on ? .primary : .secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The sentence being spoken, lit word by word in step with the voice (karaoke-style).
struct SpokenCaption: View {
    let text: String
    let start: Date
    let duration: Double

    var body: some View {
        TimelineView(.animation) { ctx in
            let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let p = min(1, max(0, ctx.date.timeIntervalSince(start) / max(0.4, duration)))
            let lit = Int((Double(words.count) * p).rounded(.up))
            words.enumerated().reduce(Text("")) { acc, e in
                acc + Text((e.offset == 0 ? "" : " ") + e.element)
                    .foregroundColor(e.offset < lit ? .primary : .primary.opacity(0.35))
            }
            .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }
}

// MARK: - Global hotkey (⌃⌥M): summon the companion or talk, from anywhere

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: () -> Void = {}
    private static var installed = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x4D43_5458), id: 1)  // "MCTX"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
