import SwiftUI
import AppKit

// MARK: - Status of every source, measured on this Mac

/// Everything the control panel shows, computed off the main thread from the same readers the brief uses.
final class ControlPanelModel: ObservableObject {

    struct SourceCard: Identifiable {
        enum State { case connected, found, off, failing, waiting }
        let id: String
        let name: String
        var subtitle: String = ""
        let icon: String          // SF Symbol
        let tint: Color
        var state: State
        var pill: String
        var detail: String
        var via: String           // how it's reached: "reads local files", "asks Claude", "asks Codex"
        var toggle: Binding<Bool>?
    }

    @Published var cards: [SourceCard] = []
    @Published var stats: [(String, String)] = []
    @Published var nextBrief = ""
    @Published var loading = false
    @Published var jobs: [ClaudeJobs.Job] = []
    @Published var plan: IntakePlanner.Plan?

    var onTalk: () -> Void = {}
    var onPrepare: () -> Void = {}
    var onShowBrief: () -> Void = {}

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (from, to) = BriefEngine.window()
            let claude = ClaudeCodeReader.digest(from: from, to: to, charBudget: 1)
            let wispr = Settings.wisprEnabled ? WisprFlowReader.digest(from: from, to: to, charBudget: 1)
                                              : WisprFlowReader.Result(dbFound: FileManager.default.fileExists(atPath: Settings.wisprDBPath))
            let codex = CodexReader.digest(from: from, to: to, charBudget: 1)
            let automations = CodexReader.automationNames()
            let plan = IntakePlanner.lastPlan()
            // With a plan, the fixed tracker cards are only the fallback; the plan section shows what really ran.
            let gather = (Settings.plannerEnabled && plan != nil) ? [] : Gather.detect(includeDisabled: true)
            let last = Gather.loadStatus()
            let ghUser = Self.run("/opt/homebrew/bin/gh", ["config", "get", "-h", "github.com", "user"]) ?? Self.run("/usr/local/bin/gh", ["config", "get", "-h", "github.com", "user"])
            let repos = LiveChecks.discover()

