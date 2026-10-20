import Foundation

/// A live, multi-turn conversation with Claude about the morning's context.
///
/// Runs one long-lived `claude -p` process in stream-json mode (your existing Claude Code login,
/// no API key): each question is a JSON line on stdin, and the answer streams back token by token.
/// The brief + raw digest sit in the system prompt, so follow-ups are fast and stay grounded.
final class ConversationEngine {

    enum Event {
        case delta(String)
        /// Claude is running a live, read-only check (e.g. `gh pr view 42 …`).
        case checking(String)
        case turnDone(text: String, interrupted: Bool)
        case failed(String)
    }

    /// Called on the main queue.
    var onEvent: (Event) -> Void = { _ in }

    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var turnText = ""
    private var inFlight = false
    private var queued: String?
    private var muted = false
    private var stderrTail = ""

    var isRunning: Bool { proc?.isRunning == true }

    func start(systemPrompt: String, repos: [LiveChecks.Repo] = []) throws {
        stop()
        let promptURL = Settings.claudeWorkDir.appendingPathComponent("conversation-system.txt")
        try systemPrompt.write(to: promptURL, atomically: true, encoding: .utf8)

        let (claudePath, path) = try ClaudeCLI.locate()
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--no-session-persistence",
                    "--system-prompt-file", promptURL.path]
        let model = Settings.conversationModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { args += ["--model", model] }
        args += LiveChecks.flags(repos)   // last: --allowedTools takes the rest of the arguments

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        p.currentDirectoryURL = Settings.claudeWorkDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["CLAUDECODE"] = nil
        env["TERM"] = "dumb"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(data: h.availableData, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(1_000)) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.proc === proc else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if self.inFlight || proc.terminationStatus != 0 {
                    let why = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.onEvent(.failed("Claude stopped (status \(proc.terminationStatus)). \(why)".truncated(400)))
                }
                self.inFlight = false
                self.proc = nil
            }
        }

        try p.run()
        proc = p
        stdin = inPipe.fileHandleForWriting
    }

    /// Ask something. If Claude is mid-answer, that answer is cut off first (barge-in).
    func ask(_ text: String) {
        guard isRunning else { onEvent(.failed("The conversation isn't running.")); return }
        if inFlight {
            queued = text
            interrupt()
            return
        }
        write(["type": "user", "message": ["role": "user", "content": text]])
        inFlight = true
        muted = false
        turnText = ""
    }

    func interrupt() {
        guard inFlight else { return }
        muted = true
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func stop() {
        stdin?.closeFile()
        stdin = nil
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
        inFlight = false
        queued = nil
        buffer.removeAll()
    }

    // MARK: - Stream handling

    private func write(_ obj: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do {
            try stdin.write(contentsOf: data + Data("\n".utf8))
        } catch {
            onEvent(.failed("Couldn't reach Claude: \(error.localizedDescription)"))
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "stream_event":
            // A new text block after a tool call: start a new sentence/caption line.
            if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_start",
               (ev["content_block"] as? [String: Any])?["type"] as? String == "text", !turnText.isEmpty, !muted {
                turnText += "\n"
                onEvent(.delta("\n"))
                return
            }
            guard let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            // Once the user has barged in, the rest of the old answer is noise.
            guard !muted else { return }
            turnText += text
            onEvent(.delta(text))
        case "assistant":
            guard !muted, let msg = obj["message"] as? [String: Any], let parts = msg["content"] as? [[String: Any]] else { return }
            for p in parts where p["type"] as? String == "tool_use" {
                let input = p["input"] as? [String: Any] ?? [:]
                let what = (input["command"] as? String) ?? (input["pattern"] as? String) ?? (input["file_path"] as? String) ?? (p["name"] as? String ?? "")
                onEvent(.checking(what.collapsedWhitespace.truncated(80)))
            }
        case "result":
            let interrupted = (obj["subtype"] as? String) != "success"
            if interrupted, queued == nil, (obj["terminal_reason"] as? String) != "aborted_streaming" {
                let msg = (obj["result"] as? String) ?? (obj["terminal_reason"] as? String) ?? "unknown error"
                inFlight = false
                onEvent(.failed("Claude couldn't answer: \(msg)".truncated(300)))
                return
            }
            inFlight = false
            onEvent(.turnDone(text: turnText, interrupted: interrupted))
            if let next = queued {
                queued = nil
                ask(next)
            }
        default:
            break
        }
    }
}

