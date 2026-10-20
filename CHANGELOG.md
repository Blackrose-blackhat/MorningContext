# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-20

First public release.

### Added
- Menu bar app that generates one morning brief per day on the first wake/unlock after a configurable hour.
- Context readers for Claude Code sessions, Codex sessions and automations, Wispr Flow meetings/notes/dictations,
  and an optional transcripts folder.
- Intake planner: each morning Claude decides which trackers and inboxes (Jira, Azure Boards, Gmail, …) are worth checking
  with the connectors you already have, and runs those checks read-only and in parallel via Claude Code / Codex.
- Summarization through the local `claude -p` CLI: no API key needed; falls back to the raw digest on failure.
- Brief window with Markdown rendering; briefs saved as Markdown under Application Support.
- Spoken brief through on-device speech synthesis, or ElevenLabs voices (key stored in the Keychain).
- Voice companion panel: live, interruptible conversation about your day with on-device speech recognition and
  echo cancellation, so you can interrupt just by talking.
- Control panel for sources, voice, pronunciation and launch at login.
- Hand-off of follow-up work to headless Claude Code jobs in isolated git worktrees (local commits only, never pushes).
- Secret redaction for API keys, tokens and passwords before anything is summarized or saved.
- Unit tests for secret redaction, text helpers and pronunciation.
- `build.sh` to package an ad-hoc signed `.app` and install it to `/Applications`.

[Unreleased]: https://github.com/Blackrose-blackhat/MorningContext/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Blackrose-blackhat/MorningContext/releases/tag/v1.0.0
