import Foundation

/// Sources Morning Context doesn't connect to itself: it asks Claude Code, which already can — your Jira via the
/// Atlassian connector, Azure Boards the way your repo's sessions already do it, Gmail via the Gmail connector. Each question
/// runs headless, read-only, in the repo it belongs to, while the brief is being prepared (never during a conversation).
enum Gather {

    struct Source: Codable, Equatable, Identifiable {
        var id: String          // stable key, e.g. "tracker:atlas"
        var name: String        // "Azure Boards · atlas"
        var folder: String      // where it runs (its project memory, settings and credentials apply)
        var question: String
        var engine: String = "claude"   // "claude" or "codex": whichever already has access
    }

    struct Answer {
        var source: Source
        var text: String?
        var error: String?
        var seconds: Double
    }

    // MARK: Which sources exist on this Mac

    /// Trackers come from evidence in your Claude Code history: a repo whose sessions talk to dev.azure.com gets an
    /// Azure Boards source; Atlassian/Jira usage gets a Jira source. Gmail is asked once, from a neutral folder.
    static func detect(repos: [LiveChecks.Repo] = LiveChecks.discover(), includeDisabled: Bool = false) -> [Source] {
        var out: [Source] = []
        for repo in repos {
            let hits = evidence(for: repo.path)
            if hits.azure >= 3 {
                let wiql = """
                Use WIQL, don't guess: [System.AssignedTo] = @Me AND [System.ChangedDate] >= '{SINCE_DATE}' for changes, \
                and [System.AssignedTo] = @Me AND [System.State] NOT IN ('Done','Closed','Removed') for the counts. \
                Read comments/updates only on the changed items.
                """
                out.append(Source(id: "tracker:\(repo.name)", name: "Azure Boards · \(repo.name)", folder: repo.path,
                                  question: trackerQuestion("Azure Boards (the Azure DevOps work items this project uses)", hint: wiql)))
            } else if hits.jira >= 2 {
                let keys = jiraProjectKeys(for: repo.path)
                let projects = keys.isEmpty ? "" : " Main project\(keys.count == 1 ? "" : "s"): \(keys.joined(separator: ", ")); the rest may be archives."
                let jql = """
                Search all projects with JQL, don't guess: (a) assignee = currentUser() AND updated >= "{SINCE_JQL}" ORDER BY updated DESC, \
                (b) assignee = currentUser() AND created >= "{SINCE_JQL}", (c) assignee = currentUser() AND resolution = Unresolved \
                for the counts. Read comments only on issues from (a).\(projects)
                """
                out.append(Source(id: "tracker:\(repo.name)", name: "Jira · \(repo.name)", folder: repo.path,
                                  question: trackerQuestion("Jira (via the Atlassian connector)", hint: jql)))
            }
        }
        // Gmail: Codex if your Codex automations already use Gmail (they send your outreach), else Claude's connector.
        let viaCodex = codexUsesGmail()
        out.append(Source(id: "gmail", name: viaCodex ? "Gmail (via Codex)" : "Gmail", folder: Settings.claudeWorkDir.path,
                          question: gmailQuestion, engine: viaCodex ? "codex" : "claude"))
        return includeDisabled ? out : out.filter { !Settings.disabledGatherSources.contains($0.id) }
    }

    /// Counts tracker fingerprints in the repo's recent Claude Code sessions (main checkout + worktrees).
    static func evidence(for repoPath: String, days: Int = 30) -> (azure: Int, jira: Int) {
        let prefix = repoPath.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var azure = 0, jira = 0
        let azureKey = Data("dev.azure.com".utf8)
        // Real Jira URLs only: connector tool *names* appear in every session's tool list, so they prove nothing.
        let jiraKeys = [Data("atlassian.net".utf8)]
        for dir in (try? fm.contentsOfDirectory(at: Settings.claudeProjectsDir, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix(prefix) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                guard let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= cutoff,
                      let data = try? Data(contentsOf: f, options: .mappedIfSafe) else { continue }
                if data.range(of: azureKey) != nil { azure += 1 }
                if jiraKeys.contains(where: { data.range(of: $0) != nil }) { jira += 1 }
                if azure >= 3 || jira >= 2 { return (azure, jira) }
            }
        }
        return (azure, jira)
    }

