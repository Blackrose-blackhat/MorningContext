import Foundation
import SQLite3

/// Reads Wispr Flow's local store (~/Library/Application Support/Wispr Flow/flow.sqlite):
///   - `Meetings` + meetings/<id>/refined.ndjson → title, participants, Wispr's own summary, your notes,
///     and the speaker-labelled transcript
///   - `Notes` → notes you wrote or edited in the window
///   - `History` → dictations, grouped into "conversations" by app and time
///   - `CalendarEvents` → what's on today (only events Wispr's notetaker knows about)
enum WisprFlowReader {

    struct Entry {
        var time: Date
        var app: String
        var duration: Double
        var text: String
        var conversationId: String
    }

    struct Meeting {
        var id: String
        var title: String
        var start: Date
        var end: Date?
        var participants: [String]
        var summary: String
        var notes: String
        var transcript: String
        var transcriptLines: Int
    }

    struct Note {
        var title: String
        var modified: Date
        var content: String
    }

    struct CalendarEvent {
        var title: String
        var start: Date
        var end: Date?
        var participants: [String]
    }

    struct Result {
        var entries: [Entry] = []
        var meetings: [Meeting] = []
        var notes: [Note] = []
        var today: [CalendarEvent] = []
        var text: String = ""
        var todayText: String = ""
        var dbFound: Bool
        var error: String? = nil
    }

    static func digest(from: Date, to: Date, charBudget: Int) -> Result {
        let path = Settings.wisprDBPath
        guard FileManager.default.fileExists(atPath: path) else {
            return Result(dbFound: false, error: "No database at \(path)")
        }
        guard let db = open(path: path) else {
            return Result(dbFound: true, error: "Could not open Wispr Flow DB at \(path)")
        }
        defer { sqlite3_close(db) }

        var r = Result(dbFound: true)
        r.meetings = readMeetings(db: db, from: from, to: to)
        r.notes = readNotes(db: db, from: from, to: to)
        r.entries = readHistory(db: db, from: from, to: to)
        r.today = readCalendar(db: db, day: to)
        r.text = render(meetings: r.meetings, notes: r.notes, entries: r.entries, charBudget: charBudget)
        r.todayText = renderCalendar(r.today)
        return r
    }

