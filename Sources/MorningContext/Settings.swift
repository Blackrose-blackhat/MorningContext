import Foundation

/// All user-tunable settings, backed by UserDefaults so the SwiftUI settings
/// window (@AppStorage) and the rest of the app share one source of truth.
enum Settings {
    static let defaults = UserDefaults.standard

    enum Key {
        static let wisprDBPath          = "wisprDBPath"
        static let extraTranscriptsDir  = "extraTranscriptsDir"
        static let claudeModel          = "claudeModel"
        static let startHour            = "startHour"
        static let lookbackDays         = "lookbackDays"
        static let maxContextChars      = "maxContextChars"
        static let lastBriefDate        = "lastBriefDate"
        static let lastBriefWindowEnd   = "lastBriefWindowEnd"
        static let extraInstructions    = "extraInstructions"
        static let autoSpeak            = "autoSpeak"
        static let voiceIdentifier      = "voiceIdentifier"
        static let speechRate           = "speechRate"
        static let talkOnMorning        = "talkOnMorning"
        static let autoListen           = "autoListen"
        static let conversationModel    = "conversationModel"
        static let elevenLabsVoiceId    = "elevenLabsVoiceId"
        static let pronunciations       = "pronunciations"
        static let gatherEnabled        = "gatherEnabled"
        static let codexEnabled         = "codexEnabled"
        static let disabledGatherSources = "disabledGatherSources"
        static let wisprEnabled         = "wisprEnabled"
        static let handoffEnabled       = "handoffEnabled"
        static let elevenLabsVoiceName  = "elevenLabsVoiceName"
        static let handsFree            = "handsFree"
        static let plannerEnabled       = "plannerEnabled"
        static let intakeRules          = "intakeRules"
        static let onboarded            = "onboarded"
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var defaultWisprDBPath: String {
        home.appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite").path
    }

    /// Wispr Flow keeps meeting transcripts as files next to its database: meetings/<meetingId>/refined.ndjson
    static var wisprMeetingsDir: URL {
        URL(fileURLWithPath: wisprDBPath).deletingLastPathComponent().appendingPathComponent("meetings")
    }

    static var claudeProjectsDir: URL {
        home.appendingPathComponent(".claude/projects")
    }

