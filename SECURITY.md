# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/Blackrose-blackhat/MorningContext/security/advisories/new)
instead. You should get a reply within a few days. Once a fix is released, we'll credit you
unless you'd rather stay anonymous.

## What Morning Context touches

It helps to know the trust boundaries when assessing an issue:

- **Reads locally:** Claude Code transcripts (`~/.claude/projects`), Codex sessions (`~/.codex/sessions`),
  the Wispr Flow database (opened read-only), and an optional transcripts folder.
- **Sends to Claude:** the collected context, via your own logged-in `claude` CLI. Obvious secrets
  (API keys, tokens, passwords) are redacted before anything is sent or saved.
- **Optional:** ElevenLabs text-to-speech, only if you add an API key. The key is stored in the
  macOS Keychain.
- **Background jobs:** voice-requested Claude Code jobs run in a fresh git worktree, commit locally,
  and never push.
- **Stores:** briefs and logs under `~/Library/Application Support/MorningContext/`.