    /// Plain read-only first: Wispr Flow uses WAL, so a reader never blocks it, and this sees
    /// dictations still sitting in flow.sqlite-wal. `immutable=1` (ignores the WAL) is only a fallback.
    private static func open(path: String) -> OpaquePointer? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        for uri in ["file:\(encoded)?mode=ro", "file:\(encoded)?immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 2_000)
                var ok = false
                query(db: db, sql: "SELECT count(*) FROM sqlite_master") { _ in ok = true }
                if ok { return db }
                sqlite3_close(db)
            } else if let db {
                sqlite3_close(db)
            }
        }
        return nil
    }

    // MARK: Meetings

    private static func readMeetings(db: OpaquePointer, from: Date, to: Date) -> [Meeting] {
        let cols = columns(db: db, table: "Meetings")
        guard !cols.isEmpty else { return [] }
        func col(_ c: String, _ fallback: String = "NULL") -> String { cols.contains(c) ? "\"\(c)\"" : fallback }

        let sql = """
        SELECT \(col("id")), \(col("title")), \(col("createdAt")), \(col("endedAt")), \(col("participantNames")),
               \(col("summary")), \(col("notes")), \(col("speakerMap"))
        FROM "Meetings" WHERE \(col("isDeleted", "0")) IS NOT 1 ORDER BY \(col("createdAt", "rowid"))
        """
        var out: [Meeting] = []
        query(db: db, sql: sql) { stmt in
            guard let id = value(stmt, 0) as? String, let start = Dates.parse(value(stmt, 2)) else { return }
            let end = Dates.parse(value(stmt, 3))
            // Overlaps the window: started before it ends, and ended (or started) after it begins.
            guard start <= to, (end ?? start) >= from else { return }

            let speakers = speakerNames(json: value(stmt, 7) as? String)
            var participants = jsonStrings(value(stmt, 4) as? String)
            for name in speakers.values.sorted() where !participants.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                participants.append(name)
            }
            let (transcript, lines) = readTranscript(meetingId: id, speakers: speakers)
            let title = (value(stmt, 1) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(Meeting(
                id: id,
                title: title.isEmpty ? "Untitled meeting" : title,
                start: start, end: end,
                participants: participants,
                summary: tidy((value(stmt, 5) as? String) ?? "", speakers: speakers),
                notes: tidy((value(stmt, 6) as? String) ?? "", speakers: speakers),
                transcript: transcript, transcriptLines: lines
            ))
        }
        return out
    }

    /// speakerMap = {"people": {personId: {"name"}}, "assignments": {"1": {"user"|"consensus"|…: personId}}}
    /// → ["1": "Siobhan K", …]
    private static func speakerNames(json: String?) -> [String: String] {
        guard let json, let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let people = obj["people"] as? [String: [String: Any]],
              let assignments = obj["assignments"] as? [String: [String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for (speaker, a) in assignments {
            let personId = ["user", "consensus", "dom", "mic", "llm"].lazy.compactMap { a[$0] as? String }.first
            if let personId, let name = people[personId]?["name"] as? String, !name.isEmpty { out[speaker] = name }
        }
        return out
    }

    /// Wispr's summaries are Markdown with their own `###` headings and `<@speaker:2>` mentions.
    /// Headings become bold lines so they can't be mistaken for digest blocks; mentions become names.
    private static func tidy(_ text: String, speakers: [String: String]) -> String {
        var s = text
        if let re = try? NSRegularExpression(pattern: "<@speaker:(\\d+)>") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let whole = Range(m.range, in: s), let id = Range(m.range(at: 1), in: s) else { continue }
                s.replaceSubrange(whole, with: speakers[String(s[id])] ?? "Speaker \(s[id])")
            }
        }
        return s.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return line }
            return "**" + t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**"
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// refined.ndjson (cleaned-up, diarised) is preferred; live.ndjson is what was captured during the call.
    /// Consecutive lines from the same speaker are merged into one turn.
    private static func readTranscript(meetingId: String, speakers: [String: String]) -> (String, Int) {
        let dir = Settings.wisprMeetingsDir.appendingPathComponent(meetingId)
        for file in ["refined.ndjson", "live.ndjson"] {
            guard let content = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            var turns: [(speaker: String, stamp: String, text: String)] = []
            var lines = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                lines += 1
                let sp = o["speaker"] as? [String: Any]
                let spId = (sp?["id"]).map { "\($0)" } ?? "?"
                let name = (sp?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? speakers[spId] ?? "Speaker \(spId)"
                if let last = turns.last, last.speaker == name {
                    turns[turns.count - 1].text += " " + text
                } else {
                    turns.append((name, (o["timestamp"] as? String) ?? "", text))
                }
            }
            if !turns.isEmpty {
                return (turns.map { "[\($0.stamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n"), lines)
            }
        }
        return ("", 0)
    }

    // MARK: Notes

    private static func readNotes(db: OpaquePointer, from: Date, to: Date) -> [Note] {
        let cols = columns(db: db, table: "Notes")
        guard cols.contains("modifiedAt") || cols.contains("createdAt") else { return [] }
        let ts = cols.contains("modifiedAt") ? "modifiedAt" : "createdAt"
        let body = cols.contains("content") ? "content" : (cols.contains("contentPreview") ? "contentPreview" : nil)
        guard let body else { return [] }
        let title = cols.contains("title") ? "\"title\"" : "''"
        let notDeleted = cols.contains("isDeleted") ? "WHERE \"isDeleted\" IS NOT 1" : ""
        var out: [Note] = []
        query(db: db, sql: "SELECT \"\(ts)\", \(title), \"\(body)\" FROM \"Notes\" \(notDeleted) ORDER BY \"\(ts)\"") { stmt in
            guard let t = Dates.parse(value(stmt, 0)), t >= from, t <= to,
                  let c = value(stmt, 2) as? String, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out.append(Note(title: (value(stmt, 1) as? String) ?? "", modified: t, content: c))
        }
        return out
    }

    // MARK: History (dictations)

    private static func readHistory(db: OpaquePointer, from: Date, to: Date) -> [Entry] {
        let cols = columns(db: db, table: "History")
        guard !cols.isEmpty else { return [] }

        func has(_ c: String) -> Bool { cols.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }

        // Best available text, in preference order.
        var textExprs: [String] = []
        for c in ["editedText", "formattedText", "asrText", "text", "transcript"] where has(c) {
            textExprs.append("NULLIF(\"\(c)\", '')")
        }
        guard !textExprs.isEmpty else { return [] }
        let textExpr = textExprs.count == 1 ? textExprs[0] : "COALESCE(\(textExprs.joined(separator: ", ")))"

        let tsCol = ["timestamp", "createdAt", "created_at", "date", "time"].first(where: has) ?? cols[0]
        let appCol = has("app") ? "\"app\"" : "''"
        let durCol = has("duration") ? "\"duration\"" : "0"
        let convCol = has("conversationId") ? "\"conversationId\"" : "''"
        let notArchived = has("isArchived") ? " AND \"isArchived\" IS NOT 1" : ""

        let sql = "SELECT \"\(tsCol)\", \(appCol), \(durCol), \(textExpr), \(convCol) FROM \"History\" WHERE \(textExpr) IS NOT NULL\(notArchived) ORDER BY rowid"
        var out: [Entry] = []
        query(db: db, sql: sql) { stmt in
            guard let ts = Dates.parse(value(stmt, 0)), ts >= from, ts <= to else { return }
            let text = (value(stmt, 3) as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out.append(Entry(
                time: ts,
                app: (value(stmt, 1) as? String) ?? "",
                duration: (value(stmt, 2) as? Double) ?? 0,
                text: text,
                conversationId: (value(stmt, 4) as? String) ?? ""
            ))
        }
        out.sort { $0.time < $1.time }
        return out
    }

    // MARK: Calendar (today)

    private static func readCalendar(db: OpaquePointer, day: Date) -> [CalendarEvent] {
        let cols = columns(db: db, table: "CalendarEvents")
        guard cols.contains("startAtUtc"), cols.contains("title") else { return [] }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let endCol = cols.contains("endAtUtc") ? "\"endAtUtc\"" : "NULL"
        let partCol = cols.contains("participantNames") ? "\"participantNames\"" : "NULL"
        let notCancelled = cols.contains("status") ? "WHERE \"status\" IS NOT 'cancelled'" : ""
        var out: [CalendarEvent] = []
        query(db: db, sql: "SELECT \"title\", \"startAtUtc\", \(endCol), \(partCol) FROM \"CalendarEvents\" \(notCancelled) ORDER BY \"startAtUtc\"") { stmt in
            guard let start = Dates.parse(value(stmt, 1)), start >= dayStart, start < dayEnd else { return }
            out.append(CalendarEvent(title: (value(stmt, 0) as? String) ?? "Untitled event", start: start,
                                     end: Dates.parse(value(stmt, 2)), participants: jsonStrings(value(stmt, 3) as? String)))
        }
        return out
    }

    private static func renderCalendar(_ events: [CalendarEvent]) -> String {
        events.map { e in
            var line = "- \(Dates.time.string(from: e.start))"
            if let end = e.end { line += "–\(Dates.time.string(from: end))" }
            line += " \(e.title)"
            if !e.participants.isEmpty { line += " — with \(e.participants.joined(separator: ", "))" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: Rendering

    /// Meetings first (densest signal), then notes, then dictations. The budget is shared fairly
    /// across all blocks; inside a meeting the transcript is trimmed before the summary or notes.
    private static func render(meetings: [Meeting], notes: [Note], entries: [Entry], charBudget: Int) -> String {
        var blocks: [(fixed: String, trimmable: String)] = []

        for m in meetings {
            var header = "### Meeting — \(m.title) (\(Dates.dayTime.string(from: m.start))"
            if let end = m.end { header += " → \(Dates.time.string(from: end))" }
            header += ")\n"
            if !m.participants.isEmpty { header += "Participants: \(m.participants.joined(separator: ", "))\n" }
            if !m.summary.isEmpty { header += "\nWispr Flow's summary:\n\(m.summary)\n" }
            if !m.notes.isEmpty { header += "\nMy notes:\n\(m.notes)\n" }
            let transcript = m.transcript.isEmpty ? "" : "\nTranscript (\(m.transcriptLines) lines):\n" + m.transcript
            blocks.append((header, transcript))
        }

        for n in notes {
            blocks.append(("### Note — \(n.title.isEmpty ? "untitled" : n.title) (edited \(Dates.dayTime.string(from: n.modified)))\n", n.content))
        }

        // Group consecutive dictations (same app, < 10 min apart) so a long dictated message reads as one block.
        var groups: [(start: Date, end: Date, app: String, texts: [String], seconds: Double)] = []
        for e in entries {
            if var last = groups.last, last.app == e.app, e.time.timeIntervalSince(last.end) < 600 {
                last.end = e.time; last.texts.append(e.text); last.seconds += e.duration
                groups[groups.count - 1] = last
            } else {
                groups.append((e.time, e.time, e.app, [e.text], e.duration))
            }
        }
        for g in groups {
            let mins = Int((g.seconds / 60).rounded())
            var header = "### Dictation — \(prettyApp(g.app)) (\(Dates.dayTime.string(from: g.start))"
            if g.end > g.start { header += " → \(Dates.time.string(from: g.end))" }
            if mins > 0 { header += ", ~\(mins) min of speech" }
            header += ")\n"
            blocks.append((header, g.texts.joined(separator: "\n")))
        }

        let caps = Budget.fairCaps(sizes: blocks.map { $0.fixed.count + $0.trimmable.count }, budget: charBudget)
        var out = ""
        for (b, cap) in zip(blocks, caps) {
            let room = cap - b.fixed.count
            if room >= 0 {
                out += b.fixed + b.trimmable.headTail(room) + "\n\n"
            } else {
                out += b.fixed.headTail(max(cap, 400)) + "\n\n"
            }
        }
        return out
    }

    private static func prettyApp(_ bundleId: String) -> String {
        if bundleId.isEmpty { return "unknown app" }
        let known: [String: String] = [
            "com.tinyspeck.slackmacgap": "Slack", "us.zoom.xos": "Zoom", "com.google.Chrome": "Chrome",
            "com.apple.Safari": "Safari", "com.microsoft.teams2": "Teams", "com.apple.Notes": "Notes",
            "com.apple.mail": "Mail", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
            "com.todesktop.230313mzl4w4u92": "Cursor", "com.microsoft.VSCode": "VS Code",
            "com.anthropic.claudefordesktop": "Claude", "notion.id": "Notion", "com.linear": "Linear",
            "company.thebrowser.Browser": "Arc", "net.whatsapp.WhatsApp": "WhatsApp",
        ]
        if let k = known[bundleId] { return k }
        if bundleId.contains("/") { return bundleId }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }

    // MARK: Tiny SQLite / JSON helpers

    private static func jsonStrings(_ json: String?) -> [String] {
        guard let json, let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }.filter { !$0.isEmpty }
    }

    private static func columns(db: OpaquePointer, table: String) -> [String] {
        var cols: [String] = []
        query(db: db, sql: "PRAGMA table_info(\"\(table)\")") { stmt in
            if let n = value(stmt, 1) as? String { cols.append(n) }
        }
        return cols
    }

    private static func query(db: OpaquePointer, sql: String, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func value(_ stmt: OpaquePointer, _ i: Int32) -> Any? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return Double(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:   return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT:    return sqlite3_column_text(stmt, i).map { String(cString: $0) }
        default:             return nil
        }
    }
}

/// Optional: a folder of exported transcripts (.txt/.md/.vtt/.srt/.json), e.g. from
/// a meeting recorder. Any file modified inside the window is included.
enum TranscriptFolderReader {
    static func digest(from: Date, to: Date, charBudget: Int) -> (text: String, files: Int) {
        guard let dir = Settings.extraTranscriptsDir else { return ("", 0) }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return ("", 0) }
        var out = ""; var n = 0
        let exts: Set<String> = ["txt", "md", "vtt", "srt", "json", "markdown"]
        for case let url as URL in en {
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard rv?.isRegularFile == true, let mod = rv?.contentModificationDate, mod >= from, mod <= to else { continue }
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            n += 1
            let block = "### Transcript file — \(url.lastPathComponent) (modified \(Dates.dayTime.string(from: mod)))\n" + s.truncated(min(20_000, charBudget / 2)) + "\n\n"
            if out.count + block.count > charBudget { out += "…[further files omitted]\n"; break }
            out += block
        }
        return (out, n)
    }
}
