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
        voice.onSentenceStart = { [weak self] s in
            guard let self else { return }
            if !self.caption.isEmpty { self.previousCaption = self.caption }
            self.caption = s
            self.spokenThisTurn.append(s)
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
        listener.onLevel = { [weak self] in self?.level = $0 }
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
        if !ElevenLabs.isConfigured, !StreamingVoice.hasNaturalVoice {
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
        }
    }

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
            if a.kind == .claudeStart || a.kind == .remember { perform(a) } else { actions.append(a) }
        }
    }

    private func speak(_ sentences: [String]) {
        guard state != .listening else { return }
        for s in sentences where !s.isEmpty {
            voice.say(s)
            state = .speaking
        }
        // Keep listening while it talks, so you can just cut in.
        if Settings.handsFree, micAllowed, AudioIO.shared.running, !sentences.isEmpty, !listener.isListening {
            listener.start(bargeIn: true)
        }
    }

    private func afterReply() {
        guard state != .listening else { return }
        if flushReports() { return }
        // Hands-free: when it finishes, the interruption watcher becomes your turn (quietly ends after a few seconds).
        if listener.isListening, listener.bargeInMode {
            if Settings.autoListen { listener.promote(); userLine = ""; state = .listening } else { listener.cancel(); state = .idle }
            return
        }
        let endsInQuestion = lastReply.components(separatedBy: "\n").filter { !$0.hasPrefix("ACTION:") }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        if Settings.autoListen, endsInQuestion, micAllowed { listen() } else { state = .idle }
    }

    private func reset() {
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

    var isVisible: Bool { panel?.isVisible == true }

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
            session.onClose = { [weak self] in self?.panel?.orderOut(nil) }
            panel = p
        }
        place()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        AppLog().info("voice panel shown at \(panel.map { NSStringFromRect($0.frame) } ?? "-") on \(NSScreen.main?.localizedName ?? "?")")
    }

    func hide() { session.close() }

    /// The SwiftUI content reports its size; grow/shrink downward from the top edge.
    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let top = panel.frame.height > 1 ? panel.frame.maxY : nil
        var frame = panel.frame
        frame.size = size
        if let top { frame.origin.y = top - size.height }
        panel.setFrame(frame, display: true)
        if top == nil { place() }
    }

    /// Top centre of the screen you're working on (the one with the active window).
    private func place() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.maxY - size.height - 4))
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
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 8) {
            pill
            if showsCard { card.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .frame(width: 460)
        .padding(14)   // room for the glass shadow
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { onSize($0) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsCard)
        .animation(.easeOut(duration: 0.2), value: session.actions.count)
    }

    private var showsCard: Bool {
        !session.caption.isEmpty || !session.userLine.isEmpty || session.notice != nil || isError
    }

    private var isError: Bool { if case .error = session.state { return true }; return false }

    // The always-visible pill: orb · waveform · status · close
    private var pill: some View {
        HStack(spacing: 12) {
            Button { session.tapOrb() } label: { Orb(state: session.state, level: session.level) }
                .buttonStyle(.plain)
                .help("Tap to talk or interrupt (Space)")
            Waveform(state: session.state, level: session.level)
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { session.onShowBrief() } label: { Image(systemName: "doc.text") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the written brief")
            Button { session.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glass(Capsule(), interactive: true)
    }

    private var statusText: String {
        switch session.state {
        case .preparing(let s): return s
        case .thinking: return "Thinking…"
        case .checking(let what): return "Checking live · " + what
        case .speaking: return "Speaking · tap to interrupt"
        case .listening: return "Listening…"
        case .idle: return session.isActive ? "Tap the orb or press Space to talk" : "Morning Context"
        case .error: return "Something went wrong"
        }
    }

    // Captions, what you said, action chips, and a text box
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .error(let msg) = session.state {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !session.previousCaption.isEmpty {
                Text(session.previousCaption).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !session.caption.isEmpty {
                Text(session.caption)
                    .font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.userLine.isEmpty && session.userLine != "[start]" {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: session.state == .listening ? "mic.fill" : "person.fill").foregroundStyle(.secondary)
                    Text(session.userLine).font(.callout.weight(.semibold)).lineLimit(3)
                }
            }
            if !session.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.actions) { a in
                        Button { session.perform(a) } label: {
                            Label(a.label, systemImage: a.kind == .copy ? "doc.on.clipboard" : (a.kind == .open ? "arrow.up.right" : "hammer"))
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .glass(Capsule(), interactive: true)
                    }
                }
            }
            if let n = session.notice {
                Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if session.isActive {
                HStack(spacing: 8) {
                    TextField("Type instead…", text: $session.typed)
                        .textFieldStyle(.plain)
                        .focused($typing)
                        .onSubmit { session.submitTyped() }
                    Button { session.tapOrb() } label: {
                        Image(systemName: session.state == .listening ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glass(Capsule(), interactive: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A living gradient orb: swirls while thinking, pulses while speaking, follows your voice while listening.
struct Orb: View {
    let state: VoiceSession.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse: Double = {
                switch state {
                case .listening: return Double(level) * 0.35
                case .speaking: return 0.07 * sin(t * 7) + 0.03
                case .thinking, .preparing, .checking: return 0.04 * sin(t * 3)
                default: return 0
                }
            }()
            let spin: Double = { switch state { case .thinking, .preparing, .checking: return 180; case .idle: return 25; default: return 70 } }()
            ZStack {
                Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(t * spin)))
                    .blur(radius: 1.5)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 12))
            }
            .frame(width: 28, height: 28)
            .scaleEffect(1 + pulse)
            .shadow(color: colors[1].opacity(state == .idle ? 0.25 : 0.7), radius: 8 + pulse * 30)
        }
        .frame(width: 34, height: 34)
    }

    private var colors: [Color] {
        if case .error = state { return [.orange, .red, .pink] }
        if state == .listening { return [Color(red: 0.2, green: 0.8, blue: 1), Color(red: 0.45, green: 0.4, blue: 1), Color(red: 0.3, green: 1, blue: 0.75)] }
        return [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 1, green: 0.35, blue: 0.55), Color(red: 0.5, green: 0.42, blue: 1)]
    }
}

struct Waveform: View {
    let state: VoiceSession.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule().frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: 20)
            .foregroundStyle(.primary.opacity(active ? 0.85 : 0.3))
        }
    }

    private var active: Bool { state == .speaking || state == .listening }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let wobble = abs(sin(t * (5 + Double(i)) + Double(i) * 1.3))
        switch state {
        case .listening: return 4 + CGFloat(level) * 16 * CGFloat(0.4 + 0.6 * wobble)
        case .speaking: return 4 + 12 * CGFloat(wobble)
        default: return 4
        }
    }
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
