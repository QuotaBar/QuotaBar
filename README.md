# QuotaBar 🎚️ — Every AI coding limit, in your menu bar.

[![CI](https://github.com/gentpan/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/quotabar/actions/workflows/ci.yml)

Tiny macOS 14+ menu bar app that keeps AI coding-provider limits visible and shows when each
window resets. A clean-room Swift refactor inspired by
[steipete/CodexBar](https://github.com/steipete/CodexBar).

## Install

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 requires this for third-party taps
brew install --cask quotabar
```

Or grab the zip from [Releases](https://github.com/gentpan/quotabar/releases), unzip,
and drag `QuotaBar.app` to `/Applications`. The build is signed with a Developer ID
certificate and notarized by Apple, so it opens without a Gatekeeper detour.

Requires macOS 14 (Sonoma) or later.

## Providers

| Provider | Source | Credential |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | automatic |
| Claude | Claude Code Keychain item → `api.anthropic.com/api/oauth/usage` | automatic |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | automatic |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | automatic / manual token |
| Cursor | `cursor.com/api/usage-summary` | manual cookie |
| Kimi Code | `kimi.com` billing gateway | manual `kimi-auth` JWT |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | manual API key |
| OpenCode Go | `opencode.ai/zen/go/v1/usage` | manual token / cookie |
| MiniMax | `api.minimax.io` coding-plan remains | manual token / cookie |
| Manus | `api.manus.im` credits | manual session token |
| DeepSeek | `api.deepseek.com/user/balance` | manual API key |

Privacy-first: automatic providers reuse the session your CLI already created. Manually
entered tokens are stored in the **macOS login keychain** — never in a file. Preferences
live in `~/.config/quotabar/config.json` (`0600`) and contain no secrets. No passwords.

## Features

- One status item with a dynamic usage meter (fills with the highest active window).
- Provider switcher grid (Overview + per-provider tiles with mini meters).
- Per-provider quota windows with percent bars, absolute numbers, reset countdowns, and an
  `active` badge on the window currently governing requests.
- **Stale data is labelled.** A failed refresh keeps the last good numbers but shows how old
  they are, the underlying error, and a retry button — rather than silently serving a
  reading from an expired session.
- Local spend estimate for Claude Code and Codex CLI, read from their own session logs:
  today and a trailing 30 days, a per-day bar chart with the peak called out, the model
  most of the money went to, and a split per CLI. Duplicate turns are de-duplicated and
  cached input is not double-charged.
- Trend sparkline per provider, with a reset in Settings.
- Auto refresh (1/2/5/15/30 min), plus refresh on wake and on network recovery.
- Threshold notifications (edge-triggered, so a steady 90% does not spam).
- Bilingual UI (English / 简体中文), following the system language by default.
- Optional notch-island presentation.

## Build & run

Requires macOS 14+ and a **full Xcode toolchain** — CommandLineTools alone lacks the
SwiftUI macro plugin, so the build fails on `@State`. The packaging script auto-selects
Xcode when only CommandLineTools is active.

```bash
./Scripts/package_app.sh   # builds QuotaBar.app in-place with ad-hoc signing
open QuotaBar.app
```

Dev loop and tests:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
./Scripts/dev.sh           # runs the bare debug binary, no packaging

# The app is a menu-bar agent, so there is no window to screenshot. Render
# the surfaces off-screen instead — CI runs the first two as smoke tests.
.build/debug/QuotaBar --snapshot ./snapshots         # panel, dock, notch strip
.build/debug/QuotaBar --settings-preview ./settings  # every settings section
.build/debug/QuotaBar --icon-preview ./icons         # all eleven menu-bar styles

# Glass, vibrancy and springs only exist on screen — ImageRenderer draws none
# of them. For those, open the real thing:
.build/debug/QuotaBar --settings-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

## Distribution

QuotaBar is distributed directly (Developer ID), not through the App Store — the
App Store sandbox would block the three things the app exists to do: read the
CLI session files under `~/.codex` and `~/.claude`, and read the keychain item
Claude Code creates.

`package_app.sh` picks its signing tier automatically:

| What you have | What you get |
|---|---|
| Nothing | Ad-hoc signature — runs on your Mac only. Others see *"QuotaBar is damaged"*. |
| Developer ID certificate | Hardened-runtime signature. Others see *"Apple cannot check it for malicious software"*. |
| Certificate + notarization | Gatekeeper accepts it. Others get the normal *"downloaded from the internet"* prompt. |

To notarize, store a credential once (needs an [app-specific password](https://appleid.apple.com)):

```bash
xcrun notarytool store-credentials QuotaBar \
  --apple-id you@example.com --team-id <YOUR_TEAM_ID>
```

then build with it:

```bash
NOTARIZE=1 ./Scripts/package_app.sh
```

The script submits the app, waits for Apple, staples the ticket to the bundle,
and reports the resulting Gatekeeper verdict. Stapling matters: without it the
first launch needs a network round trip to Apple, so an offline machine refuses
to open the app.

### Cutting a release

```bash
./Scripts/release.sh
```

Notarizes, zips with `ditto` (which preserves the stapled ticket), computes the
SHA-256, and writes a ready-to-commit Homebrew cask to `dist/quotabar.rb`. It
refuses to produce a release if Gatekeeper still rejects the bundle, so a
half-signed build cannot reach users by accident.

Publish the zip as a GitHub release, drop the cask into
[gentpan/homebrew-tap](https://github.com/gentpan/homebrew-tap) as
`Casks/quotabar.rb`, and users install with:

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 requires this for third-party taps
brew install --cask quotabar
```

## First run

1. Open Settings (gear icon in the menu) → Providers and enable what you use.
2. Automatic providers need the matching CLI signed in (`codex`, `claude`, `gemini`, `grok`).
3. Manual providers: paste the token/cookie/API key described under each toggle, then use
   **Test connection** to confirm before relying on it.

Upgrading from a build that stored credentials in `config.json`? They are moved into the
keychain on first launch and erased from the file.

## Spend estimates

The cost figures are computed locally from `~/.claude/projects/**/*.jsonl` and
`~/.codex/sessions/**/rollout-*.jsonl` at published list prices. They are an estimate for
orientation, **not a bill** — they cannot see plan-included usage, discounts, or anything
that happened outside these CLIs.

## Architecture

- `Sources/QuotaCore` — provider protocol, HTTP/date helpers, config + keychain store,
  credential readers, cost estimator, one file per provider group, `ProviderRegistry`.
- `Sources/QuotaBar` — SwiftUI `MenuBarExtra` app: usage store, dynamic menu-bar icon,
  switcher grid, detail rows, settings, notch island.
- `Tests/QuotaCoreTests` — parser fixtures, cost-estimation regressions, config migration.

Adding a provider: see [CLAUDE.md](CLAUDE.md).

## Credits

Inspired by CodexBar (MIT, Peter Steinberger). QuotaBar is an independent clean-room
implementation. Provider brand logos via [GLINCKER/thesvg](https://github.com/GLINCKER/thesvg)
(SVG masters kept in `Assets/logos-src-*.svg`).

## License

MIT — see [LICENSE](LICENSE).
