import Foundation

/// The "brain" for morning context. Nothing is hard-coded: each morning Claude — running with everything you've
/// given it (claude.ai connectors, MCP servers, each repo's own setup) — looks at what happened yesterday and at what
/// it and Codex can reach today, and decides what's worth checking. Connect Slack or Calendar tomorrow and the plan
/// can use it without any change here. Results and your rules feed the next morning's plan.
enum IntakePlanner {

    struct Check: Codable, Identifiable {
        var id: String
        var title: String
        var engine: String          // "claude" or "codex"
        var folder: String          // repo path (its project setup applies) or "" for neutral
        var question: String
        var why: String
        // filled in after running
        var ok: Bool?
        var error: String?
        var seconds: Double?
        var preview: String?
    }

    struct Plan: Codable {
        var at: Date
        var claudeReach: [String]
        var codexReach: [String]
        var checks: [Check]
        var planSeconds: Double
        var note: String?
    }

    static var planFile: URL { Settings.appSupportDir.appendingPathComponent("intake-plan.json") }
    static var historyFile: URL { Settings.appSupportDir.appendingPathComponent("intake-history.json") }

    // MARK: Inventory (local, instant)

    /// Apps Codex has actually used lately (gmail, metricool, github…), from its session logs.
    static func codexApps(days: Int = 30) -> [String] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let re = try? NSRegularExpression(pattern: "mcp__codex_apps__([a-z0-9]+)"),
              let en = FileManager.default.enumerator(at: CodexReader.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var counts: [String: Int] = [:]
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= cutoff,
                  let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { counts[String(text[r]), default: 0] += 1 }
            }
        }
        return counts.filter { $0.value >= 3 && !["plugin", "tool", "search"].contains($0.key) }
            .sorted { $0.value > $1.value }.map(\.key)
    }

    /// A short, structured "what happened" for the planner: not the whole digest, just enough to know what to look up.
    static func outline(claude: ClaudeCodeReader.Result, codex: CodexReader.Result, wispr: WisprFlowReader.Result) -> String {
        var lines: [String] = []
        for s in claude.sessions.suffix(25) {
            let asks = s.turns.filter { $0.contains("USER:") }
            let first = asks.first.map { String($0.split(separator: ":", maxSplits: 2).last ?? "").collapsedWhitespace.truncated(220) } ?? ""
            let last = asks.count > 1 ? asks.last.map { String($0.split(separator: ":", maxSplits: 2).last ?? "").collapsedWhitespace.truncated(160) } ?? "" : ""
            lines.append("- Claude Code \(s.label) \(Dates.dayTime.string(from: s.start)): \(first)" + (last.isEmpty ? "" : " … last: \(last)"))
        }
        for t in codex.threads {
            let last = t.turns.last(where: { $0.hasPrefix("CODEX:") }).map { $0.collapsedWhitespace.truncated(260) } ?? ""
            lines.append("- \(t.isAutomation ? "Codex automation" : "Codex") \"\(t.title)\" \(Dates.dayTime.string(from: t.end)): \(last)")
        }
        for m in wispr.meetings {
            lines.append("- Meeting \"\(m.title)\" \(Dates.dayTime.string(from: m.start)) with \(m.participants.joined(separator: ", "))")
        }
        for e in wispr.entries.suffix(8) {
            lines.append("- Dictation \(Dates.dayTime.string(from: e.time)): \(e.text.collapsedWhitespace.truncated(160))")
        }
        return Secrets.redact(lines.joined(separator: "\n"))
    }

    /// The last few mornings: what was checked, whether it worked, what it found (so the plan learns).
    static func memory() -> String {
        guard let d = try? Data(contentsOf: historyFile), let plans = try? JSONDecoder.iso.decode([Plan].self, from: d), !plans.isEmpty else {
            return "No previous mornings yet."
        }
        return plans.suffix(3).map { p in
            "Morning of \(Dates.dayTime.string(from: p.at)):\n" + p.checks.map { c in
                "  - \(c.title) [\(c.engine)\(c.folder.isEmpty ? "" : " in \((c.folder as NSString).lastPathComponent)")]: " +
                (c.ok == true ? "worked, found: \((c.preview ?? "").collapsedWhitespace.truncated(160))" : "failed: \(c.error ?? "?")")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: Planning (one Claude call, ~30–60 s)

    static func plan(outline: String, since: Date, repos: [LiveChecks.Repo]) -> Plan? {
        guard let (claude, path) = try? ClaudeCLI.locate() else { return nil }
        let codexInstalled = (try? ClaudeCLI.locate("codex")) != nil
        let apps = codexInstalled ? codexApps() : []
        let started = Date()

        let repoLines = repos.map { r -> String in
            let ev = Gather.evidence(for: r.path)
            let keys = Gather.jiraProjectKeys(for: r.path)
            var hints: [String] = []
            if ev.azure > 0 { hints.append("its Claude sessions use Azure DevOps (dev.azure.com)") }
            if ev.jira > 0 { hints.append("its Claude sessions use Jira (atlassian.net)" + (keys.isEmpty ? "" : ", project \(keys.joined(separator: "/"))")) }
            return "- \(r.name): \(r.path)" + (r.slug.map { " (GitHub \($0))" } ?? "") + (hints.isEmpty ? "" : " — " + hints.joined(separator: "; "))
        }.joined(separator: "\n")
        let rules = Settings.intakeRules.trimmingCharacters(in: .whitespacesAndNewlines)
        let clis = localCLIs()

        let prompt = """
        You plan the information-gathering step of my morning brief. Do NOT do the checks yourself and do not call any \
        tools except to look at which tools/connectors you have. Decide what to check; other agents will run your checks \
        in parallel, read-only.

        It's \(Dates.longDay.string(from: Date())) \(Dates.time.string(from: Date())). The brief covers since \(Dates.dayTime.string(from: since)).

        WHAT HAPPENED (from my Claude Code, Codex and Wispr Flow history):
        \(outline.isEmpty ? "(nothing recorded)" : outline)

        WHERE CHECKS CAN RUN:
        - "claude" in a repo folder: Claude Code with that project's own setup and credentials (CLAUDE.md, memory, \
        keychain items it normally uses) plus all of my connectors — the same ones you can see in your own tool list.
        - "claude" with folder "": neutral folder, connectors only.
        \(codexInstalled ? "- \"codex\": Codex CLI with its connected apps. Apps my Codex has used lately: \(apps.isEmpty ? "none seen" : apps.joined(separator: ", ")). Prefer Codex for those apps (e.g. Gmail) if you don't have a working connector for them yourself." : "- Codex is not installed.")
        - Signed-in command-line tools on this Mac that check agents can use read-only: \(clis.isEmpty ? "none found" : clis.joined(separator: "; ")). \
        Connectors can lack access to org repos; when a CLI covers the same thing (gh for GitHub), tell the agent to use it.
        My repos:
        \(repoLines.isEmpty ? "- none" : repoLines)

        WHAT PREVIOUS MORNINGS FOUND (learn from it: keep checks that found useful things, drop ones that were empty or failed twice, fix the ones that failed):
        \(memory())

        MY STANDING RULES (always follow):
        \(rules.isEmpty ? "(none)" : rules)

        Choose 3 to 7 checks that would most change what I do today: work trackers for the tickets/PBIs I touched, PRs \
        and reviews, replies to outreach or emails I sent, chats or mentions, deploys or failing jobs, today's calendar — \
        whatever my history points to and something can actually reach. Skip what the local history already answers.
        Each question must stand alone (the agent can't see this), name the IDs/people/repos involved, say "since \
        \(Dates.dayTime.string(from: since))", ask for a compact plain-text answer under 2000 characters, and allow at most 6 tool calls.

        Reply with ONLY this JSON, no prose:
        {"claude_reach": ["connectors/tools you can use, short names"], "codex_reach": ["apps you expect Codex to reach"],
         "checks": [{"title": "short title", "engine": "claude" or "codex", "folder": "absolute repo path or empty",
                     "question": "…", "why": "one line: what in my history made this worth checking"}]}
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.currentDirectoryURL = Settings.claudeWorkDir
        var args = ["-p", prompt, "--permission-mode", "auto", "--permission-prompts", "none", "--output-format", "json",
                    "--no-session-persistence", "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash",
                    "--model", Settings.claudeModel.isEmpty ? "sonnet" : Settings.claudeModel]
        for r in repos { args += ["--add-dir", r.path] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path; env["CLAUDECODE"] = nil; env["TERM"] = "dumb"
        env["MCP_CONNECTOR_PREWAIT_MS"] = "20000"; env["MCP_CONNECTION_NONBLOCKING"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); data.append(d); lock.unlock() }
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(150)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        if p.isRunning { p.terminate(); AppLog().info("planner timed out"); return nil }
        Thread.sleep(forTimeInterval: 0.1)
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let raw = data; lock.unlock()

        guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let result = o["result"] as? String, let json = firstJSONObject(in: result),
              let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let checks = parsed["checks"] as? [[String: Any]] else {
            AppLog().info("planner returned no usable plan")
            return nil
        }
        let repoPaths = Set(repos.map(\.path))
        var list: [Check] = []
        for (i, c) in checks.prefix(8).enumerated() {
            guard let title = c["title"] as? String, let q = c["question"] as? String, !q.isEmpty else { continue }
            var engine = (c["engine"] as? String)?.lowercased() == "codex" ? "codex" : "claude"
            if engine == "codex" && !codexInstalled { engine = "claude" }
            var folder = (c["folder"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !repoPaths.contains(folder) { folder = "" }   // only real repos, never an arbitrary path
            let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).prefix(30)
            list.append(Check(id: "plan:\(i)-\(slug)", title: title, engine: engine, folder: folder, question: q,
                              why: c["why"] as? String ?? ""))
        }
        guard !list.isEmpty else { return nil }
        return Plan(at: Date(), claudeReach: parsed["claude_reach"] as? [String] ?? [], codexReach: parsed["codex_reach"] as? [String] ?? [],
                    checks: list, planSeconds: Date().timeIntervalSince(started))
    }

    /// Signed-in CLIs worth telling the planner about (read-only use only).
    static func localCLIs() -> [String] {
        var out: [String] = []
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: gh); p.arguments = ["config", "get", "-h", "github.com", "user"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let user = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                p.waitUntilExit()
                out.append("gh (GitHub CLI" + (user.isEmpty ? "" : ", signed in as \(user)") + "; works for my org repos: gh pr view/list/checks -R owner/repo)")
            }
            break
        }
        for az in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: az) {
            out.append("az (Azure CLI)"); break
        }
        return out
    }

    /// The planned checks as gather sources (each gets the read-only rule prepended).
    static func sources(for plan: Plan) -> [Gather.Source] {
        plan.checks.map { c in
            Gather.Source(id: c.id, name: c.title, folder: c.folder.isEmpty ? Settings.claudeWorkDir.path : c.folder,
                          question: Gather.readOnlyRule
                                    + (c.engine == "codex" ? "\nUse your connected apps/connectors only; never a browser, computer use or screen control."
                                                           : "\nIf a connector can't reach something (no access, 404, not authorized), try the signed-in CLI that covers it, read-only (e.g. `gh pr view N -R owner/repo --json …` for GitHub), before giving up.")
                                    + "\n" + c.question,
                          engine: c.engine)
        }
    }

    /// "I can't reach…" answers are failures for learning purposes, even though the agent replied.
    static func looksUnreachable(_ text: String) -> Bool {
        let head = text.prefix(220).lowercased()
        return ["can't reach", "cannot reach", "couldn't retrieve", "can't fetch", "cannot access", "no access", "isn't authorized",
                "not authorized", "requires authorization", "don't have access", "unable to access", "i can't"].contains { head.contains($0) }
    }

    /// Store results on the plan (for the control panel) and append it to the history (for tomorrow's plan).
    static func record(_ plan: Plan, answers: [Gather.Answer]) {
        var p = plan
        for i in p.checks.indices {
            guard let a = answers.first(where: { $0.source.id == p.checks[i].id }) else { continue }
            let unreachable = a.text.map(looksUnreachable) ?? false
            p.checks[i].ok = a.text != nil && !unreachable
            p.checks[i].error = a.error ?? (unreachable ? a.text.map { String($0.collapsedWhitespace.prefix(200)) } : nil)
            p.checks[i].seconds = a.seconds
            p.checks[i].preview = a.text.map { String($0.prefix(600)) }
        }
        if let d = try? JSONEncoder.iso.encode(p) { try? d.write(to: planFile, options: .atomic) }
        var history = (try? Data(contentsOf: historyFile)).flatMap { try? JSONDecoder.iso.decode([Plan].self, from: $0) } ?? []
        history.append(p)
        if let d = try? JSONEncoder.iso.encode(Array(history.suffix(7))) { try? d.write(to: historyFile, options: .atomic) }
    }

    static func lastPlan() -> Plan? {
        (try? Data(contentsOf: planFile)).flatMap { try? JSONDecoder.iso.decode(Plan.self, from: $0) }
    }

    static func addRule(_ rule: String) {
        let r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        let existing = Settings.intakeRules.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.defaults.set(existing.isEmpty ? r : existing + "\n" + r, forKey: Settings.Key.intakeRules)
    }

    private static func firstJSONObject(in s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for i in s[start...].indices {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true } else if ch == "{" { depth += 1 } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(s[start...i]) }
            }
        }
        return nil
    }
}
