import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var briefWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let model = BriefModel()
    private var isGenerating = false
    private var pollTimer: Timer?
    private let log = AppLog()
    private let voice = VoicePanelController()
    private var hotKey: HotKey?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupEditMenu()
        model.onRegenerate = { [weak self] in self?.generateAndShow(reason: "manual") }
        voice.session.onShowBrief = { [weak self] in self?.showTodayOrGenerate() }
        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { [weak self] in self?.hotKeyPressed() }
        ClaudeJobs.shared.onFinished = { [weak self] job in self?.jobFinished(job) }
        observeWakeEvents()

        // Poll as a safety net: handles laptops that never sleep, and the first run after install.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.maybeShowMorningBrief(reason: "poll")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            // First run: welcome first; nothing reads, sends or talks until you press Start.
            if Settings.onboarded { self?.maybeShowMorningBrief(reason: "launch") } else { self?.showSettings() }
        }
    }

    /// morningcontext://talk · morningcontext://brief — for Shortcuts, Raycast, Stream Deck…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "morningcontext" {
            log.info("url \(url.absoluteString)")
            switch url.host {
            case "brief": showTodayOrGenerate()
            case "settings", "panel": showSettings()
            case "regenerate": generateAndShow(reason: "url-regenerate", silent: true)
            default: talkNow()
            }
        }
    }

    // MARK: Wake / lid-open detection

    private func observeWakeEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        // Lid open → system wake. Fire a few seconds later so the display, Wi-Fi and disks are back.
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log.info("didWake")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self?.maybeShowMorningBrief(reason: "didWake") }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log.info("screensDidWake")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.maybeShowMorningBrief(reason: "screensDidWake") }
        }
        // Best moment of all: right after you unlock — you're definitely looking at the screen.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.log.info("screenIsUnlocked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.maybeShowMorningBrief(reason: "unlock") }
        }
    }

    /// Once per calendar day after `startHour`: prepare the brief silently in the background, then present it
    /// the moment it's ready and you're at the Mac (or at your next unlock if you've walked away).
    private func maybeShowMorningBrief(reason: String) {
        guard Settings.onboarded else { return }
        let today = Dates.dayKey.string(from: Date())
        if let pending = pendingPresentation {
            if pending.dayKey == today, userIsPresent { present(pending, talk: Settings.talkOnMorning) }
            return
        }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= Settings.startHour else { log.info("skip (\(reason)): before start hour"); return }
        guard Settings.lastBriefDate != today else { return }
        log.info("morning brief triggered by \(reason)")
        Settings.lastBriefDate = today   // claim the day immediately so parallel triggers don't double-fire
        generateAndShow(reason: reason, talk: Settings.talkOnMorning, silent: true)
    }

    /// A brief that finished while you were away; shown at your next unlock / wake.
    private var pendingPresentation: BriefEngine.Brief?

    /// Screen unlocked and touched in the last few minutes.
    private var userIsPresent: Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return !locked && idle < 300
    }

    private func present(_ brief: BriefEngine.Brief, talk: Bool) {
        pendingPresentation = nil
        if talk {
            voice.show()
            voice.session.begin(briefMarkdown: brief.markdown, rawContext: brief.rawContext, snapshot: brief.generatedAt)
        } else {
            showBriefWindow()
            if Settings.autoSpeak { Speaker.shared.speak(brief.spokenScript) }
        }
    }

    // MARK: Generation

    /// `talk`: open the glass voice pill and talk it through, instead of the brief window.
    /// `silent`: nothing on screen while it prepares (only the menu-bar icon); present when done.
    private func generateAndShow(reason: String, talk: Bool = false, silent: Bool = false) {
        guard !isGenerating else {
            if !silent { talk ? voice.show() : showBriefWindow() }
            return
        }
        Speaker.shared.stop()
        isGenerating = true
        model.phase = .collecting
        model.title = "Morning brief — \(Dates.longDay.string(from: Date()))"
        model.sourcesLine = "Collecting…"
        if !silent {
            if talk {
                voice.session.prepare("Reading yesterday…")
                voice.show()
            } else {
                showBriefWindow()
            }
        }
        setStatusIcon(busy: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = BriefEngine.generate { phase in
                DispatchQueue.main.async {
                    self?.model.phase = phase
                    if case .gathering(let names) = phase { self?.statusItem.button?.toolTip = "Morning Context — checking \(names)…" }
                    if talk, !silent {
                        switch phase {
                        case .gathering(let names): self?.voice.session.prepare("Checking \(names)…")
                        case .summarizing: self?.voice.session.prepare("Writing your brief…")
                        default: break
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGenerating = false
                self.setStatusIcon(busy: false)
                switch result {
                case .success(let brief):
                    self.model.markdown = brief.markdown
                    self.model.spokenScript = brief.spokenScript
                    self.model.sourcesLine = "\(BriefEngine.windowLabel(brief.windowStart, brief.windowEnd)) · \(brief.sourcesLine)"
                    self.model.dayKey = brief.dayKey
                    if case .failed = self.model.phase {} else { self.model.phase = .done }
                    Settings.lastBriefDate = brief.dayKey
                    if silent {
                        if reason.hasPrefix("url") || reason.hasPrefix("menu") {
                            self.notify("Your brief is ready", "Press ⌃⌥M to talk it through, or open it from the menu bar.")
                        } else if self.userIsPresent {
                            self.present(brief, talk: talk)
                        } else {
                            self.log.info("brief ready; waiting for you to come back")
                            self.pendingPresentation = brief
                        }
                        return
                    }
                    if talk {
                        self.voice.session.begin(briefMarkdown: brief.markdown, rawContext: brief.rawContext, snapshot: brief.generatedAt)
                        return
                    }
                    if Settings.autoSpeak, !reason.hasPrefix("url") { Speaker.shared.speak(brief.spokenScript) }
                case .failure(let err):
                    self.model.phase = .failed(err.localizedDescription)
                    if silent { self.notify("Morning brief failed", err.localizedDescription); return }
                }
                self.showBriefWindow()
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \(Self.appleScriptString(body)) with title \(Self.appleScriptString(title))"]
        try? p.run()
    }

    // MARK: Windows

    private func showBriefWindow() {
        if briefWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Morning Context"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentViewController = NSHostingController(rootView: BriefView(model: model))
            w.center()
            w.setFrameAutosaveName("MorningContext.BriefWindow")
            briefWindow = w
        }
        briefWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showTodayOrGenerate() {
        let today = Dates.dayKey.string(from: Date())
        if model.markdown.isEmpty, let saved = BriefStore.load(dayKey: today) {
            model.markdown = saved.0
            model.spokenScript = saved.1
            model.dayKey = today
            model.title = "Morning brief — \(Dates.longDay.string(from: Date()))"
            model.sourcesLine = "Loaded from disk"
            model.phase = .done
            showBriefWindow()
        } else if model.markdown.isEmpty {
            generateAndShow(reason: "menu")
        } else {
            showBriefWindow()
        }
    }

    private let panelModel = ControlPanelModel()

    /// The control panel: every source and its live status, voice, Claude jobs, schedule.
    private func showSettings() {
        if settingsWindow == nil {
            panelModel.onTalk = { [weak self] in self?.talkNow() }
            panelModel.onPrepare = { [weak self] in self?.generateAndShow(reason: "menu-prepare", silent: true) }
            panelModel.onShowBrief = { [weak self] in self?.showTodayOrGenerate() }
            panelModel.onFinishSetup = { [weak self] start in
                guard let self, start else { return }
                Settings.lastBriefDate = Dates.dayKey.string(from: Date())
                self.generateAndShow(reason: "first-run", talk: Settings.talkOnMorning)
            }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Morning Context"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = false
            w.backgroundColor = .clear
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ControlPanelView(model: panelModel))
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            w.contentView = GlassWindow.wrap(host)
            w.setFrameAutosaveName("MorningContext.ControlPanel")
            if w.frame.width < 900 { w.setContentSize(NSSize(width: 1040, height: 720)) }
            w.center()
            settingsWindow = w
        }
        panelModel.refresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar

    /// A menu-bar-only app has no main menu, and without an Edit menu ⌘V/⌘C/⌘A do nothing in text fields
    /// (Settings, the voice pill). This invisible main menu provides those shortcuts.
    private func setupEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(busy: false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Talk to Me  (⌃⌥M)", action: #selector(menuTalk), keyEquivalent: "t")
        let jobsItem = NSMenuItem(title: "Claude Jobs", action: nil, keyEquivalent: "")
        let jobsMenu = NSMenu(title: "Claude Jobs")
        jobsMenu.delegate = self
        jobsItem.submenu = jobsMenu
        menu.addItem(jobsItem)
        menu.addItem(withTitle: "Show Today's Brief", action: #selector(menuShow), keyEquivalent: "b")
        menu.addItem(withTitle: "Regenerate Now", action: #selector(menuRegenerate), keyEquivalent: "r")
        menu.addItem(withTitle: "Read Brief Aloud", action: #selector(menuSpeak), keyEquivalent: "p")
        menu.addItem(withTitle: "Stop Speaking", action: #selector(menuStopSpeaking), keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check Sources…", action: #selector(menuCheckSources), keyEquivalent: "")
        menu.addItem(withTitle: "Open Briefs Folder", action: #selector(menuOpenFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Control Panel…", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Morning Context", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    private func setStatusIcon(busy: Bool) {
        let img = NSImage(systemSymbolName: busy ? "sunrise" : "sunrise.fill", accessibilityDescription: "Morning Context")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = busy ? "Morning Context — generating brief…" : "Morning Context"
    }

    @objc private func menuShow() { showTodayOrGenerate() }

    // MARK: Claude jobs

    /// Tell you when handed-off work is done: by voice if the companion is open, otherwise a notification.
    private func jobFinished(_ job: ClaudeJobs.Job) {
        if voice.session.isActive {
            voice.show()
            voice.session.report(job)
        } else {
            let title = "Claude \(job.status == .done ? "finished" : job.status.rawValue) in \(job.repo)"
            let body = "\(job.title) · \(job.changes ?? "") · branch \(job.branch ?? "?")"
            let script = "display notification \(Self.appleScriptString(body)) with title \(Self.appleScriptString(title)) sound name \"Glass\""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        }
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Rebuilt every time the Claude Jobs submenu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Claude Jobs" else { return }
        menu.removeAllItems()
        let jobs = ClaudeJobs.shared.jobs.prefix(12)
        if jobs.isEmpty {
            menu.addItem(withTitle: "No jobs yet. Ask the voice companion to get Claude on something.", action: nil, keyEquivalent: "")
            return
        }
        for job in jobs {
            let icon = ["running": "●", "done": "✓", "failed": "✕", "stopped": "■"][job.status.rawValue] ?? "•"
            let mins = Int((job.finished ?? Date()).timeIntervalSince(job.started) / 60)
            let item = NSMenuItem(title: "\(icon) \(job.repo) — \(job.title)  (\(mins)m)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(withTitle: job.isRunning ? (job.lastActivity ?? "Working…") : (job.changes ?? job.status.rawValue), action: nil, keyEquivalent: "")
            sub.addItem(.separator())
            func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
                let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: "")
                i.target = self; i.representedObject = job.id
                sub.addItem(i)
            }
            add("Open in Terminal (resume Claude)", #selector(jobOpenTerminal(_:)), enabled: job.worktreePath != nil)
            add("Reveal Worktree in Finder", #selector(jobReveal(_:)), enabled: job.worktreePath != nil)
            add("Copy Branch Name", #selector(jobCopyBranch(_:)), enabled: job.branch != nil || job.worktreePath != nil)
            if job.isRunning { add("Stop", #selector(jobStop(_:))) }
            item.submenu = sub
            menu.addItem(item)
        }
    }

    private func job(_ sender: NSMenuItem) -> ClaudeJobs.Job? {
        ClaudeJobs.shared.jobs.first { $0.id == sender.representedObject as? String }
    }
    @objc private func jobOpenTerminal(_ s: NSMenuItem) { if let j = job(s) { ClaudeJobs.shared.openInTerminal(j) } }
    @objc private func jobReveal(_ s: NSMenuItem) {
        if let p = job(s)?.worktreePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
    }
    @objc private func jobCopyBranch(_ s: NSMenuItem) {
        guard let j = job(s) else { return }
        let branch = j.branch ?? j.worktreePath.flatMap { ClaudeJobs.git(["-C", $0, "rev-parse", "--abbrev-ref", "HEAD"]) } ?? ""
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(branch, forType: .string)
    }
    @objc private func jobStop(_ s: NSMenuItem) { if let j = job(s) { ClaudeJobs.shared.stop(j.id) } }
    @objc private func menuTalk() { talkNow() }

    /// ⌃⌥M from anywhere: open the companion, or — if it's already up — talk / interrupt.
    private func hotKeyPressed() {
        if voice.isVisible, voice.session.isActive { voice.session.tapOrb() } else { talkNow() }
    }

    /// Talk about today's brief; writes it first if there isn't one yet.
    private func talkNow() {
        log.info("talk requested (active: \(voice.session.isActive))")
        if voice.session.isActive { voice.show(); return }
        let today = Dates.dayKey.string(from: Date())
        guard !isGenerating, let saved = BriefStore.load(dayKey: today) else {
            generateAndShow(reason: "talk", talk: true)
            return
        }
        Speaker.shared.stop()
        voice.show()
        voice.session.begin(briefMarkdown: saved.0, rawContext: BriefStore.loadContext(dayKey: today) ?? "",
                            snapshot: BriefStore.generatedAt(dayKey: today) ?? Date())
    }
    @objc private func menuRegenerate() { generateAndShow(reason: "menu-regenerate", silent: true) }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuStopSpeaking() { Speaker.shared.stop() }
    @objc private func menuSpeak() {
        let today = Dates.dayKey.string(from: Date())
        if model.spokenScript.isEmpty, let saved = BriefStore.load(dayKey: today) {
            model.markdown = saved.0; model.spokenScript = saved.1; model.dayKey = today; model.phase = .done
        }
        if model.spokenScript.isEmpty { generateAndShow(reason: "menu-speak"); return }
        Speaker.shared.speak(model.spokenScript)
    }
    @objc private func menuOpenFolder() { NSWorkspace.shared.open(Settings.briefsDir) }

    /// Quick diagnostic so you can see what the app can and can't find — no AI involved.
    @objc private func menuCheckSources() {
        let (from, to) = BriefEngine.window()
        DispatchQueue.global().async {
            let claude = ClaudeCodeReader.digest(from: from, to: to, charBudget: 50_000)
            let wispr = WisprFlowReader.digest(from: from, to: to, charBudget: 50_000)
            let files = TranscriptFolderReader.digest(from: from, to: to, charBudget: 50_000)
            let claudeDirExists = FileManager.default.fileExists(atPath: Settings.claudeProjectsDir.path)

            var lines: [String] = ["Window: \(BriefEngine.windowLabel(from, to))", ""]
            lines.append("Claude Code  \(Settings.claudeProjectsDir.path)")
            lines.append(claudeDirExists ? "  ✓ found · \(claude.filesScanned) session files touched · \(claude.sessions.count) sessions with activity in window · \(claude.skippedAutomated) automated (claude -p) runs skipped" : "  ✗ folder not found")
            lines.append("")
            lines.append("Wispr Flow   \(Settings.wisprDBPath)")
            if let e = wispr.error { lines.append("  ✗ \(e)") } else {
                lines.append("  ✓ found · \(wispr.meetings.count) meetings · \(wispr.notes.count) notes · \(wispr.entries.count) dictations in window · \(wispr.today.count) calendar events today")
            }
            if let d = Settings.extraTranscriptsDir {
                lines.append(""); lines.append("Transcripts  \(d)"); lines.append("  \(files.files) files in window")
            }
            lines.append("")
            lines.append("Summaries use the `claude` CLI from your login shell. Briefs are saved to:\n\(Settings.briefsDir.path)")

            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Morning Context — sources"
                a.informativeText = lines.joined(separator: "\n")
                a.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        }
    }
}

// MARK: - Launch at login (macOS 13+)

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoginItem error: \(error)")
        }
    }
}

// MARK: - Tiny file logger (~/Library/Application Support/MorningContext/app.log)

struct AppLog {
    private let url = Settings.appSupportDir.appendingPathComponent("app.log")
    func info(_ s: String) {
        let line = "\(Dates.dayTime.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        NSLog("MorningContext: %@", s)
    }
}