            DispatchQueue.main.async {
                self.plan = plan
                self.build(claude: claude, wispr: wispr, codex: codex, automations: automations,
                           gather: gather, last: last, ghUser: ghUser, repos: repos, window: (from, to))
                self.loading = false
            }
        }
    }

    private func build(claude: ClaudeCodeReader.Result, wispr: WisprFlowReader.Result, codex: CodexReader.Result,
                       automations: [String: String], gather: [Gather.Source], last: [String: Gather.LastRun],
                       ghUser: String?, repos: [LiveChecks.Repo], window: (Date, Date)) {
        let since = "since \(Dates.dayTime.string(from: window.0))"
        var c: [SourceCard] = []

        let repoCount = Set(claude.sessions.map(\.repo)).count
        c.append(SourceCard(id: "claude", name: "Claude Code", icon: "sparkle", tint: Color(red: 0.85, green: 0.47, blue: 0.34),
                            state: .connected, pill: "Connected",
                            detail: "\(claude.sessions.count) sessions in \(repoCount) repos \(since) · \(claude.skippedAutomated) automated runs skipped",
                            via: "Reads ~/.claude/projects", toggle: nil))

        let wisprOn = Settings.wisprEnabled
        c.append(SourceCard(id: "wispr", name: "Wispr Flow", icon: "waveform", tint: Color(red: 0.42, green: 0.36, blue: 1),
                            state: !wisprOn ? .off : (wispr.dbFound ? .connected : .failing),
                            pill: !wisprOn ? "Off" : (wispr.dbFound ? "Connected" : "Not found"),
                            detail: wispr.dbFound ? "\(wispr.meetings.count) meetings · \(wispr.entries.count) dictations · \(wispr.notes.count) notes \(since)"
                                                  : "No Wispr Flow database at \(Settings.wisprDBPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))",
                            via: "Reads Wispr's local database", toggle: Self.binding(Settings.Key.wisprEnabled)))

        let codexFound = FileManager.default.fileExists(atPath: CodexReader.sessionsDir.path)
        let autos = codex.threads.filter(\.isAutomation)
        c.append(SourceCard(id: "codex", name: "Codex", icon: "circle.hexagongrid", tint: Color(white: 0.15),
                            state: !codexFound ? .off : (Settings.codexEnabled ? .connected : .found),
                            pill: !codexFound ? "Not installed" : (Settings.codexEnabled ? "Connected" : "Found on Mac"),
                            detail: "\(codex.threads.count - autos.count) sessions + \(autos.count) automation runs \(since) · \(automations.count) automations: \(automations.values.sorted().prefix(3).joined(separator: ", "))",
                            via: "Reads ~/.codex/sessions", toggle: Self.binding(Settings.Key.codexEnabled)))

        for s in gather {
            let run = last[s.id]
            let disabled = Settings.disabledGatherSources.contains(s.id) || !Settings.gatherEnabled
            let isGmail = s.id == "gmail"
            let state: SourceCard.State = disabled ? .off : (run == nil ? .waiting : (run!.ok ? .connected : .failing))
            let pill = disabled ? "Off" : (run == nil ? "Next brief" : (run!.ok ? "Working" : "Failed last time"))
            var detail = run.map { r in
                "Last checked \(Dates.dayTime.string(from: r.at)) in \(Int(r.seconds))s" + (r.ok ? "" : ": \(r.error ?? "error")")
            } ?? "Will be checked when the next brief is prepared"
            if !isGmail { detail = "\(s.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · " + detail }
            let isAzure = s.name.hasPrefix("Azure")
            // "Azure Boards · atlas" → name + subtitle, so the card title never truncates.
            let parts = s.name.components(separatedBy: " · ")
            let title = isGmail ? "Gmail" : parts[0]
            let sub = isGmail ? (s.engine == "codex" ? "via Codex" : "via Claude") : parts.dropFirst().joined(separator: " · ")
            c.append(SourceCard(id: s.id, name: title, subtitle: sub, icon: isGmail ? "envelope.fill" : (isAzure ? "square.grid.3x3.fill" : "checklist"),
                                tint: isGmail ? Color(red: 0.92, green: 0.26, blue: 0.21) : (isAzure ? Color(red: 0, green: 0.47, blue: 0.83) : Color(red: 0, green: 0.32, blue: 0.8)),
                                state: state, pill: pill, detail: detail,
                                via: s.engine == "codex" ? "Asks Codex (read-only)" : "Asks Claude (read-only)",
                                toggle: Self.sourceBinding(s.id)))
        }

        c.append(SourceCard(id: "github", name: "GitHub", icon: "arrow.triangle.branch", tint: Color(white: 0.2),
                            state: ghUser == nil ? .failing : .connected, pill: ghUser == nil ? "gh not signed in" : "Live checks",
                            detail: ghUser.map { "via gh as \($0) · \(repos.compactMap(\.slug).count) repos · PRs, CI, reviews · read-only" } ?? "Run `gh auth login` in Terminal",
                            via: "Asked live, only when you say \"check again\"", toggle: nil))

        c.append(SourceCard(id: "folder", name: "Folder", subtitle: "transcripts & notes", icon: "folder.fill", tint: Color(white: 0.45),
                            state: Settings.extraTranscriptsDir == nil ? .off : .connected,
                            pill: Settings.extraTranscriptsDir == nil ? "Optional" : "Connected",
                            detail: Settings.extraTranscriptsDir.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Any folder of .md, .txt or .vtt notes/transcripts (set in Sources)",
                            via: "Reads local files", toggle: nil))
        cards = c

        let connected = c.filter { $0.state == .connected }.count
        let running = ClaudeJobs.shared.jobs.filter(\.isRunning).count
        stats = [
            ("\(connected) of \(c.count)", "sources working"),
            ("\(claude.sessions.count + codex.threads.count)", "Claude + Codex sessions \(since.replacingOccurrences(of: "since ", with: "since\n"))"),
            ("\(running) running", "Claude jobs"),
            (ElevenLabs.probablyConfigured ? ((Settings.defaults.string(forKey: Settings.Key.elevenLabsVoiceName) ?? "ElevenLabs")
                .components(separatedBy: " - ").first ?? "ElevenLabs") : "Mac voice",
             ElevenLabs.probablyConfigured ? "ElevenLabs voice" : "add ElevenLabs for a natural voice"),
        ]
        jobs = ClaudeJobs.shared.jobs
        let today = Dates.dayKey.string(from: Date())
        nextBrief = Settings.lastBriefDate == today
            ? "Today's brief is ready · next one tomorrow, the first time you're at your Mac after \(Settings.startHour):00"
            : "Next brief: the first time you're at your Mac after \(Settings.startHour):00"
    }

    private static func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { Settings.defaults.object(forKey: key) as? Bool ?? true },
                set: { Settings.defaults.set($0, forKey: key) })
    }

    private static func sourceBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !Settings.disabledGatherSources.contains(id) },
                set: { on in
                    var d = Set(Settings.disabledGatherSources)
                    if on { d.remove(id) } else { d.insert(id) }
                    Settings.disabledGatherSources = Array(d)
                })
    }

    private static func run(_ bin: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }
}

