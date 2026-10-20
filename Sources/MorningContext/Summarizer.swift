import Foundation

/// Turns the raw digest into a morning brief by shelling out to the Claude Code CLI
/// in headless mode (`claude -p`). Reuses your existing Claude Code login — no API key.
enum Summarizer {

    struct SummarizerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func buildPrompt(context: String, windowLabel: String) -> String {
        var p = """
        You are my morning briefing assistant. It is \(Dates.longDay.string(from: Date())). Below is raw context \
        captured on my Mac for the period: \(windowLabel). It contains (a) Claude Code coding sessions \
        (what I asked, what the agent did, which files/tools it touched, grouped by repo and branch) and (b) Wispr Flow \
        meetings (title, participants, Wispr's own summary, my notes, speaker-labelled transcript), notes and dictations \
        (things I said out loud), (c) Codex sessions and scheduled Codex automation runs (job search, client outreach, \
        lead research: what they found and sent), and (d) WORK TRACKERS & EMAIL: answers Claude gathered this morning from \
        my Jira / Azure Boards and Gmail. It may also start with today's calendar.

        Write me a brief in Markdown so I can pick up exactly where I left off. Use these sections:

        ## Today
        The events from TODAY'S CALENDAR, with time and who's in them. If the raw context has no TODAY'S CALENDAR \
        section, leave this heading out entirely — don't mention it.

        ## TL;DR
        3–5 bullets with the most important things from the period.

        ## What I worked on
        One short block per project. What the goal was, what actually got done, key decisions, and precisely where it was left off (unfinished work, failing tests, open questions).

        ## Tasks & tickets
        From WORK TRACKERS (Jira, Azure Boards): what changed on my items, what's newly assigned, who is waiting on me. \
        Most actionable first, with IDs. Say they're as of the time they were checked.

        ## Inbox
        From EMAIL: replies to my outreach (job applications, clients) and anything that needs my reply. Connect replies \
        to the Codex automation or conversation that started them ("the application your Codex automation sent \
        Monday got a reply"). Skip if nothing.

        ## Meetings & conversations
        One block per meeting: key points, decisions, commitments I made, commitments others made (by name), people involved. Use the transcript to check and sharpen Wispr's summary, not just repeat it.

        ## Open loops for today
        A checklist (- [ ] …) of concrete next actions implied by the above, most important first.

        ## Worth remembering
        Facts, numbers, names, links, or gotchas that will be annoying to re-discover.

        Rules: be concrete and specific (name projects, files, people). Prefer facts over interpretation. Keep the whole brief under ~800 words. \
        If a section has no data, write a single line saying so. Do not ask questions or add preamble.

        THEN, after the Markdown brief, output a line containing exactly `=====SPOKEN=====` followed by a SPOKEN SCRIPT: \
        the same content rewritten as something a friendly assistant would say out loud to me first thing in the morning. \
        Plain prose only — no headings, bullets, Markdown, code, URLs, or file paths (say "the settings file" not "settings.swift"). \
        Start with "Good morning" and the day, then the most important thing, then project by project, then meetings, then what to do first today. \
        Short sentences. Spell out abbreviations the first time. Around 250–350 words (about two minutes of speech). End with one upbeat sentence. \
        Talk like a person, not a report: use contractions (it's, you've, there's), mostly short sentences with the \
        odd longer one, and natural connectors ("So,", "Also,", "One more thing,", "Good news:"). No lists, no brackets, \
        no "firstly / secondly". You may stress at most one word in a sentence by wrapping it in single asterisks, \
        like *two* or *today*; use it rarely, only where a person would lean on the word.
        """
        let extra = Settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { p += "\n\nAdditional instructions from me: \(extra)" }
        p += "\n\n===== RAW CONTEXT =====\n\n" + context + "\n\n===== END OF RAW CONTEXT =====\n"
        return p
    }

    /// Synchronous; call from a background queue.
    static func summarize(context: String, windowLabel: String, timeout: TimeInterval = 300) throws -> String {
        let prompt = buildPrompt(context: context, windowLabel: windowLabel)

        var cmd = "claude -p --output-format text --no-session-persistence " + ClaudeCLI.isolationFlags.map(shellQuote).joined(separator: " ")
        let model = Settings.claudeModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { cmd += " --model \(shellQuote(model))" }

        // Prompt goes through a file (not a stdin pipe) so an early exit of `claude`
        // can never raise a broken-pipe exception inside the app.
        let promptURL = Settings.claudeWorkDir.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        cmd += " < \(shellQuote(promptURL.path))"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Interactive login shell so ~/.zshrc and ~/.zprofile both run and `claude` is found
        // wherever you installed it (brew, npm -g, ~/.local/bin, nvm…).
        proc.arguments = ["-lic", cmd]
        proc.currentDirectoryURL = Settings.claudeWorkDir

        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil          // make sure we aren't mistaken for a nested session
        env["TERM"] = "dumb"
        proc.environment = env

        let stdout = Pipe(), stderr = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdout; proc.standardError = stderr

        try proc.run()

        // Drain pipes on background threads to avoid deadlock on large output.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        proc.waitUntilExit()
        if group.wait(timeout: .now() + 10) == .timedOut {
            // A stray child kept the pipes open; stop waiting for it.
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        killer.cancel()
        try? FileManager.default.removeItem(at: promptURL)

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard proc.terminationStatus == 0 else {
            if err.contains("command not found") {
                throw SummarizerError(message: "The `claude` CLI was not found in your login shell PATH. Install Claude Code (npm install -g @anthropic-ai/claude-code) or run `claude` once in Terminal to confirm it works.")
            }
            throw SummarizerError(message: "claude -p exited with status \(proc.terminationStatus).\n\(err.isEmpty ? out : err)".truncated(2_000))
        }
        guard !out.isEmpty else { throw SummarizerError(message: "claude -p returned no output.\n\(err)".truncated(2_000)) }
        return out
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
