# Morning Context

[![CI](https://github.com/Blackrose-blackhat/MorningContext/actions/workflows/ci.yml/badge.svg)](https://github.com/Blackrose-blackhat/MorningContext/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Blackrose-blackhat/MorningContext)](https://github.com/Blackrose-blackhat/MorningContext/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)

A tiny native macOS menu bar app that picks up where you left off. When you open your laptop in the
morning it reads what you did yesterday — your **Claude Code** and **Codex** sessions, your
**Wispr Flow** meetings and dictations — asks Claude to write a brief, and reads it to you. Then you can
just talk to it about your day.

- **One brief per day**, generated on the first wake after a set hour, saved as Markdown.
- **Spoken**, with on-device voices or ElevenLabs, and a live voice companion you can interrupt.
- **No API key needed**: it runs through your existing, logged-in `claude` CLI.
- **Local first**: everything is read from your Mac; secrets are redacted before anything is sent.

## Install

### From a release

1. Download the latest `MorningContext-*.zip` from [Releases](https://github.com/Blackrose-blackhat/MorningContext/releases/latest).
2. Unzip and move **MorningContext.app** to `/Applications`.
3. The app is ad-hoc signed, not notarized, so the first time right-click it → **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MorningContext.app
   ```

### From source

```sh
git clone https://github.com/Blackrose-blackhat/MorningContext.git
cd MorningContext
./build.sh --install
```

### Requirements

- macOS 13+ (Apple's new on-device speech model is used on macOS 26+). Building needs the macOS 26 SDK
  (Xcode 26 or its Command Line Tools: `xcode-select --install`).
- The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code), logged in (`claude` works in Terminal).
- Optional: [Wispr Flow](https://wisprflow.ai), Codex, an ElevenLabs account.

The app appears as a **sunrise icon** in the menu bar. Open **Control Panel…** and turn on
**Launch at login** so it's running when the lid opens. Use **Check Sources…** to confirm what it
finds on your Mac before the first morning.

## What it reads

| Source | Where | How |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | Every user/assistant turn in the window, plus which tools/files were touched, grouped by repo and branch. Tool output is dropped as noise. |
| Codex | `~/.codex/sessions/**/*.jsonl` | What you asked, what Codex answered, and what scheduled automation runs found. |
| Wispr Flow | `~/Library/Application Support/Wispr Flow/flow.sqlite` | Meetings (summary, notes, speaker-labelled transcript), notes, dictations grouped by app and time, and today's calendar. Opened read-only/immutable so it never blocks Wispr Flow. |
| Extra folder (optional) | whatever you set | `.txt/.md/.vtt/.srt/.json` files modified in the window — handy if a meeting recorder exports transcripts. |
| Trackers & email (optional) | via Claude Code / Codex | Each morning Claude plans what's worth checking with the connectors you already have (Jira, Azure Boards, Gmail, …) and runs those checks read-only, in parallel, in the repo they belong to. |

## How "every morning" works

The app listens for `NSWorkspace.didWakeNotification` (lid open → wake), `screensDidWake`, and the
screen-unlock event, plus a 15-minute poll as a safety net. The first trigger of a calendar day after the
*earliest hour* (default 04:00) generates and shows the brief; later wakes that day do nothing.
**Show Today's Brief** reopens it, **Regenerate Now** rebuilds it.

The window covers *yesterday 00:00 → now* by default. If the last brief was older (e.g. Monday
morning), it extends back to the end of the last brief, up to 7 days.

## Summarization

`claude -p --output-format text` is run from your login shell with the raw digest on stdin, in a neutral
working directory (so no project `CLAUDE.md` leaks in). Set a model or extra instructions in the Control
Panel. If the CLI fails, the raw digest is shown instead so nothing is lost.

Context is capped (default 120k characters); long sessions keep their beginning and end so the goal and
the "where I left off" survive. API keys, tokens and passwords are redacted before anything is sent or saved.

## Voice

Claude writes two things in one call: the Markdown brief and a ~2-minute spoken script. The script is read
with macOS's built-in speech engine (offline, no key) or, if you add an API key, an
[ElevenLabs](https://elevenlabs.io) voice (the key is stored in the Keychain).

For a much nicer built-in voice, download a **Premium** or **Enhanced** one: System Settings →
Accessibility → Spoken Content → System Voice → Manage Voices. Fix names it mispronounces under
**Pronunciation** (`word = how to say it`).

**Talk to Me** (⌃⌥M) opens the voice companion: a floating panel that walks you through yesterday and
answers follow-ups. Interrupt any time by talking (echo cancellation keeps the mic open), tapping the orb,
or pressing Space. Speech recognition runs on-device. It can run read-only live checks (e.g. a PR's
status with `gh`) and hand work off to **Claude Jobs**: headless Claude Code runs in a fresh git
worktree that commit locally and **never push**.

## Files

- Briefs: `~/Library/Application Support/MorningContext/briefs/YYYY-MM-DD.md`
  (+ `YYYY-MM-DD.context.md` with the raw digest that was sent)
- Log: `~/Library/Application Support/MorningContext/app.log`

## Project layout

```
Package.swift
Sources/MorningContext/
  main.swift             app entry (accessory app, no Dock icon)
  AppDelegate.swift      menu bar, wake listeners, once-per-day logic, windows
  BriefEngine.swift      window selection → collect → summarize → save
  ClaudeCodeReader.swift ~/.claude/projects JSONL parser
  CodexReader.swift      ~/.codex/sessions JSONL parser
  WisprFlowReader.swift  Wispr Flow SQLite reader (+ extra transcript folder)
  IntakePlanner.swift    Claude decides which trackers/inboxes are worth checking today
  Gather.swift           runs those checks headless via Claude Code / Codex
  Summarizer.swift       claude -p runner + prompt (brief + spoken script)
  Conversation.swift     live multi-turn conversation (claude -p stream-json)
  ClaudeJobs.swift       hand-off of work to headless Claude Code in git worktrees
  Speech.swift           on-device speech recognition, vocabulary, pronunciation
  AudioIO.swift          shared audio engine with echo cancellation
  Speaker.swift          text-to-speech (AVSpeechSynthesizer)
  CloudVoice.swift       ElevenLabs text-to-speech + Keychain
  VoicePanel.swift       floating voice companion UI
  BriefView.swift        brief window and Markdown renderer
  ControlPanel.swift     settings / control panel
  Settings.swift         UserDefaults-backed settings, secret redaction, helpers
Tests/MorningContextTests unit tests (Swift Testing)
build.sh                 swift build → .app bundle → /Applications
scripts/test.sh          runs the tests (works with Command Line Tools only)
```

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and please report security
issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
