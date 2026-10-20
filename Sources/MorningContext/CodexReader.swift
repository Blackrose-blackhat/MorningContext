import Foundation

/// Reads Codex (desktop/CLI) sessions from ~/.codex/sessions/**/*.jsonl: what you asked, what Codex answered,
/// and what each scheduled automation run found (job outreach, client outreach, lead research…).
enum CodexReader {

    struct Thread {
        var title: String
        var start: Date
        var end: Date
        var turns: [String]
        var isAutomation: Bool
    }

    struct Result {
        var threads: [Thread]
        var text: String
        var filesScanned: Int
    }

    static var sessionsDir: URL { Settings.home.appendingPathComponent(".codex/sessions") }
    static var automationsDir: URL { Settings.home.appendingPathComponent(".codex/automations") }

    static func digest(from: Date, to: Date, charBudget: Int) -> Result {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return Result(threads: [], text: "", filesScanned: 0)
        }
        let names = automationNames()
        var threads: [Thread] = []
        var scanned = 0
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod >= from else { continue }
            scanned += 1
            if let t = parse(url, from: from, to: to, automationNames: names) { threads.append(t) }
        }
        threads.sort { $0.start < $1.start }

        let headers = threads.map { t in
            "### \(t.isAutomation ? "Codex automation" : "Codex session") — \(t.title) (\(Dates.dayTime.string(from: t.start)) → \(Dates.time.string(from: t.end)))\n"
        }
        let bodies = threads.map { $0.turns.joined(separator: "\n") }
        let caps = Budget.fairCaps(sizes: zip(headers, bodies).map { $0.count + $1.count + 2 }, budget: charBudget)
        var out = ""
        for i in threads.indices {
            let room = caps[i] - headers[i].count - 2
            guard room >= 200 else { continue }
            // Keep the end: for automations the latest run is what matters.
            out += headers[i] + bodies[i].headTail(room) + "\n\n"
        }
        return Result(threads: threads, text: out, filesScanned: scanned)
    }

    /// automation id → its display name, from ~/.codex/automations/<id>/automation.toml
    static func automationNames() -> [String: String] {
        var out: [String: String] = [:]
        for dir in (try? FileManager.default.contentsOfDirectory(at: automationsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let toml = try? String(contentsOf: dir.appendingPathComponent("automation.toml"), encoding: .utf8) else { continue }
            let id = value(of: "id", in: toml) ?? dir.lastPathComponent
            out[id] = value(of: "name", in: toml) ?? id
        }
        return out
    }

    private static func value(of key: String, in toml: String) -> String? {
        for line in toml.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    private static func parse(_ url: URL, from: Date, to: Date, automationNames: [String: String]) -> Thread? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var title = ""
        var automation: String?
        var turns: [String] = []
        var start: Date?, end: Date?

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap filter before JSON parsing: only the record types we use.
            guard line.contains("\"session_meta\"") || line.contains("\"task_complete\"") || line.contains("\"role\":\"user\"") else { continue }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            let type = o["type"] as? String

            if type == "session_meta" {
                // Codex's own helper agents (safety reviewer etc.) aren't your work.
                if let src = p["source"] as? [String: Any], src["subagent"] != nil { return nil }
                if let cwd = p["cwd"] as? String { title = (cwd as NSString).lastPathComponent }
                continue
            }
            guard let ts = Dates.parse(o["timestamp"]), ts >= from, ts <= to else { continue }

            if type == "response_item", p["type"] as? String == "message", p["role"] as? String == "user" {
                let text = ((p["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = tag("automation_id", in: t) {
                    automation = id
                    turns.append("[\(Dates.time.string(from: ts))] (scheduled run)")
                } else if t.isEmpty || t.hasPrefix("<") {
                    continue   // environment / app context plumbing
                } else {
                    turns.append("[\(Dates.time.string(from: ts))] USER: " + t.collapsedWhitespace.truncated(900))
                }
                if start == nil { start = ts }
                end = ts
            } else if type == "event_msg", p["type"] as? String == "task_complete" {
                guard var msg = (p["last_agent_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty else { continue }
                if let inner = tag("message", in: msg) {
                    let decision = tag("decision", in: msg).map { "[\($0)] " } ?? ""
                    msg = decision + inner
                }
                // Codex's own permission-review verdicts are JSON blobs; skip them.
                if msg.hasPrefix("{") { continue }
                turns.append("CODEX: " + msg.collapsedWhitespace.truncated(1_500))
                if start == nil { start = ts }
                end = ts
            }
        }
        guard let s = start, let e = end, !turns.isEmpty else { return nil }
        if let a = automation { title = automationNames[a] ?? a }
        return Thread(title: title.isEmpty ? "Codex" : title, start: s, end: e, turns: turns, isAutomation: automation != nil)
    }

    private static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