// MARK: - Window content

struct ControlPanelView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", sources = "Sources", voice = "Voice", jobs = "Claude jobs", schedule = "Schedule & brief"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "circle.grid.2x2.fill"
            case .sources: return "tray.and.arrow.down.fill"
            case .voice: return "waveform.circle.fill"
            case .jobs: return "hammer.fill"
            case .schedule: return "calendar.badge.clock"
            }
        }
    }

    @ObservedObject var model: ControlPanelModel
    @State private var section: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch section ?? .overview {
                case .overview: OverviewView(model: model)
                case .sources: SourcesSettingsView(model: model)
                case .voice: VoiceSettingsView()
                case .jobs: JobsView(model: model)
                case .schedule: ScheduleSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { model.refresh() }
    }
}

struct OverviewView: View {
    @ObservedObject var model: ControlPanelModel
    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting).font(.system(size: 26, weight: .bold))
                        Text(model.nextBrief).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.onPrepare() } label: { Label("Prepare brief now", systemImage: "arrow.clockwise") }
                        .help("Runs in the background; you'll get a notification when it's ready")
                    Button { model.onShowBrief() } label: { Label("Read brief", systemImage: "doc.text") }
                    Button { model.onTalk() } label: { Label("Talk now", systemImage: "mic.fill").padding(.horizontal, 4) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .keyboardShortcut("t", modifiers: .command)
                }

                HStack(spacing: 12) {
                    ForEach(Array(model.stats.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.0).font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(s.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
                    }
                }

                header("What it reads", trailing: model.loading ? "Checking…" : nil)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.cards) { card in SourceCardView(card: card, onChange: { model.refresh() }) }
                }

                if let plan = model.plan { PlanSection(plan: plan) }

                header("What it can do", trailing: nil)
                LazyVGrid(columns: columns, spacing: 12) {
                    AbilityCard(icon: "hammer.fill", tint: Color(red: 0.85, green: 0.47, blue: 0.34), title: "Hand off to Claude",
                                detail: "\"Get Claude on it\": background job in its own worktree branch, edits and tests, never pushes.",
                                key: Settings.Key.handoffEnabled)
                    AbilityCard(icon: "arrow.triangle.2.circlepath", tint: Color(white: 0.25), title: "Live GitHub checks",
                                detail: "Say \"check again\" for current PR, review and CI state. Read-only.", key: nil)
                    AbilityCard(icon: "doc.on.clipboard", tint: .purple, title: "Drafts to clipboard",
                                detail: "Replies and nudges as copy buttons; you send them yourself.", key: nil)
                }
            }
            .padding(24)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 17 ? "Good afternoon" : "Good evening")
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? part : "\(part), \(name)"
    }

    private func header(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            Spacer()
            if let t = trailing { ProgressView().controlSize(.small); Text(t).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.top, 4)
    }
}

