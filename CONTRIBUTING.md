# Contributing to Morning Context

Thanks for helping out! Bug reports, new context sources, and fixes are all welcome.

## Getting set up

Requirements: macOS 13+ to run; the macOS 26 SDK (Xcode 26 or its Command Line Tools) to build, and the
[Claude Code CLI](https://docs.claude.com/en/docs/claude-code) logged in.

```sh
git clone https://github.com/Blackrose-blackhat/MorningContext.git
cd MorningContext
swift build          # compile
./scripts/test.sh    # unit tests (plain `swift test` works with full Xcode)
./build.sh           # build/MorningContext.app
./build.sh --install # install to /Applications and launch
```

Logs go to `~/Library/Application Support/MorningContext/app.log`.

## Making a change

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Branch from `main`, keep the change focused, and match the style of the code around it.
3. Add or update tests where it makes sense (pure logic such as parsing and redaction is easy to test).
4. Add a line under **Unreleased** in [`CHANGELOG.md`](CHANGELOG.md) for user-facing changes.
5. Open a pull request; CI must be green.

### Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/):
`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `chore:`.

### Privacy

Morning Context reads very personal data. Never commit real session logs, transcripts,
briefs, names, tokens, or screenshots containing them. Use made-up fixtures in tests.
Anything that leaves the Mac must be opt-in and documented in the README.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading.
2. Commit: `chore(release): vX.Y.Z`.
3. Tag and push: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin main vX.Y.Z`.
4. The **Release** workflow builds the app, zips it with a SHA-256 checksum, and publishes the
   GitHub release using that changelog section.

Versions follow [Semantic Versioning](https://semver.org/).