    static var appSupportDir: URL {
        let url = home.appendingPathComponent("Library/Application Support/MorningContext")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var briefsDir: URL {
        let url = appSupportDir.appendingPathComponent("briefs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A neutral working directory for `claude -p`, so no project CLAUDE.md leaks in.
    static var claudeWorkDir: URL {
        let url = appSupportDir.appendingPathComponent("claude-workdir")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var wisprDBPath: String {
        let v = defaults.string(forKey: Key.wisprDBPath) ?? ""
        return v.isEmpty ? defaultWisprDBPath : (v as NSString).expandingTildeInPath
    }

    static var extraTranscriptsDir: String? {
        let v = defaults.string(forKey: Key.extraTranscriptsDir) ?? ""
        return v.isEmpty ? nil : (v as NSString).expandingTildeInPath
    }

    static var claudeModel: String {
        defaults.string(forKey: Key.claudeModel) ?? ""
    }

    static var extraInstructions: String {
        defaults.string(forKey: Key.extraInstructions) ?? ""
    }

    /// Don't show the brief before this hour (so a 1am wake-up doesn't count as "morning").
    static var startHour: Int {
        defaults.object(forKey: Key.startHour) == nil ? 4 : defaults.integer(forKey: Key.startHour)
    }

    /// Minimum number of days to look back (1 = yesterday).
    static var lookbackDays: Int {
        let v = defaults.integer(forKey: Key.lookbackDays)
        return v == 0 ? 1 : v
    }

    static var maxContextChars: Int {
        let v = defaults.integer(forKey: Key.maxContextChars)
        return v == 0 ? 120_000 : v
    }

    /// Read the brief aloud automatically when it's ready (default on).
    static var autoSpeak: Bool {
        defaults.object(forKey: Key.autoSpeak) == nil ? true : defaults.bool(forKey: Key.autoSpeak)
    }

    static var voiceIdentifier: String {
        defaults.string(forKey: Key.voiceIdentifier) ?? ""
    }

    /// AVSpeechUtterance rate, 0…1. 0.5 is the system default pace.
    static var speechRate: Float {
        let v = defaults.double(forKey: Key.speechRate)
        return v == 0 ? 0.5 : Float(v)
    }

    /// Morning flow: open the voice pill and talk it through (default), instead of the brief window.
    static var talkOnMorning: Bool {
        defaults.object(forKey: Key.talkOnMorning) == nil ? true : defaults.bool(forKey: Key.talkOnMorning)
    }

    /// After a spoken reply that ends in a question, start listening without a tap.
    static var autoListen: Bool {
        defaults.object(forKey: Key.autoListen) == nil ? true : defaults.bool(forKey: Key.autoListen)
    }

    /// Model for the live conversation; a fast one keeps replies snappy.
    static var conversationModel: String {
        let v = defaults.string(forKey: Key.conversationModel) ?? ""
        return v.isEmpty ? "sonnet" : v
    }

    /// "word = how to say it", one per line: project names, people, acronyms the voice gets wrong.
    static let defaultPronunciations = """
    kubectl = cube control
    nginx = engine X
    Siobhan = Shiv-awn
    SQL = sequel
    """

    static var pronunciations: String {
        defaults.string(forKey: Key.pronunciations) ?? defaultPronunciations
    }

    /// Ask Claude about Jira / Azure Boards / Gmail while preparing the brief.
    static var gatherEnabled: Bool {
        defaults.object(forKey: Key.gatherEnabled) == nil ? true : defaults.bool(forKey: Key.gatherEnabled)
    }

    static var wisprEnabled: Bool {
        defaults.object(forKey: Key.wisprEnabled) == nil ? true : defaults.bool(forKey: Key.wisprEnabled)
    }

    /// Let Claude decide each morning what to check (vs. the fixed trackers found in your history).
    static var plannerEnabled: Bool {
        defaults.object(forKey: Key.plannerEnabled) == nil ? true : defaults.bool(forKey: Key.plannerEnabled)
    }

    /// Your standing instructions for the morning checks ("always check Render deploys", "skip CI notification emails").
    static var intakeRules: String { defaults.string(forKey: Key.intakeRules) ?? "" }

    /// Keep the mic open (echo-cancelled) while it talks, so you can interrupt just by speaking.
    static var handsFree: Bool {
        defaults.object(forKey: Key.handsFree) == nil ? true : defaults.bool(forKey: Key.handsFree)
    }

    /// Let the voice companion start background Claude Code jobs.
    static var handoffEnabled: Bool {
        defaults.object(forKey: Key.handoffEnabled) == nil ? false : defaults.bool(forKey: Key.handoffEnabled)   // opt-in: it edits code
    }

    /// Finished the first-run welcome. Until then nothing runs on its own.
    static var onboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    /// Read Codex sessions and automation runs.
    static var codexEnabled: Bool {
        defaults.object(forKey: Key.codexEnabled) == nil ? true : defaults.bool(forKey: Key.codexEnabled)
    }

    /// Gather source ids switched off in Settings (e.g. "gmail", "tracker:atlas").
    static var disabledGatherSources: [String] {
        get { defaults.stringArray(forKey: Key.disabledGatherSources) ?? [] }
        set { defaults.set(newValue, forKey: Key.disabledGatherSources) }
    }

    static var lastBriefDate: String? {
        get { defaults.string(forKey: Key.lastBriefDate) }
        set { defaults.set(newValue, forKey: Key.lastBriefDate) }
    }

    static var lastBriefWindowEnd: Date? {
        get { defaults.object(forKey: Key.lastBriefWindowEnd) as? Date }
        set { defaults.set(newValue, forKey: Key.lastBriefWindowEnd) }
    }
}

// MARK: - Shared date helpers

enum Dates {
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f
    }()

    static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Formats with an explicit offset come first: Wispr Flow (Sequelize) writes `2026-10-19 16:51:52.412 +00:00`.
    /// Formats without one are read as UTC.
    private static let sqlFormats: [DateFormatter] = {
        return ["yyyy-MM-dd HH:mm:ss.SSS xxx", "yyyy-MM-dd HH:mm:ss xxx", "yyyy-MM-dd HH:mm:ss.SSSxxx", "yyyy-MM-dd HH:mm:ssxxx",
                "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"].map {
            let f = DateFormatter()
            f.dateFormat = $0
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }
    }()

    /// Parses the many timestamp shapes found in JSONL logs and SQLite stores.
    static func parse(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let d = raw as? Date { return d }
        if let n = raw as? Double { return fromNumber(n) }
        if let n = raw as? Int { return fromNumber(Double(n)) }
        if let n = raw as? Int64 { return fromNumber(Double(n)) }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let d = isoFrac.date(from: t) ?? iso.date(from: t) { return d }
            for f in sqlFormats { if let d = f.date(from: t) { return d } }
            if let n = Double(t) { return fromNumber(n) }
        }
        return nil
    }

    private static func fromNumber(_ n: Double) -> Date? {
        if n <= 0 { return nil }
        if n > 1e14 { return Date(timeIntervalSince1970: n / 1_000_000) } // microseconds
        if n > 1e11 { return Date(timeIntervalSince1970: n / 1_000) }     // milliseconds
        return Date(timeIntervalSince1970: n)                             // seconds
    }
}

/// Splits a character budget across blocks of different sizes ("water-filling"): small blocks
/// get all they need, the rest share what's left equally. Nothing is dropped just for coming last.
enum Budget {
    static func fairCaps(sizes: [Int], budget: Int) -> [Int] {
        guard !sizes.isEmpty else { return [] }
        var remaining = budget
        var caps = Array(repeating: 0, count: sizes.count)
        var open = Array(sizes.indices).sorted { sizes[$0] < sizes[$1] }
        while !open.isEmpty {
            let share = remaining / open.count
            let i = open[0]
            if sizes[i] <= share {
                caps[i] = sizes[i]; remaining -= sizes[i]; open.removeFirst()
            } else {
                for j in open { caps[j] = share }
                break
            }
        }
        return caps
    }
}

/// API keys, tokens and passwords that show up in session logs or dictation must never reach a brief,
/// the summarizer, or the voice conversation.
enum Secrets {
    private static let patterns: [NSRegularExpression] = [
        "\\bsk[-_](?:ant-|proj-|live_|test_)?[A-Za-z0-9_-]{20,}",   // Anthropic, OpenAI, ElevenLabs, Stripe
        "\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}",             // GitHub tokens
        "\\bgithub_pat_[A-Za-z0-9_]{30,}",
        "\\bAKIA[0-9A-Z]{16}\\b",                                  // AWS access key id
        "\\bAIza[0-9A-Za-z_-]{35}\\b",                             // Google API key
        "\\bxox[abprs]-[A-Za-z0-9-]{10,}",                          // Slack
        "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", // JWTs
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
        "(?i)\\b(api[_-]?key|secret|token|passw(?:or)?d|pat)\\b(\\s*[:=]\\s*[\"']?)[^\\s\"']{8,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ text: String) -> String {
        var out = text
        for re in patterns {
            let range = NSRange(out.startIndex..., in: out)
            // Keep "api_key=" so the context still reads naturally; drop only the value.
            let template = re.numberOfCaptureGroups >= 2 ? "$1$2[REDACTED]" : "[REDACTED]"
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}

extension String {
    /// Keeps the beginning (the goal) and the end (where it was left off), dropping the middle.
    func headTail(_ cap: Int, marker: String = "\n…[middle omitted]…\n") -> String {
        if count <= cap { return self }
        let keep = max(0, cap - marker.count)
        return String(prefix(keep * 3 / 5)) + marker + String(suffix(keep * 2 / 5))
    }
    func truncated(_ max: Int) -> String {
        if count <= max { return self }
        return String(prefix(max)) + " …[truncated]"
    }
    var collapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