    /// The Jira project keys you actually work in ("INFRA"), from ticket ids in the repo's Claude sessions.
    static func jiraProjectKeys(for repoPath: String, days: Int = 30) -> [String] {
        let prefix = repoPath.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let notKeys: Set<String> = ["UTF", "ISO", "SHA", "AES", "PR", "GPT", "RFC", "HTTP", "TLS", "IPV", "MD", "COVID", "SPDX", "LTS"]
        guard let re = try? NSRegularExpression(pattern: "\\b([A-Z][A-Z0-9]{1,6})-[0-9]{1,5}\\b") else { return [] }
        var counts: [String: Int] = [:]
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: Settings.claudeProjectsDir, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix(prefix) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                guard let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= cutoff,
                      let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range(at: 1), in: text) { counts[String(text[r]), default: 0] += 1 }
                }
            }
        }
        let ranked = counts.filter { !notKeys.contains($0.key) && $0.value >= 20 }.sorted { $0.value > $1.value }
        guard let top = ranked.first?.value else { return [] }
        return ranked.filter { $0.value * 5 >= top }.prefix(3).map(\.key)   // keys within 5x of the most used
    }

    static func codexUsesGmail(days: Int = 14) -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let key = Data("codex_apps__gmail".utf8)
        guard let en = FileManager.default.enumerator(at: CodexReader.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= cutoff,
                  let data = try? Data(contentsOf: f, options: .mappedIfSafe) else { continue }
            if data.range(of: key) != nil { return true }
        }
        return false
    }

    // MARK: Questions

    static let readOnlyRule = """
    READ-ONLY briefing request from the user's morning assistant. Do not create, edit, move, assign, comment on, send, \
    draft, label, archive or delete anything, anywhere. Only look.
    """

    static func trackerQuestion(_ tracker: String, hint: String = "") -> String {
        """
        \(readOnlyRule)
        Using \(tracker), report for me (the current user) since {SINCE}. \(hint)
        1. Items assigned to me that changed: status moves, new comments (who wrote them and the gist), reassignments.
        2. Items newly assigned to me.
        3. Anything where someone is waiting on me (asked me a question, blocked on me, review or QA sitting with me).
        Then one line: how many other open items I have, by state.
        Be quick: at most 6 tool calls. Plain text, IDs and titles, no tables, under 2500 characters.
        If you can't reach the tracker, reply with one line saying exactly why.
        """
    }

    static let gmailQuestion = """
    \(readOnlyRule)
    Use your Gmail connector/app tools only; never a browser, computer use or screen control.
    Check my Gmail for mail received since {SINCE}:
    1. Replies from anyone I emailed recently, especially job applications and client/startup outreach (compare with \
    my Sent mail from the last two weeks).
    2. Emails from real people that need a reply or a decision from me.
    3. Anything urgent: security, billing, deadlines, interviews, meetings.
    Skip newsletters, notifications and marketing. For each: sender, subject, a one-line gist, and whether it needs a reply.
    Be quick: at most 8 tool calls. Plain text, no tables, under 2500 characters. If you can't reach Gmail, one line why.
    """

    // MARK: Running

    /// Starts every source in parallel; `wait()` collects the answers (sources still running at the deadline are stopped).
    final class Run {
        private var procs: [(Source, Process, Pipe, Date)] = []
        private let deadline: Date
        private var sources: [Source] = []

        init(sources: [Source], since sinceDate: Date, timeout: TimeInterval = 300) {
            deadline = Date().addingTimeInterval(timeout)
            self.sources = sources
            let since = Dates.dayTime.string(from: sinceDate) + " (\(TimeZone.current.identifier))"
            let model = Settings.claudeModel.trimmingCharacters(in: .whitespaces)
            for s in sources {
                guard let (bin, path) = try? ClaudeCLI.locate(s.engine) else { failures[s.id] = "`\(s.engine)` not found"; continue }
                let question = s.question.replacingOccurrences(of: "{SINCE}", with: since)
                    .replacingOccurrences(of: "{SINCE_JQL}", with: Gather.jqlFormatter.string(from: sinceDate))
                    .replacingOccurrences(of: "{SINCE_DATE}", with: Gather.dayFormatter.string(from: sinceDate))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.currentDirectoryURL = URL(fileURLWithPath: s.folder)
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path; env["CLAUDECODE"] = nil; env["TERM"] = "dumb"
                if s.engine == "codex" {
                    // Read-only sandbox; the answer is the last message, written to a file.
                    let answerFile = FileManager.default.temporaryDirectory.appendingPathComponent("mc-gather-\(UUID().uuidString).txt")
                    answerFiles[s.id] = answerFile
                    p.arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                                   "-o", answerFile.path, question]
                } else {
                    // Headless Claude attaches your claude.ai connectors (Atlassian, …) in the background; wait for them.
                    env["MCP_CONNECTOR_PREWAIT_MS"] = "20000"
                    env["MCP_CONNECTION_NONBLOCKING"] = "0"
                    p.arguments = ["-p", question, "--permission-mode", "auto", "--permission-prompts", "none",
                                   "--output-format", "json", "--no-session-persistence",
                                   "--disallowedTools", "Edit", "Write", "NotebookEdit",
                                   "--model", model.isEmpty ? "sonnet" : model]
                }
                p.environment = env
                let out = Pipe()
                p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                // Drain as we go so a large answer can't fill the pipe and stall Claude.
                var data = Data()
                let lock = NSLock()
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    lock.lock(); data.append(d); lock.unlock()
                }
                outputs[s.id] = { lock.lock(); defer { lock.unlock() }; return data }
                do { try p.run(); procs.append((s, p, out, Date())) } catch { failures[s.id] = error.localizedDescription }
            }
        }

        private var outputs: [String: () -> Data] = [:]
        private var answerFiles: [String: URL] = [:]
        private var failures: [String: String] = [:]

        /// Blocking; call from a background queue. `progress` gets the names still running.
        func wait(progress: ([String]) -> Void = { _ in }) -> [Answer] {
            var answers: [Answer] = []
            var pending = procs
            while !pending.isEmpty {
                progress(pending.map { $0.0.name })
                if Date() > deadline {
                    for (s, p, _, t) in pending {
                        p.terminate()
                        answers.append(Answer(source: s, text: nil, error: "took too long, skipped", seconds: Date().timeIntervalSince(t)))
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
                pending.removeAll { (s, p, out, t) in
                    guard !p.isRunning else { return false }
                    Thread.sleep(forTimeInterval: 0.1)
                    out.fileHandleForReading.readabilityHandler = nil
                    let secs = Date().timeIntervalSince(t)
                    if let file = answerFiles[s.id] {
                        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        try? FileManager.default.removeItem(at: file)
                        answers.append(Answer(source: s, text: text.isEmpty ? nil : text,
                                              error: text.isEmpty ? "Codex returned nothing (exit \(p.terminationStatus))" : nil, seconds: secs))
                    } else {
                        answers.append(Gather.answer(for: s, data: outputs[s.id]?() ?? Data(), seconds: secs))
                    }
                    return true
                }
            }
            for (id, err) in failures {
                if let s = sources.first(where: { $0.id == id }) { answers.append(Answer(source: s, text: nil, error: err, seconds: 0)) }
            }
            return answers
        }
    }

    static let jqlFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    static func answer(for s: Source, data: Data, seconds: Double) -> Answer {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Answer(source: s, text: nil, error: "no answer from Claude", seconds: seconds)
        }
        let text = (o["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (o["subtype"] as? String) != "success" || text.isEmpty {
            return Answer(source: s, text: nil, error: text.isEmpty ? "Claude returned nothing" : text.truncated(200), seconds: seconds)
        }
        return Answer(source: s, text: text, error: nil, seconds: seconds)
    }

    /// How each source did last time, for the control panel.
    struct LastRun: Codable {
        var id: String, name: String, engine: String
        var ok: Bool, error: String?, seconds: Double, at: Date
    }
    static var statusFile: URL { Settings.appSupportDir.appendingPathComponent("gather-status.json") }

    static func saveStatus(_ answers: [Answer], at: Date) {
        var runs = loadStatus()
        for a in answers {
            runs[a.source.id] = LastRun(id: a.source.id, name: a.source.name, engine: a.source.engine,
                                        ok: a.text != nil, error: a.error, seconds: a.seconds, at: at)
        }
        if let d = try? JSONEncoder.iso.encode(Array(runs.values)) { try? d.write(to: statusFile, options: .atomic) }
    }

    static func loadStatus() -> [String: LastRun] {
        guard let d = try? Data(contentsOf: statusFile), let runs = try? JSONDecoder.iso.decode([LastRun].self, from: d) else { return [:] }
        return Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func render(_ answers: [Answer], at time: Date) -> String {
        answers.sorted { $0.source.name < $1.source.name }.map { a in
            let head = "### \(a.source.name) (asked \(a.source.engine == "codex" ? "Codex" : "Claude") at \(Dates.time.string(from: time)), \(Int(a.seconds))s)\n"
            return head + (a.text.map { $0.truncated(4_000) } ?? "Not available this morning: \(a.error ?? "unknown error")") + "\n"
        }.joined(separator: "\n")
    }
}
