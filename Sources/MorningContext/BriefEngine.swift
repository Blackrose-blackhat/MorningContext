import Foundation

/// Orchestrates one brief: decide the window → collect raw context → summarize → persist.
final class BriefEngine {

    struct Brief {
        var dayKey: String
        var windowStart: Date
        var windowEnd: Date
        var markdown: String
        var spokenScript: String
        var sourcesLine: String
        var rawContext: String
        var generatedAt: Date
    }

    enum Phase: Equatable {
        case idle
        case collecting
        /// Waiting on Claude to answer the gather questions (names still running).
        case gathering(String)
        case summarizing(chars: Int)
        case done
        case failed(String)
    }

    /// Everything since the start of the day `lookbackDays` ago — or since the last brief
    /// if that was longer ago (e.g. Monday morning covers the whole weekend), capped at 7 days.
    static func window(now: Date = Date()) -> (Date, Date) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        var from = cal.date(byAdding: .day, value: -Settings.lookbackDays, to: startOfToday)!
        if let last = Settings.lastBriefWindowEnd, last < from {
            from = max(last, cal.date(byAdding: .day, value: -7, to: startOfToday)!)
        }
        return (from, now)
    }

    static func windowLabel(_ from: Date, _ to: Date) -> String {
        "\(Dates.dayTime.string(from: from)) → \(Dates.dayTime.string(from: to))"
    }

    /// Blocking; run on a background queue. `progress` is called on the calling thread.
    static func generate(progress: (Phase) -> Void) -> Result<Brief, Error> {
        let (from, to) = window()
        let label = windowLabel(from, to)
        progress(.collecting)

        let budget = Settings.maxContextChars
        let wispr  = Settings.wisprEnabled ? WisprFlowReader.digest(from: from, to: to, charBudget: budget * 25 / 100)
                                           : WisprFlowReader.Result(dbFound: false, error: "Turned off in the control panel")
        let files  = TranscriptFolderReader.digest(from: from, to: to, charBudget: budget / 10)
        let codex  = Settings.codexEnabled ? CodexReader.digest(from: from, to: to, charBudget: budget * 15 / 100) : CodexReader.Result(threads: [], text: "", filesScanned: 0)

        // The brain: Claude looks at what happened and what it (and Codex) can reach today, and plans the checks.
        // If planning fails, fall back to the trackers found in your history. Everything lands before the brief is
        // written; nothing is fetched mid-conversation.
        var plan: IntakePlanner.Plan?
        if Settings.gatherEnabled && Settings.plannerEnabled {
            progress(.gathering("planning what to check"))
            let outline = IntakePlanner.outline(claude: ClaudeCodeReader.digest(from: from, to: to, charBudget: 1), codex: codex, wispr: wispr)
            plan = IntakePlanner.plan(outline: outline, since: from, repos: LiveChecks.discover())
        }
        let gatherSources = !Settings.gatherEnabled ? [] : (plan.map(IntakePlanner.sources) ?? Gather.detect())
        let gatherStarted = Date()
        let answers = Gather.Run(sources: gatherSources, since: from).wait { running in progress(.gathering(running.joined(separator: ", "))) }
        let gathered = answers.isEmpty ? "" : Gather.render(answers, at: gatherStarted)
        if !answers.isEmpty { Gather.saveStatus(answers, at: gatherStarted) }
        if let plan { IntakePlanner.record(plan, answers: answers) }
        // Claude Code gets what's left (at least ~45%).
        let claude = ClaudeCodeReader.digest(from: from, to: to, charBudget: max(budget * 45 / 100,
            budget - wispr.text.count - wispr.todayText.count - files.text.count - codex.text.count - gathered.count))

        var sources: [String] = []
        sources.append("\(claude.sessions.count) Claude Code session\(claude.sessions.count == 1 ? "" : "s")")
        if wispr.dbFound {
            sources.append("\(wispr.meetings.count) meeting\(wispr.meetings.count == 1 ? "" : "s")")
            sources.append("\(wispr.entries.count) dictation\(wispr.entries.count == 1 ? "" : "s")")
            if !wispr.notes.isEmpty { sources.append("\(wispr.notes.count) note\(wispr.notes.count == 1 ? "" : "s")") }
        } else {
            sources.append("Wispr Flow DB not found")
        }
        if !codex.threads.isEmpty {
            let autos = codex.threads.filter(\.isAutomation).count
            sources.append("\(codex.threads.count - autos) Codex session\(codex.threads.count - autos == 1 ? "" : "s")" + (autos > 0 ? " + \(autos) automation\(autos == 1 ? "" : "s")" : ""))
        }
        for a in answers { sources.append(a.text != nil ? a.source.name : "\(a.source.name) unavailable") }
        if Settings.extraTranscriptsDir != nil { sources.append("\(files.files) transcript file\(files.files == 1 ? "" : "s")") }
        let sourcesLine = sources.joined(separator: " · ")

        var raw = ""
        if !wispr.todayText.isEmpty { raw += "## TODAY'S CALENDAR\n\n" + wispr.todayText + "\n\n" }
        if !gathered.isEmpty { raw += "## WORK TRACKERS & EMAIL (asked Claude at \(Dates.time.string(from: gatherStarted)); as of then)\n\n" + gathered + "\n" }
        if !claude.text.isEmpty { raw += "## CLAUDE CODE SESSIONS\n\n" + claude.text + "\n" }
        if !codex.text.isEmpty  { raw += "## CODEX SESSIONS & AUTOMATIONS\n\n" + codex.text + "\n" }
        if !wispr.text.isEmpty  { raw += "## WISPR FLOW MEETINGS, NOTES & DICTATIONS\n\n" + wispr.text + "\n" }
        if !files.text.isEmpty  { raw += "## TRANSCRIPT FILES\n\n" + files.text + "\n" }
        raw = Secrets.redact(raw)

        let dayKey = Dates.dayKey.string(from: to)

        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var md = "## Nothing recorded\n\nNo Claude Code sessions or Wispr Flow dictations were found for **\(label)**.\n\n"
            if let e = wispr.error { md += "- Wispr Flow: \(e)\n" }
            if claude.filesScanned == 0 { md += "- Claude Code: no session files modified in this window under `~/.claude/projects`\n" }
            md += "\nIf that's wrong, check the paths in **Settings…** from the menu bar icon."
            let spoken = "Good morning. I didn't find any Claude Code sessions or Wispr Flow dictations for \(label), so there's nothing to brief you on. Have a good day."
            let brief = Brief(dayKey: dayKey, windowStart: from, windowEnd: to, markdown: md, spokenScript: spoken, sourcesLine: sourcesLine, rawContext: "", generatedAt: Date())
            BriefStore.save(brief)
            progress(.done)
            return .success(brief)
        }

        progress(.summarizing(chars: raw.count))
        do {
            let full = try Summarizer.summarize(context: raw, windowLabel: label)
            let (md, spoken) = split(full)
            let brief = Brief(dayKey: dayKey, windowStart: from, windowEnd: to, markdown: md, spokenScript: spoken, sourcesLine: sourcesLine, rawContext: raw, generatedAt: Date())
            BriefStore.save(brief)
            Settings.lastBriefWindowEnd = to
            progress(.done)
            return .success(brief)
        } catch {
            // Still persist the raw digest so nothing is lost; show it as a fallback.
            let md = "## Summary unavailable\n\n\(error.localizedDescription)\n\nShowing the raw digest instead:\n\n---\n\n" + raw.truncated(30_000)
            let spoken = "Good morning. I couldn't reach Claude to write your brief, so I'm showing you the raw notes from \(label) in the window instead."
            let brief = Brief(dayKey: dayKey, windowStart: from, windowEnd: to, markdown: md, spokenScript: spoken, sourcesLine: sourcesLine + " · summarizer failed", rawContext: raw, generatedAt: Date())
            BriefStore.save(brief)
            progress(.failed(error.localizedDescription))
            return .success(brief)
        }
    }
}

