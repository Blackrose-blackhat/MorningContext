import Foundation
import AppKit

/// Work the voice companion hands off to Claude Code: each job runs headless in a fresh git worktree
/// (`<repo>/.claude/worktrees/morning-…`, its own branch), edits/tests/commits locally, and never pushes or posts.
/// Claude's auto permission mode vets every step; anything that would need a human is refused, not waited on.
final class ClaudeJobs: ObservableObject {
    static let shared = ClaudeJobs()

    struct Job: Codable, Identifiable, Equatable {
        enum Status: String, Codable { case running, done, failed, stopped }
        var id: String
        var repo: String
        var repoPath: String
        var title: String
        var prompt: String
        var worktreeName: String
        var baseCommit: String
        var started: Date
        var finished: Date?
        var status: Status
        var sessionId: String?
        var worktreePath: String?
        var branch: String?
        var lastActivity: String?
        var steps: Int
        var summary: String?
        var changes: String?

        var isRunning: Bool { status == .running }
    }

    @Published private(set) var jobs: [Job] = []
    /// Called on the main queue when a job ends.
    var onFinished: (Job) -> Void = { _ in }

    private var procs: [String: Process] = [:]
    private var buffers: [String: Data] = [:]

    static var dir: URL {
        let url = Settings.appSupportDir.appendingPathComponent("jobs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var statusFile: URL { dir.appendingPathComponent("jobs.json") }

    /// Commands a job may never run, on top of auto mode's own checks: nothing leaves this Mac.
    static let neverAllowed = ["git push", "gh pr create", "gh pr merge", "gh pr comment", "gh pr review", "gh pr close",
                               "gh pr edit", "gh pr ready", "gh issue create", "gh issue comment", "gh issue close",
                               "gh issue edit", "gh api", "gh release", "gh repo", "gh workflow", "gh run rerun",
                               "gh run cancel", "gh secret", "gh gist"].map { "Bash(\($0):*)" }

    init() {
        if let data = try? Data(contentsOf: Self.statusFile),
           let saved = try? JSONDecoder.iso.decode([Job].self, from: data) {
            // Anything still "running" from a previous launch lost its process.
            jobs = saved.map { var j = $0; if j.status == .running { j.status = .stopped; j.lastActivity = "App restarted" }; return j }
        }
    }

    @discardableResult
    func start(repo: LiveChecks.Repo, title: String, task: String) throws -> Job {
        let (claudePath, path) = try ClaudeCLI.locate()
        let stamp = Self.stampFormatter.string(from: Date())
        let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)
        let name = "morning-\(slug.isEmpty ? "task" : String(slug))-\(stamp)"
        let base = Self.git(["-C", repo.path, "rev-parse", "HEAD"]) ?? ""

        var job = Job(id: UUID().uuidString, repo: repo.name, repoPath: repo.path, title: title, prompt: task,
                      worktreeName: name, baseCommit: base, started: Date(), finished: nil, status: .running,
                      sessionId: nil, worktreePath: nil, branch: nil, lastActivity: "Starting", steps: 0,
                      summary: nil, changes: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.currentDirectoryURL = URL(fileURLWithPath: repo.path)
        p.arguments = ["-p", Self.wrap(task, repo: repo), "-w", name, "-n", "Morning: \(title)",
                       "--permission-mode", "auto", "--permission-prompts", "none", "--strict-mcp-config",
                       "--output-format", "stream-json", "--verbose",
                       "--disallowedTools"] + Self.neverAllowed
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["CLAUDECODE"] = nil
        env["TERM"] = "dumb"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err

        let log = Self.dir.appendingPathComponent("\(job.id).jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        let id = job.id
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            logHandle?.write(data)
            DispatchQueue.main.async { self?.consume(id: id, data: data) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty { logHandle?.write(data) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()
            DispatchQueue.main.async { self?.ended(id: id, status: proc.terminationStatus) }
        }

        try p.run()
        procs[id] = p
        jobs.insert(job, at: 0)
        save()
        AppLog().info("job started: \(repo.name) · \(title) · \(name)")
        job.lastActivity = "Working"
        update(id) { $0.lastActivity = "Working" }
        return job
    }

    func stop(_ id: String) {
        procs[id]?.terminate()
        update(id) { $0.status = .stopped; $0.lastActivity = "Stopped by you" }
    }

    /// Pick the conversation up yourself: an interactive Claude Code session in the job's worktree.
    func openInTerminal(_ job: Job) {
        guard let wt = job.worktreePath else { return }
        var cmd = "cd \(Self.shellQuote(wt)) && claude"
        if let s = job.sessionId { cmd += " --resume \(s)" }
        let script = Self.dir.appendingPathComponent("open-\(job.id).command")
        try? "#!/bin/zsh -l\n\(cmd)\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        NSWorkspace.shared.open(script)
    }

    // MARK: - Stream

    private func consume(id: String, data: Data) {
        var buf = (buffers[id] ?? Data()) + data
        while let nl = buf.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buf[buf.startIndex..<nl]
            buf.removeSubrange(buf.startIndex...nl)
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "system" where o["subtype"] as? String == "init":
                update(id) { j in
                    j.sessionId = o["session_id"] as? String
                    j.worktreePath = o["cwd"] as? String
                }
            case "assistant":
                let parts = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for part in parts where part["type"] as? String == "tool_use" {
                    let input = part["input"] as? [String: Any] ?? [:]
                    let what = (input["description"] as? String) ?? (input["command"] as? String)
                        ?? (input["file_path"] as? String).map { "Editing \(($0 as NSString).lastPathComponent)" }
                        ?? (part["name"] as? String ?? "")
                    update(id) { $0.steps += 1; $0.lastActivity = what.collapsedWhitespace.truncated(90) }
                }
            case "result":
                update(id) { j in
                    j.summary = (o["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    j.status = (o["subtype"] as? String) == "success" ? .done : .failed
                }
            default: break
            }
        }
        buffers[id] = buf
    }

    private func ended(id: String, status: Int32) {
        procs[id] = nil
        buffers[id] = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        var j = job
        j.finished = Date()
        if j.status == .running { j.status = status == 0 ? .done : .failed }
        if let wt = j.worktreePath {
            j.branch = Self.git(["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"])
            if !j.baseCommit.isEmpty {
                let commits = Self.git(["-C", wt, "rev-list", "--count", "\(j.baseCommit)..HEAD"]) ?? "0"
                let stat = Self.git(["-C", wt, "diff", "--shortstat", j.baseCommit]) ?? ""
                j.changes = "\(commits) commit\(commits == "1" ? "" : "s")" + (stat.isEmpty ? ", no file changes" : ", \(stat)")
            }
        }
        j.lastActivity = j.status == .done ? "Finished" : (j.status == .stopped ? "Stopped" : "Failed")
        update(id) { $0 = j }
        AppLog().info("job \(j.status.rawValue): \(j.repo) · \(j.title) · \(j.changes ?? "")")
        onFinished(j)
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    /// Also what the voice companion reads when you ask "how's that job going?".
    private func save() {
        if let data = try? JSONEncoder.iso.encode(Array(jobs.prefix(30))) {
            try? data.write(to: Self.statusFile, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func wrap(_ task: String, repo: LiveChecks.Repo) -> String {
        """
        You were started by the user's voice assistant (Morning Context) to do this task unattended, in a fresh git \
        worktree of \(repo.name)\(repo.slug.map { " (GitHub: \($0))" } ?? ""). Nobody is watching and you cannot ask \
        questions: make sensible calls and note them in your summary.

        TASK:
        \(task)

        RULES:
        - Work only inside this worktree. If the task builds on an existing branch, start from it first \
        (git fetch origin <branch>, then git reset --hard origin/<branch> on your current branch).
        - Commit your work to your current branch with clear messages. Never push, open or edit PRs or issues, \
        comment, merge, or post anywhere; the user reviews and ships it.
        - Run the relevant tests or checks when practical, and say if you couldn't.
        - Stop and explain if the task is unclear, unsafe, or much bigger than described.

        Finish with a plain-English summary of 3 to 5 sentences that will be read aloud: what you did, what is left, \
        how to verify it, and your branch name. No Markdown.
        """
    }

    @discardableResult
    static func git(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMdd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
