import Foundation

/// Reads Claude Code session transcripts from ~/.claude/projects/**/*.jsonl
/// and produces a compact text digest of everything that happened in a time window.
enum ClaudeCodeReader {

    struct Session {
        var repo: String
        var worktree: String?
        var branch: String?
        var start: Date
        var end: Date
        var turns: [String]
        var chars: Int { turns.reduce(0) { $0 + $1.count } }
        var label: String {
            var s = "`\(repo)`"
            if let branch { s += " on branch `\(branch)`" } else if let worktree { s += " (worktree `\(worktree)`)" }
            return s
        }
    }

    struct Result {
        var sessions: [Session]
        var text: String
        var filesScanned: Int
        var skippedAutomated: Int
    }

    static func digest(from: Date, to: Date, charBudget: Int) -> Result {
        let fm = FileManager.default
        let root = Settings.claudeProjectsDir
        var sessions: [Session] = []
        var candidates: [(url: URL, dir: String, size: Int)] = []
        var skippedAutomated = 0

        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return Result(sessions: [], text: "", filesScanned: 0, skippedAutomated: 0)
        }

        // Top-level <session>.jsonl only: <session>/subagents/*.jsonl are the agent's own helpers,
        // and their results already show up in the parent session.
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // Cheap pre-filter: a file untouched since the window started can't contain anything from it.
                let rv = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard (rv?.contentModificationDate ?? .distantPast) >= from else { continue }
                candidates.append((file, dir.lastPathComponent, rv?.fileSize ?? 0))
            }
        }

        // A forked/resumed session copies its parent's messages into a new file. Parse the biggest
        // files first so the original keeps the shared history and the fork contributes only what's new.
        candidates.sort { $0.size > $1.size }
        var seen = Set<String>()
        for c in candidates {
            switch parseSession(file: c.url, projectDirName: c.dir, from: from, to: to, seen: &seen) {
            case .session(let s): sessions.append(s)
            case .automated: skippedAutomated += 1
            case .empty: break
            }
        }

        sessions.sort { $0.start < $1.start }

        // Share the budget fairly across sessions (small ones in full, big ones head+tail), so the
        // latest work is never the part that gets cut.
        let headers = sessions.map { "### Claude Code — \($0.label) (\(Dates.dayTime.string(from: $0.start)) → \(Dates.time.string(from: $0.end)))\n" }
        let bodies = sessions.map { $0.turns.joined(separator: "\n") }
        let caps = Budget.fairCaps(sizes: zip(headers, bodies).map { $0.count + $1.count + 2 }, budget: charBudget)
        var out = ""
        for i in sessions.indices {
            let room = caps[i] - headers[i].count - 2
            guard room >= 200 else { continue }
            out += headers[i] + bodies[i].headTail(room, marker: "\n…[middle of session omitted]…\n") + "\n\n"
        }
        return Result(sessions: sessions, text: out, filesScanned: candidates.count, skippedAutomated: skippedAutomated)
    }

    // MARK: - Parsing one .jsonl session file

    private enum Parsed { case session(Session), automated, empty }

    private static func parseSession(file: URL, projectDirName: String, from: Date, to: Date, seen: inout Set<String>) -> Parsed {
        guard let data = try? Data(contentsOf: file), let content = String(data: data, encoding: .utf8) else { return .empty }

        var place = (repo: prettyProject(projectDirName), worktree: String?.none)
        var branch: String? = nil
        var turns: [String] = []
        var start: Date? = nil
        var end: Date? = nil
        var lastRole = ""
        var pendingTools: [String] = []
        let ownWorkDir = Settings.appSupportDir.path

        func flushTools() {
            if !pendingTools.isEmpty {
                turns.append("  tools: " + pendingTools.joined(separator: "; ").truncated(700))
                pendingTools.removeAll()
            }
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }

            // Headless `claude -p` runs (scripts, other apps, and this app's own summaries) aren't your work.
            // …except jobs you handed to Claude from the voice companion (worktrees named morning-…).
            if obj["entrypoint"] as? String == "sdk-cli", !((obj["cwd"] as? String) ?? "").contains("/.claude/worktrees/morning-") {
                return .automated
            }
            if let cwd = obj["cwd"] as? String, cwd.hasPrefix(ownWorkDir) { return .automated }

            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { continue }
            if let uuid = obj["uuid"] as? String, !seen.insert(uuid).inserted { continue }
            guard let ts = Dates.parse(obj["timestamp"]), ts >= from, ts <= to else { continue }

            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { place = repoAndWorktree(cwd: cwd) }
            if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            if start == nil { start = ts }
            end = ts

            guard let message = obj["message"] as? [String: Any] else { continue }
            let role = (message["role"] as? String) ?? type

            var texts: [String] = []
            if let s = message["content"] as? String {
                texts.append(s)
            } else if let parts = message["content"] as? [[String: Any]] {
                for p in parts {
                    switch p["type"] as? String {
                    case "text":
                        if let t = p["text"] as? String { texts.append(t) }
                    case "tool_use":
                        pendingTools.append(describeTool(p))
                    case "tool_result":
                        // Tool output is usually noise for a summary; keep a short hint only.
                        if let c = p["content"] as? String, c.lowercased().contains("error") {
                            texts.append("[tool error: \(c.collapsedWhitespace.truncated(160))]")
                        }
                    default: break
                    }
                }
            }

            let joined = texts.joined(separator: " ").collapsedWhitespace
            // Skip slash-command plumbing and empty turns.
            if joined.isEmpty || joined.hasPrefix("<command-name>") || joined.hasPrefix("<local-command") { continue }
            if joined.hasPrefix("[Request interrupted") { continue }

            if role == "user" {
                flushTools()
                turns.append("[\(Dates.time.string(from: ts))] USER: " + joined.truncated(900))
            } else {
                if lastRole == "assistant" { flushTools() }
                turns.append("ASSISTANT: " + joined.truncated(700))
            }
            lastRole = role
        }
        flushTools()

        guard let s = start, let e = end, !turns.isEmpty else { return .empty }
        return .session(Session(repo: place.repo, worktree: place.worktree, branch: branch, start: s, end: e, turns: turns))
    }

    private static func describeTool(_ p: [String: Any]) -> String {
        let name = (p["name"] as? String) ?? "tool"
        let input = (p["input"] as? [String: Any]) ?? [:]
        let detail = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["command"] as? String)?.collapsedWhitespace.truncated(90)
            ?? (input["pattern"] as? String)
            ?? (input["description"] as? String)
            ?? (input["query"] as? String)
            ?? (input["url"] as? String)
            ?? (input["subject"] as? String)
            ?? ""
        return detail.isEmpty ? name : "\(name)(\(detail))"
    }

    /// `/…/acme-monorepo/.claude/worktrees/funny-hodgkin-34a90c` → ("acme-monorepo", "funny-hodgkin-34a90c")
    private static func repoAndWorktree(cwd: String) -> (repo: String, worktree: String?) {
        // Claude desktop side sessions run in a scratch notes folder, not a repo.
        if cwd.contains("/Claude/side-session-notes/") { return ("Claude side session", nil) }
        for marker in ["/.claude/worktrees/", "/.worktrees/"] {
            if let r = cwd.range(of: marker) {
                let repo = (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
                let worktree = cwd[r.upperBound...].split(separator: "/").first.map(String.init)
                return (repo, worktree)
            }
        }
        return ((cwd as NSString).lastPathComponent, nil)
    }

    /// `-Users-me-work-pux` → `pux` (only used when a session has no cwd)
    private static func prettyProject(_ dirName: String) -> String {
        let parts = dirName.split(separator: "-").map(String.init)
        return parts.last ?? dirName
    }
}