extension BriefEngine {
    static let spokenMarker = "=====SPOKEN====="

    /// Splits Claude's output into (markdown brief, spoken script). If the model
    /// forgot the marker, the spoken script is the brief itself with Markdown stripped.
    static func split(_ full: String) -> (String, String) {
        if let r = full.range(of: spokenMarker) {
            let md = String(full[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = String(full[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { return (md, Speaker.stripMarkdown(spoken)) }
        }
        return (full, Speaker.stripMarkdown(full))
    }
}

/// Briefs live as plain Markdown in ~/Library/Application Support/MorningContext/briefs/
/// so you can grep them, sync them, or feed them back into Claude.
enum BriefStore {
    static func url(for dayKey: String) -> URL { Settings.briefsDir.appendingPathComponent("\(dayKey).md") }

    static func save(_ b: BriefEngine.Brief) {
        let header = """
        <!-- MorningContext brief · generated \(Dates.dayTime.string(from: b.generatedAt)) · window \(BriefEngine.windowLabel(b.windowStart, b.windowEnd)) · \(b.sourcesLine) -->
        # Morning brief — \(Dates.longDay.string(from: b.windowEnd))

        """
        let body = header + b.markdown + "\n\n## Spoken script\n\n" + b.spokenScript + "\n"
        try? body.write(to: url(for: b.dayKey), atomically: true, encoding: .utf8)
        if !b.rawContext.isEmpty {
            try? b.rawContext.write(to: Settings.briefsDir.appendingPathComponent("\(b.dayKey).context.md"), atomically: true, encoding: .utf8)
        }
    }

    /// The raw digest the brief was written from (what the voice companion answers follow-ups from).
    static func loadContext(dayKey: String) -> String? {
        (try? String(contentsOf: Settings.briefsDir.appendingPathComponent("\(dayKey).context.md"), encoding: .utf8)).map(Secrets.redact)
    }

    /// When a saved brief was written — the "as of" time for everything in it.
    static func generatedAt(dayKey: String) -> Date? {
        (try? url(for: dayKey).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Returns (markdown, spoken script) for a saved brief.
    static func load(dayKey: String) -> (String, String)? {
        guard let s = try? String(contentsOf: url(for: dayKey), encoding: .utf8) else { return nil }
        if let r = s.range(of: "\n## Spoken script\n") {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (s, Speaker.stripMarkdown(s))
    }
}