/// Finding and isolating the `claude` CLI, shared by the brief summarizer and the conversation.
enum ClaudeCLI {
    /// No tools, skills, MCP servers or settings files: this is a pure text conversation, so nothing
    /// from your Claude Code setup (a "morning brief" skill, hooks, project memory) can hijack it.
    static let isolationFlags = ["--tools", "", "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", ""]

    private static var cached: [String: (String, String)] = [:]

    /// Resolves a CLI (`claude`, `codex`) and PATH from your login shell once (brew, npm -g, ~/.local/bin, nvm…).
    static func locate(_ name: String = "claude") throws -> (claude: String, path: String) {
        if let hit = cached[name] { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "print -r -- \"__CLAUDE__$(command -v \(name))\"; print -r -- \"__PATH__$PATH\""]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n")
        let claude = lines.last { $0.hasPrefix("__CLAUDE__") }.map { String($0.dropFirst(10)) } ?? ""
        let path = lines.last { $0.hasPrefix("__PATH__") }.map { String($0.dropFirst(8)) } ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        guard !claude.isEmpty, FileManager.default.isExecutableFile(atPath: claude) else {
            throw Summarizer.SummarizerError(message: "The `\(name)` CLI was not found in your login shell PATH. Run `\(name)` once in Terminal to confirm it works.")
        }
        cached[name] = (claude, path)
        return (claude, path)
    }
}

/// What the voice companion knows and how it should talk.
enum ConversationPrompt {
    static func system(briefMarkdown: String, rawContext: String, snapshot: Date = Date(), repos: [LiveChecks.Repo] = []) -> String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return """
        You are Morning Context, \(name.isEmpty ? "the user" : name)'s spoken morning companion on their Mac. It is \
        \(Dates.longDay.string(from: Date())), \(Dates.time.string(from: Date())). You are having a live voice \
        conversation: everything you write is read aloud by a speech synthesizer, and the user answers by voice or by typing.

        How to talk:
        - Write for the ear. Plain sentences only: no Markdown, no bullets, no headings, no emoji, no code formatting, no URLs read aloud.
        - Short. Two to four sentences per reply unless they ask for more. One idea per sentence.
        - Say numbers and names the way a person would ("PR forty-two", "Siobhan", "about ten minutes").
        - Sound like a sharp colleague who read everything for them, not a report. Warm, direct, no filler, no "great question".
        - When you finish a topic, offer one natural next step as a short question, so they can just say yes.
        - If they interrupt or change topic, follow them immediately. Never re-read things they already heard.
        - A message starting with [Interrupted: …] means they talked over you; the quote is the last thing they heard. \
        Answer what they said. If it was "go on", "yeah", "okay" or similar, continue from exactly where you were cut \
        off without repeating; if it was a question or a new direction, follow it and offer to come back to the rest.

        What they say reaches you through on-device speech recognition, so names and jargon often arrive mangled \
        ("at last" for atlas, "cube control" for kubectl, "Shavon" for Siobhan, "manor repo" for monorepo). \
        Match what you hear by sound against the names in the context and answer what they meant. Never point out the mistake.

        The first message you get is "[start]": open with a short greeting, then the two or three things that matter \
        most today (blockers and anything someone is waiting on first), in under 120 words. Then ask where they want to go.

        Ground everything in the context below. If it isn't there, say you don't know rather than guessing. \
        You cannot see their screen, email or calendar beyond what's below.

        Actions: you can offer the user up to three buttons by ending your reply with lines in exactly this form \
        (they are shown, never spoken):
        ACTION: <2-4 word label> | copy | <text to put on their clipboard, e.g. a drafted message>
        ACTION: <2-4 word label> | open | <an https URL that appears verbatim in the context>
        Offer a copy action whenever you draft something for them (a nudge, a reply, a commit message). You never send, \
        post or change anything yourself; say "I've put a draft on your clipboard button", never "I sent it".

        \(LiveChecks.promptSection(repos: repos, snapshot: snapshot))

        ===== TODAY'S BRIEF (already written; use it as your map) =====
        \(Secrets.redact(briefMarkdown))

        ===== RAW CONTEXT (Claude Code sessions, meetings, dictations; use it for details) =====
        \(Secrets.redact(rawContext))
        ===== END =====
        """
    }
}