/// What the brain decided to check this morning, why, and what came back.
struct PlanSection: View {
    let plan: IntakePlanner.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THIS MORNING'S CHECKS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Text("Planned by Claude at \(Dates.time.string(from: plan.at)) in \(Int(plan.planSeconds))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.checks) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.ok == true ? "checkmark.circle.fill" : (c.ok == false ? "xmark.circle.fill" : "circle.dotted"))
                            .foregroundStyle(c.ok == true ? .green : (c.ok == false ? .red : .secondary))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(c.title).font(.system(size: 13, weight: .semibold))
                                Text(c.engine == "codex" ? "Codex" : "Claude")
                                    .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                                if !c.folder.isEmpty {
                                    Text((c.folder as NSString).lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                                }
                                if let s = c.seconds { Text("\(Int(s))s").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            if !c.why.isEmpty { Text(c.why).font(.caption).foregroundStyle(.secondary) }
                            if let p = c.preview {
                                Text(p.collapsedWhitespace).font(.caption).lineLimit(2).foregroundStyle(.primary.opacity(0.8))
                            } else if let e = c.error {
                                Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    if c.id != plan.checks.last?.id { Divider().padding(.leading, 38) }
                }
            }
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
            if !plan.claudeReach.isEmpty || !plan.codexReach.isEmpty {
                Text("Claude could reach: \(plan.claudeReach.joined(separator: ", "))" +
                     (plan.codexReach.isEmpty ? "" : "   ·   Codex: \(plan.codexReach.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SourceCardView: View {
    let card: ControlPanelModel.SourceCard
    var onChange: () -> Void
    @State private var on = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: card.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(card.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    if !card.subtitle.isEmpty { Text(card.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(card.pill).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(pillColor).background(pillColor.opacity(0.16), in: Capsule())
            }
            Text(card.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(card.via).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let t = card.toggle {
                    Toggle("", isOn: Binding(get: { on }, set: { on = $0; t.wrappedValue = $0; onChange() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .onAppear { on = t.wrappedValue }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
    }

    private var pillColor: Color {
        switch card.state {
        case .connected: return .green
        case .found, .waiting: return .orange
        case .failing: return .red
        case .off: return .secondary
        }
    }
}

struct AbilityCard: View {
    let icon: String, tint: Color, title: String, detail: String
    let key: String?
    @State private var on = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let key {
                    Toggle("", isOn: Binding(get: { on }, set: { on = $0; Settings.defaults.set($0, forKey: key) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .onAppear { on = Settings.defaults.object(forKey: key) as? Bool ?? true }
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(13).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
    }
}

// MARK: - Sections

struct SourcesSettingsView: View {
    @ObservedObject var model: ControlPanelModel
    @AppStorage(Settings.Key.wisprDBPath) private var wisprDBPath = ""
    @AppStorage(Settings.Key.extraTranscriptsDir) private var extraDir = ""
    @AppStorage(Settings.Key.gatherEnabled) private var gatherEnabled = true
    @AppStorage(Settings.Key.codexEnabled) private var codexEnabled = true
    @AppStorage(Settings.Key.wisprEnabled) private var wisprEnabled = true
    @AppStorage(Settings.Key.plannerEnabled) private var plannerEnabled = true
    @AppStorage(Settings.Key.intakeRules) private var intakeRules = ""
    @State private var gatherSources: [Gather.Source] = []
    @State private var disabled = Set(Settings.disabledGatherSources)

    var body: some View {
        Form {
            Section("Read from this Mac") {
                LabeledContent("Claude Code") { Text("~/.claude/projects (always on)").foregroundStyle(.secondary) }
                Toggle("Codex sessions and automation runs (~/.codex)", isOn: $codexEnabled)
                Toggle("Wispr Flow meetings, notes and dictations", isOn: $wisprEnabled)
                TextField("Wispr Flow database", text: $wisprDBPath, prompt: Text(Settings.defaultWisprDBPath))
                TextField("Extra transcripts folder (optional)", text: $extraDir, prompt: Text("~/Documents/Meeting Notes"))
            }
            Section {
                Toggle("Ask Claude and Codex while preparing the brief", isOn: $gatherEnabled)
                Toggle("Let Claude decide what to check each morning", isOn: $plannerEnabled).disabled(!gatherEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your standing rules for the morning checks")
                    TextEditor(text: $intakeRules).font(.system(.body, design: .monospaced)).frame(minHeight: 70)
                    Text("One per line, e.g. \"Always check Render deploys for ramp-lab\" or \"Skip Hershey's task emails\". You can also say it in the voice pill: \"always check…\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!gatherEnabled || !plannerEnabled)
            } header: {
                Text("The brain")
            } footer: {
                Text("Each morning Claude reads what happened yesterday, looks at every connector and tool it and Codex have (anything you add later included), and plans 3–7 read-only checks. They run in parallel in the right repo or app, and what they found shapes the next morning's plan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(gatherSources) { s in
                    Toggle(isOn: Binding(get: { !disabled.contains(s.id) }, set: { on in
                        if on { disabled.remove(s.id) } else { disabled.insert(s.id) }
                        Settings.disabledGatherSources = Array(disabled)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text("\(s.engine == "codex" ? "Codex" : "Claude") in \(s.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!gatherEnabled)
                }
            } header: {
                Text(plannerEnabled ? "Fallback checks (used if planning fails)" : "Fixed checks")
            } footer: {
                Text("Found from your Claude Code history: Azure Boards / Jira are asked in the repo that uses them, Gmail through Codex. Read-only, while the brief is prepared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Prepare a brief now (in the background)") { model.onPrepare() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            DispatchQueue.global().async {
                let all = Gather.detect(includeDisabled: true)
                DispatchQueue.main.async { gatherSources = all }
            }
        }
        .onDisappear { model.refresh() }
    }
}

struct JobsView: View {
    @ObservedObject var model: ControlPanelModel
    @ObservedObject private var jobs = ClaudeJobs.shared

    var body: some View {
        Form {
            Section {
                if jobs.jobs.isEmpty {
                    Text("No jobs yet. In the voice pill, say \"get Claude to …\" in one of your repos.").foregroundStyle(.secondary)
                }
                ForEach(jobs.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: icon(job)).foregroundStyle(color(job))
                            Text("\(job.repo) — \(job.title)").font(.headline)
                            Spacer()
                            Text(Dates.dayTime.string(from: job.started)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(job.isRunning ? (job.lastActivity ?? "Working…") : (job.changes ?? job.status.rawValue))
                            .font(.caption).foregroundStyle(.secondary)
                        if let s = job.summary, !job.isRunning { Text(s).font(.caption).lineLimit(4) }
                        HStack {
                            Button("Open in Terminal") { ClaudeJobs.shared.openInTerminal(job) }.disabled(job.worktreePath == nil)
                            Button("Show worktree") {
                                if let p = job.worktreePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                            }.disabled(job.worktreePath == nil)
                            if job.isRunning { Button("Stop", role: .destructive) { ClaudeJobs.shared.stop(job.id) } }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Claude jobs")
            } footer: {
                Text("Each job runs in its own git worktree branch (repo/.claude/worktrees/morning-…), commits locally and never pushes. You review and ship it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func icon(_ j: ClaudeJobs.Job) -> String {
        switch j.status { case .running: return "circle.dotted"; case .done: return "checkmark.circle.fill"; case .failed: return "xmark.circle.fill"; case .stopped: return "stop.circle.fill" }
    }
    private func color(_ j: ClaudeJobs.Job) -> Color {
        switch j.status { case .running: return .orange; case .done: return .green; case .failed: return .red; case .stopped: return .secondary }
    }
}

struct ScheduleSettingsView: View {
    @AppStorage(Settings.Key.startHour) private var startHour = 4
    @AppStorage(Settings.Key.lookbackDays) private var lookbackDays = 1
    @AppStorage(Settings.Key.claudeModel) private var model = ""
    @AppStorage(Settings.Key.extraInstructions) private var extraInstructions = ""
    @AppStorage(Settings.Key.talkOnMorning) private var talkOnMorning = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Every morning") {
                Stepper("Earliest hour: \(startHour):00", value: $startHour, in: 0...12)
                Toggle("Talk me through it in the voice pill (otherwise open the written brief)", isOn: $talkOnMorning)
                Text("The brief is prepared silently in the background and appears once it's ready and you're at your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Brief") {
                Stepper("Look back \(lookbackDays) day\(lookbackDays == 1 ? "" : "s")", value: $lookbackDays, in: 1...7)
                TextField("Claude model (blank = default)", text: $model, prompt: Text("e.g. sonnet"))
                TextField("Extra instructions for the brief", text: $extraInstructions, axis: .vertical).lineLimit(2...5)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { LoginItem.set(enabled: $0) }
                LabeledContent("Briefs folder") {
                    Button("Open") { NSWorkspace.shared.open(Settings.briefsDir) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct VoiceSettingsView: View {
    @AppStorage(Settings.Key.autoSpeak) private var autoSpeak = true
    @AppStorage(Settings.Key.voiceIdentifier) private var voiceIdentifier = ""
    @AppStorage(Settings.Key.speechRate) private var speechRate = 0.5
    @AppStorage(Settings.Key.autoListen) private var autoListen = true
    @AppStorage(Settings.Key.handsFree) private var handsFree = true
    @AppStorage(Settings.Key.conversationModel) private var conversationModel = ""
    @AppStorage(Settings.Key.elevenLabsVoiceId) private var elevenVoiceId = ""
    @AppStorage(Settings.Key.pronunciations) private var pronunciations = Settings.defaultPronunciations
    @State private var elevenKey = ElevenLabs.apiKey
    @State private var elevenVoices: [ElevenLabs.Voice] = []
    @State private var elevenStatus = ""
    private static let tester = StreamingVoice()
    private let voices = Speaker.availableVoices()

    var body: some View {
        Form {
            Section("Conversation") {
                Toggle("Hands-free: interrupt by just talking (mic stays open while it speaks, echo-cancelled)", isOn: $handsFree)
                Toggle("Keep listening for a few seconds after it finishes", isOn: $autoListen)
                TextField("Conversation model", text: $conversationModel, prompt: Text("sonnet"))
                Text("Summon any time with ⌃⌥M. Tap the orb or press Space to interrupt, Esc to close.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ElevenLabs voice (recommended)") {
                SecureField("API key", text: $elevenKey, prompt: Text("Paste from elevenlabs.io → Profile → API keys"))
                    .onChange(of: elevenKey) { ElevenLabs.apiKey = $0; elevenStatus = "" }
                HStack {
                    Button("Load my voices") { loadVoices() }.disabled(elevenKey.isEmpty)
                    Picker("Voice", selection: $elevenVoiceId) {
                        Text(elevenVoices.isEmpty ? "Default (Rachel)" : "Choose…").tag("")
                        ForEach(elevenVoices) { v in Text(v.detail.isEmpty ? v.name : "\(v.name) · \(v.detail)").tag(v.id) }
                    }
                    .labelsHidden().disabled(elevenVoices.isEmpty)
                    .onChange(of: elevenVoiceId) { id in
                        Settings.defaults.set(elevenVoices.first { $0.id == id }?.name, forKey: Settings.Key.elevenLabsVoiceName)
                    }
                }
                HStack {
                    Button("Test voice") { test("Good morning. Your GitHub account is the blocker today, and Siobhan owes you three reviews.") }
                    Spacer()
                    Text(elevenStatus.isEmpty ? "Voices you add from the Voice Library or Voice Design show up here." : elevenStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Section("Pronunciation") {
                TextEditor(text: $pronunciations).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
                HStack {
                    Button("Hear them") {
                        test("Here's how I say your words: " + Pronunciation.rules(pronunciations).map(\.word).joined(separator: ", ") + ".")
                    }
                    Spacer()
                    Text("One per line: word = how to say it, e.g. Siobhan = Shiv-awn.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Mac voice (fallback)") {
                Toggle("Read the written brief aloud when it opens", isOn: $autoSpeak)
                Picker("Voice", selection: $voiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { v in Text("\(v.name) · \(v.language) · \(Speaker.qualityLabel(v))").tag(v.identifier) }
                }
                Slider(value: $speechRate, in: 0.35...0.65) { Text("Speed") }
            }
        }
        .formStyle(.grouped)
        .onAppear { if !elevenKey.isEmpty { loadVoices() } }
    }

    private func test(_ line: String) {
        Self.tester.stop(); Self.tester.resetCloud()
        Self.tester.onNotice = { elevenStatus = $0 }
        Self.tester.say(line)
    }

    private func loadVoices() {
        elevenStatus = "Loading voices…"
        ElevenLabs.listVoices(key: elevenKey) { result in
            switch result {
            case .success(let v):
                elevenVoices = v
                elevenStatus = "\(v.count) voices in your account."
                if let name = v.first(where: { $0.id == elevenVoiceId })?.name {
                    Settings.defaults.set(name, forKey: Settings.Key.elevenLabsVoiceName)
                }
            case .failure(let e): elevenStatus = e.localizedDescription
            }
        }
    }
}