/// Read-only "check again" powers for the conversation: GitHub (via your logged-in `gh`) and local git,
/// for the repos you worked in recently. Every allowed command is an exact, read-only prefix; anything else
/// (commit, push, comment, merge, writing files, chained commands) is refused by Claude Code itself.
enum LiveChecks {
    struct Repo: Equatable {
        let name: String
        let path: String
        let slug: String?   // owner/repo on GitHub
    }

    static let ghReadOnly = ["gh pr view", "gh pr list", "gh pr checks", "gh pr status", "gh pr diff", "gh run list", "gh run view",
                             "gh issue view", "gh issue list", "gh repo view", "gh release list", "gh search prs", "gh search issues"]
    static let gitReadOnly = ["log", "status", "show", "diff", "rev-parse", "for-each-ref", "ls-remote", "worktree list", "branch --list"]

    /// Main checkouts (not worktrees) of repos with Claude Code activity in the last `days` days.
    static func discover(days: Int = 14) -> [Repo] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        var out: [Repo] = []
        for dir in (try? fm.contentsOfDirectory(at: Settings.claudeProjectsDir, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                guard let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= cutoff,
                      let h = try? FileHandle(forReadingFrom: f) else { continue }
                let head = h.readData(ofLength: 64_000)
                try? h.close()
                guard let s = String(data: head, encoding: .utf8), let r = s.range(of: "\"cwd\":\""),
                      let end = s[r.upperBound...].firstIndex(of: "\"") else { continue }
                var cwd = String(s[r.upperBound..<end])
                for marker in ["/.claude/worktrees/", "/.worktrees/"] {
                    if let m = cwd.range(of: marker) { cwd = String(cwd[..<m.lowerBound]) }
                }
                // Real checkouts only: skip temp/scratch folders and paths with spaces (permission rules can't quote them).
                guard !seen.contains(cwd), !cwd.contains(" "),
                      !["/private/", "/var/", "/tmp/"].contains(where: { cwd.hasPrefix($0) }) else { continue }
                seen.insert(cwd)
                var isDir: ObjCBool = false
                let git = (cwd as NSString).appendingPathComponent(".git")
                guard fm.fileExists(atPath: git, isDirectory: &isDir), isDir.boolValue else { continue }
                out.append(Repo(name: (cwd as NSString).lastPathComponent, path: cwd, slug: githubSlug(gitDir: git)))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func githubSlug(gitDir: String) -> String? {
        guard let config = try? String(contentsOfFile: gitDir + "/config", encoding: .utf8),
              let origin = config.range(of: "[remote \"origin\"]") else { return nil }
        let section = config[origin.upperBound...].prefix { $0 != "[" }
        guard let re = try? NSRegularExpression(pattern: "url\\s*=\\s*\\S*github\\.com[:/]([^/\\s]+/[^/\\s]+?)(?:\\.git)?\\s*$", options: .anchorsMatchLines),
              let m = re.firstMatch(in: String(section), range: NSRange(section.startIndex..., in: section)),
              let r = Range(m.range(at: 1), in: section) else { return nil }
        return String(section[r])
    }

    static func flags(_ repos: [Repo]) -> [String] {
        var f = ["--tools", "Bash,Read,Grep,Glob", "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", ""]
        for r in repos { f += ["--add-dir", r.path] }
        f += ["--add-dir", ClaudeJobs.dir.path]
        var allowed = ghReadOnly.map { "Bash(\($0):*)" } + ["Read", "Grep", "Glob"]
        for r in repos { allowed += gitReadOnly.map { "Bash(git -C \(r.path) \($0):*)" } }
        return f + ["--allowedTools"] + allowed
    }

    static func promptSection(repos: [Repo], snapshot: Date) -> String {
        let list = repos.map { r in "- \(r.name): \(r.path)" + (r.slug.map { " (GitHub: \($0))" } ?? " (no GitHub remote)") }.joined(separator: "\n")
        return """
        Live checks: the brief and raw context are a snapshot from \(Dates.dayTime.string(from: snapshot)). For a status \
        question (PR reviews, CI, runs, deploys, who is waiting on whom), answer straight away from the snapshot, say when \
        it was last seen ("as of twelve fifteen last night"), and offer to check live. Do NOT run checks unless they ask you \
        to check, check again, refresh, or say "right now" / "latest" — checks take several seconds. When they do ask, \
        first say one short sentence like "Checking GitHub now.", then report what is true now and what changed since the \
        snapshot. Keep it spoken and short; never read out raw output.
        Be fast: use as few commands as possible, ideally one. For several PRs in a repo use a single \
        gh pr list -R owner/repo --state all --search "42 57 61" (or --author @me) --json number,title,state,reviewDecision,mergeable,statusCheckRollup \
        instead of one gh pr view per PR. If you need several independent commands, issue them together in one turn.
        You can only look, never change anything. Allowed (anything else is refused, so don't try):
        - \(ghReadOnly.joined(separator: ", ")). Always pass -R owner/repo. Use --json with only the fields you need, \
        and gh's own --jq to trim it (e.g. gh pr view 42 -R owner/repo --json state,reviewDecision,mergeable,statusCheckRollup,latestReviews).
        - git -C <repo path> \(gitReadOnly.joined(separator: " | ")).
        - Read, Grep, Glob inside the repos below.
        One command per tool call: no pipes, no "&&", no cd. If a check fails (no access, suspended account, not found), \
        say so plainly and fall back to the snapshot, with its time.
        Repos you can check:
        \(list.isEmpty ? "- none found" : list)

        If they tell you what the morning brief should or shouldn't look at ("always check Render deploys", "stop telling me \
        about Hershey's task emails"), save it as a standing rule by adding this line (it's applied, not shown):
        ACTION: Remember | remember | <the rule as a short instruction>
        and confirm in a few words.

        Jira, Azure Boards, Gmail and Codex information in the context was gathered while the brief was prepared (see \
        the "asked Claude at" times). Answer from it and say it's as of then; you can't re-check those live during the \
        conversation. Only GitHub and git can be checked live, and only when asked.

        \(Settings.handoffEnabled ? "" : "Handing work to Claude is switched off in the control panel: never offer claude or claude-start actions; just say what they could ask Claude to do. Ignore the next paragraph.\n")
        Handing work to Claude: you can't change code yourself, but you can start Claude Code to do it. It runs unattended \
        in a fresh worktree branch of one of the repos above, edits, runs tests and commits locally, and never pushes, \
        comments or merges; the user reviews the branch afterwards. When they ask for work (fix, implement, investigate, \
        write tests, refactor…), say in one sentence what you'll ask Claude to do and where, then offer it as a button:
        ACTION: <2-4 word label> | claude | <repo name> :: <task prompt>
        If they already clearly told you to go ahead ("yes, do it", "get Claude on it"), use claude-start instead of claude: \
        it starts immediately, and you say something like "Started. I'll tell you when it's done."
        The task prompt must stand alone, since that Claude can't see this conversation: the goal, ticket/PR numbers, the \
        branch to start from, relevant files, decisions already made, and how to verify — all from the context. One line; \
        write \\n for line breaks.
        Jobs you started, with live status, are in \(ClaudeJobs.statusFile.path); Read it when they ask how a job is going.
        When you receive a message starting with [Job finished], tell them in two or three spoken sentences what Claude \
        did and whether it worked, then offer the next step (review it, run it, or hand off a follow-up). Don't read long \
        branch names or paths aloud: say "on its own branch in atlas"; put the branch on a copy button instead.
        """
    }
}
