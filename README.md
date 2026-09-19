<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**Every AI coding limit, at a glance — in the menu bar, the notch, at the screen's edge or on the desktop.**

[![Release](https://img.shields.io/github/v/release/gentpan/QuotaBar?color=6ee02b&label=release)](https://github.com/gentpan/QuotaBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gentpan/QuotaBar/total?color=6ee02b&label=downloads)](https://github.com/gentpan/QuotaBar/releases)
[![Stars](https://img.shields.io/github/stars/gentpan/QuotaBar?style=flat&color=f5c518&label=stars)](https://github.com/gentpan/QuotaBar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gentpan/QuotaBar?color=black&label=last%20commit)](https://github.com/gentpan/QuotaBar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/gentpan/QuotaBar?color=black&label=commits)](https://github.com/gentpan/QuotaBar/graphs/commit-activity)
[![CI](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/QuotaBar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar is a macOS menu-bar app that shows how much of each AI coding service's quota
you have used, when each window resets, and roughly what it has cost — for twenty-three
providers, read and worked out on your own Mac. No account, no telemetry.

[Download](https://github.com/gentpan/QuotaBar/releases/latest) ·
[Website](https://quota.bar) ·
[Changelog](CHANGELOG.en.md) ·
[Architecture](ARCHITECTURE.md)

**English** · [简体中文](README.zh-CN.md)

</div>

---

## Install

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 gates third-party taps
brew install --cask quotabar
```

Or download the `.dmg` from [Releases](https://github.com/gentpan/QuotaBar/releases/latest)
and drag `QuotaBar.app` into `/Applications`. Builds are signed with a Developer ID
certificate and notarized by Apple, so Gatekeeper opens them without a detour.

Requires macOS 14 (Sonoma) or later. Apple Silicon and Intel. The interface is in
English and Simplified Chinese and follows the system language unless you pick one.

## Recent updates

<!-- changelog:start -->
<!-- Generated from CHANGELOG.en.md by Scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.5.9** (2026-09-19) · [full changelog](CHANGELOG.en.md)

<details open>
<summary><b>2026-09-19</b> · 0.5.9 · 1 fixed</summary>

**Fixed**

- The Kimi Code card showed a spent quota as untouched: "0% used", or "100% left" in the default remaining view. The 5-hour window was really at 100 / 100 and the week at 21 / 100. This only happened when reading the sign-in on this Mac or an API key, the two ways added on 2026-09-17; a pasted kimi-auth cookie was not affected. Kimi's usage reply carries two kinds of number: a share used and a "used / limit" count. This time the share said 0, and QuotaBar looked only at the share whenever there was one. Each window now reads both and shows whichever says more is used. When the count is the one shown, `QuotaBar --json` and the local API also give it as "used / limit".

</details>

<details>
<summary><b>2026-09-17</b> · 0.5.9 · 6 added · 2 style · 7 fixed</summary>

**Added**

- Kimi Code reads the sign-in of the Kimi Code app or CLI (`kimi`) on this Mac, so there is no kimi-auth cookie to paste. It tells the China edition (kimi.com) from the Global one (kimi.ai) by itself. The card shows the 5-hour and weekly limits, and the monthly one when the plan has it, each with its reset time. After Kimi Code signs in, signs out, switches edition or renews its own sign-in, QuotaBar reads the quota again within 30 seconds.
- The sign-in token Kimi Code saves runs out every 15 minutes. While QuotaBar runs, a refresh that finds the token has run out, or has less than a minute left, renews it before reading the quota, so the quota keeps showing without using Kimi Code first. QuotaBar and Kimi Code take turns to renew, and the result is saved in Kimi Code's own format. The two never renew at once and sign each other out, also just after the Mac wakes from sleep. If you sign out or sign in again in Kimi Code while a renewal is under way, what you did stands. `QuotaBar --json` and the other one-off commands only read the sign-in and never renew it. Quitting QuotaBar waits for a renewal under way to be saved.
- When a renewal doesn't go through, the card says so. While Kimi Code is renewing, the quota is read at the next refresh. A network or server error keeps the last reading and tries again at the next refresh. A renewal that couldn't be saved is saved first at the next refresh, before anything else is sent. A refused renewal leaves Kimi Code's sign-in file untouched, and the card says to sign in again. When Kimi Code's sign-in has gone 30 days without a renewal from either Kimi Code or QuotaBar and can no longer be renewed, or it is signed out, the card also says to sign in again. A sign-in left on this Mac from the other edition, or a dead one left by the old Python CLI, is never used in its place.
- Some sign-ins QuotaBar only reads and never renews. When the old CLI's sign-in runs out, the card says to sign in to the Kimi Code app or the current `kimi` CLI. When Kimi Code has not yet created this Mac's device id (it does so on first start), or the sign-in is not the one Kimi Code is using, the card says to open or use Kimi Code once after the token runs out. In each case, "In use" in Settings says it is read only, and why.
- Kimi Code also takes a Kimi Code API key pasted in Settings, from the Kimi Code console of your edition. The kimi-auth cookie still works, and now a Global (kimi.ai) cookie does too. Sign in in a browser… in Settings also works for a Global account, whose sign-in ends on kimi.ai. QuotaBar tells a pasted key from a cookie by itself, and uses it ahead of the sign-in on this Mac; clear it to go back to that sign-in. A copied `Authorization: Bearer …` header, a quoted cookie or a cookie row from the browser's developer tools is understood. Text that is neither a key nor a cookie is not sent anywhere. QuotaBar asks the China edition first and the Global one only if China turns the key or cookie down, and until QuotaBar quits asks only the edition that answered. A cookie only ever goes to kimi.com and kimi.ai. If the key or cookie is refused, the card says to clear it or replace it.
- The Kimi Code card shows the edition in use (China / Global) beside the plan. In Settings → Providers → Kimi Code, a new "In use" line says whether the sign-in on this Mac, an API key or a kimi-auth cookie is used, and for which edition, and "How to sign in" lists the three ways. The Console link, in Settings and on the menu panel's card, opens kimi.com or kimi.ai to match, also after a relaunch. `QuotaBar --json` and the local API give the edition as `china` or `global`, and the credential as `signIn`, `legacySignIn`, `apiKey` or `cookie`, whatever the language. Switching edition or credential starts the trend line afresh and is not taken for a quota reset.

**Style**

- A provider whose last refresh failed and that still shows older numbers now shows an amber "● Not updating" beside its service status. It appears on the island, on the menu panel's card and on the edge dock's card. Its tooltip gives the reason and how old the numbers are, and a click opens that provider in Settings. On the island its figures and bars are dimmed; on the menu panel's and the dock's cards its bars are dimmed. In those older numbers, a window whose reset time has passed shows "reset due" in amber, so it no longer looks current. QuotaBar doesn't guess how much has been used since the reset.
- The menu panel's card and the edge dock's card write "Showing numbers from …" above older numbers, and the reason the refresh failed right under it. Before, the menu panel showed the reason only on hover, and the dock's card didn't even say how old the numbers were.

**Fixed**

- In the open island, "N not updating" in the footer did nothing when clicked and gave no hint of which providers or why. It was a count and nothing more. Rest the pointer on it, or click it, and a list above it shows each provider that is not updating. Each row gives its mark, its name and what its last refresh said, and how old the numbers are where older ones are still shown. Click one to open Settings → Providers at its row. A list opened by a click stays open, and a click on the note while the list is showing closes it.
- When you clicked Refresh now in the island and the reads came straight back, the spinner showed for a blink and it looked as if the click had missed. The spinner only showed while reads were under way. Afterwards the footer went straight back to its usual note, with nothing to say how the refresh went. The spinner, in the island and on the menu panel's refresh-everything button, now stays for at least 0.8 seconds. Then the island's footer says "All up to date" or "Refreshed · N not updating" for about 2 seconds.
- While a refresh was under way, a provider with no numbers whose last refresh had failed counted as loading. Its card on the menu panel and on the edge dock said "Loading…" in place of the error. The dot on the island and in the menu panel's footer turned from amber to green until the read came back. The cause: each refresh set every provider without numbers back to loading, and its last error went with it. It now keeps its error, and still counts as not updating, until the new read is back.
- With Claude Code signed out on this Mac, the Claude card said "Not configured. Run `claude` once and sign in to create the OAuth session.", as if it had never been signed in. Signing out leaves Claude Code's keychain item in place but empties its sign-in tokens, and QuotaBar took that for no sign-in at all. It now says Claude Code is signed out on this Mac and to run `claude` in Terminal, then /login. Settings → Providers shows Claude as Sign in, and its open row says it is signed out. `QuotaBar --credentials` also says Claude Code is signed out.
- In Settings → Providers, Cursor, Grok, OpenCode Go and GitHub Copilot said Keychain even with nothing pasted, while they were using the sign-in on this Mac. The label went by whether a provider can take a pasted credential, not by which one it was using. They now say Auto when using this Mac's sign-in, and Keychain only for a pasted credential. Kimi Code, which reads this Mac's sign-in from this version on, does the same.
- Pasting a credential in Settings while that provider was still being read could do nothing until the next refresh, or the read with the old credential could land last and put its error back. The new credential is now read at once, and the old read's answer is dropped.
- QuotaBar crashed when a provider sent a figure too large to turn into a whole number or a date, such as a Kimi Code limit as large as the largest 64-bit integer, or a reset time with no end. Such a figure now just leaves out the count or the reset time.

</details>

<details>
<summary><b>2026-09-16</b> · 0.5.9 · 1 fixed · 1 removed</summary>

**Fixed**

- The edge dock's folded handle ignored the provider picked on the dock. With Antigravity picked (the green dot under its ring), the handle still showed the dock's most spent provider, such as Cursor, as a full red bar and flashed. The handle always went by the dock's tightest provider, whichever one was picked. Its fill, colour and low-quota flash now follow the picked provider, and don't flash when it has plenty left. Only with nothing picked do they follow the dock's tightest provider.

**Removed**

- The Share Usage Card window no longer opens by itself after an update. It used to open once on the first launch of each new version with usage that week. Several updates in a row opened it every time, which looked like something had gone wrong. The card is still one click away in the menu panel, the share icon on the island's overview page, and Settings → Usage.

</details>

<!-- changelog:end -->

## Activity

<p align="center">
  <img src="Assets/readme/activity.svg" alt="Commits per day over the last 26 weeks" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#gentpan/QuotaBar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date&theme=dark">
      <img alt="Star history" src="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date" width="760">
    </picture>
  </a>
</p>

## Providers

| Provider | Source | Credential |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | automatic |
| Claude | Claude Code keychain item → `api.anthropic.com/api/oauth/usage` | automatic |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | automatic |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | automatic / manual |
| Antigravity | `~/.gemini/jetski-standalone-oauth-token` → `cloudcode-pa.googleapis.com` | automatic |
| Cursor | Cursor's own `state.vscdb` session → `cursor.com/api/usage-summary` | automatic / manual |
| OpenCode Go | `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage` | automatic / manual |
| Kimi Code | Kimi Code app / CLI sign-in (`~/.kimi-code/credentials`) → `api.kimi.com` / `api.kimi.ai` `/coding/v1/usages`, or the `kimi.com` billing gateway with a `kimi-auth` JWT | automatic / manual |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | manual API key |
| MiniMax | `api.minimax.io` coding-plan remains | manual token / cookie |
| Manus | `api.manus.im` credits | manual session token |
| DeepSeek | `api.deepseek.com/user/balance` | manual API key |
| Qwen Cloud | `home.qwencloud.com` console → token plan usage | manual Cookie header |
| GitHub Copilot | GitHub CLI sign-in (`gh auth token`) → `api.github.com/copilot_internal/user` | automatic / manual |
| 阿里云百炼 Coding Plan *(experimental)* | Bailian console gateway → coding plan quota | Cookie header / in-app sign-in |
| 火山方舟 *(experimental)* | `arkcli usage plan --format json` | automatic (arkcli login) |
| 智谱 GLM *(experimental)* | `open.bigmodel.cn/api/monitor/usage/quota/limit` | manual API key |
| Kimi 开放平台 *(experimental)* | `api.moonshot.cn/v1/users/me/balance` | manual API key |
| OpenRouter *(experimental)* | `openrouter.ai/api/v1/credits` + `/key` | manual API key |
| 小米 MiMo *(experimental)* | `platform.xiaomimimo.com/api/v1` balance + token plan | Cookie header / in-app sign-in |
| Qoder *(experimental)* | `qoder.com/api/v2/me/usages/big_model_credits` | manual Cookie header |
| Windsurf *(experimental)* | Windsurf's own `state.vscdb` cached plan | automatic |
| Kiro *(experimental)* | `kiro-cli` session → AWS `GetUsageLimits` | automatic |

*Experimental* providers are built from the services' own consoles and CLIs but have not
yet been checked against a live account; they are labelled as such in Settings.

**No dialog, normally.** Claude is the only provider whose session lives in *another
app's* keychain item. QuotaBar reads it the way Claude Code itself does — through
`/usr/bin/security`, which every item that tool writes trusts — so macOS has nothing to
ask, whatever the build is signed with. Only if that read is refused does the
**Allow keychain access** button appear, and the dialog is never raised from a background
refresh — only from that button.

## Where the numbers show

**Menu bar and panel**
- Eleven glyph styles, four of them *stepped* so the reading can be counted rather than
  estimated; or a text reading, the logo alone, or nothing.
- The glyph splits a **short** horizon (5-hour, rolling) from a **long** one (weekly,
  billing cycles), because collapsing them hides which limit is actually near.
- Click it for the panel: a spend card on top — spend, tokens or cost per million
  tokens, for today, yesterday or 30 days, split by CLI — then one card per provider
  with its two most important windows; the rest, the trend, 30-day spend and the status
  page fold out beneath.
- Click any percentage to flip between used and left, any reset time between a countdown
  and the clock. Right-click a card to copy it as an image.
- `Esc` closes, `⌘R` refreshes everything, `⌘,` opens Settings. A global hotkey can open
  it from anywhere.

**Notch island** — on notched Macs the figures sit either side of the notch. Hover to open
three pages (limits, usage, overview) with five chart styles. A soft glow turns amber and
red as a limit nears, and the island peeks out on its own the first time one crosses the
warning line. A low-power mode glows only when something happens.

**Edge dock** — hides until the pointer reaches the screen edge. Double-click a window
(5-hour, weekly, a model's own) to choose what its ring shows.

**Desktop cards** — as many as you like, sitting on the desktop below your windows or
kept above them: big figure, gauge, spend trend, day by day, provider grid, closest to the
limit, and the classic list, each in small, medium or large. Drag to move, double-click
for the panel, right-click to change style, size or provider.

With two screens, choose which one the island, dock and cards appear on.

## Pace, alerts and spend

- **Pace.** A thin tick on every bar marks where even use would be by now. A window on
  course to finish tight says so; one on course to run out shows a flame and when.
- **Alerts.** Warning and critical thresholds, plus *almost out*, *cutting it close* and
  *will run out* — each fires once per crossing and once per reset period.
- **Resets.** QuotaBar reads a provider again the moment a window resets, and marks it
  in that provider's colour: the dock slides out and sweeps the ring full with a card
  beside it, the island opens a "limit reset" banner, the menu-bar glyph refills with a
  sheen, and the row says it just reset; a notification follows if the window had been
  used past 90%.
- **Spend.** Estimated locally from Claude Code, Codex CLI and OpenCode session logs, in
  dollars or one of ten other currencies at daily reference rates, counting all tokens or
  input and output only. QuotaBar keeps its own day-by-model archive, so the figures do
  not shrink when a CLI prunes old logs.
- **Usage page.** A year heatmap and volume chart in Settings.
- **Share card.** Your last 7 days, 30 days, 3 months, year or all time, by API value or
  tokens; the card turns black past $1,000 and blue past $10,000. 4:5, 1:1 or 9:16, saved
  as a 1080-pixel PNG or copied.
- **Service status.** The providers' own status pages, judged by the coding components —
  Claude Code, the Codex CLI — with 30 days of history in Settings.

## Your data

Automatic providers reuse the session your CLI already created — the app never asks for a
password. Manually entered tokens go to the **macOS login keychain**, never to a file.
Preferences live in `~/.config/quotabar/config.json` (mode `0600`) and contain no
secrets. There is no analytics and no telemetry.

QuotaBar connects only to:

- the usage endpoints of the providers you turn on, with your own session or key;
- their public status pages, such as `status.claude.com`;
- `open.er-api.com`, once a day, for exchange rates;
- GitHub, to check for and download updates and to fetch model prices (LiteLLM's catalog);
- `quota.bar`, only when you send feedback.

With a proxy set (HTTP, HTTPS or SOCKS5), all of it goes through the proxy. Your usage is
never sent to a server of ours. While a screen share or recording is on, QuotaBar can
hide the figures and leave only its mark in the menu bar.

## For other tools

Turn on **Local API** in Settings → General and QuotaBar serves JSON on this Mac only:

```bash
curl http://127.0.0.1:6736/v1/limits   # every window, percent and reset
curl http://127.0.0.1:6736/v1/spend    # dollars and tokens: today, yesterday, 30 days
```

No credentials, no account names. From a terminal, the same limits without the app open:

```bash
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json          # cached up to five minutes
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json --force  # ask every provider now
```

## First run

1. On a fresh install QuotaBar turns on only the providers whose tools it finds signed in
   on this Mac, and a welcome card in the panel says how many.
2. Automatic providers need the matching CLI signed in (`codex`, `claude`, `gemini`,
   `grok`, `gh`) or the app installed (Cursor, Windsurf).
3. Manual providers: open Settings → **Providers**, paste the token described under the
   row, then **Test connection** — it bypasses every cache and asks the source directly.

The panel refreshes every 5, 15 or 30 minutes, on wake, and when the network comes back;
the footer's button refreshes everything at once. Upgrading from a build that stored
credentials in `config.json`? They are moved into the keychain on first launch and erased
from the file.

## Build & run

Requires macOS 14+ and a **full Xcode toolchain** — CommandLineTools alone lacks the
SwiftUI macro plugin, so the build fails on `@State`.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
UNIVERSAL=0 ./Scripts/package_app.sh   # QuotaBar.app in place; drop UNIVERSAL=0 for Intel too
open QuotaBar.app
```

The app is a menu-bar agent, so there is little to screenshot. Render the surfaces
off-screen instead — CI runs the first two as smoke tests. Add `--lang en` or `--lang zh`
to render one language:

```bash
.build/debug/QuotaBar --snapshot ./snapshots             # panel, dock, notch strip
.build/debug/QuotaBar --settings-preview ./settings      # every settings section, both languages
.build/debug/QuotaBar --icon-preview ./icons             # all eleven menu-bar styles
.build/debug/QuotaBar --island-preview ./island          # island pages and chart styles
.build/debug/QuotaBar --widget-concepts ./cards          # every desktop card, every size
```

Glass, vibrancy and springs only exist on screen — `ImageRenderer` draws none of them.
For those, open the real thing:

```bash
.build/debug/QuotaBar --settings-window about
.build/debug/QuotaBar --panel-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

For a single provider: `QuotaBar --provider claude`; for the status pages:
`QuotaBar --status`.

## Distribution

Developer ID only, not the App Store — the sandbox forbids reading `~/.codex`,
`~/.claude` and another app's keychain item, which is the entire feature set.

`package_app.sh` picks its signing tier automatically:

| What you have | What others get |
|---|---|
| Nothing | Ad-hoc signature — runs on your Mac only. Others see *"QuotaBar is damaged"*. |
| Developer ID certificate | Hardened runtime. Others see *"Apple cannot check it for malicious software"*. |
| Certificate + notarization | Gatekeeper accepts it — the normal *"downloaded from the internet"* prompt. |

Store a notarization credential once (needs an
[app-specific password](https://appleid.apple.com)):

```bash
xcrun notarytool store-credentials QuotaBar \
  --apple-id you@example.com --team-id <YOUR_TEAM_ID>
```

### Cutting a release

```bash
./Scripts/release.sh
```

Notarizes, staples, zips with `ditto` (which preserves the ticket), builds a signed and
notarized `.dmg`, computes both SHA-256s, and writes a ready-to-commit Homebrew cask to
`dist/quotabar.rb`. It **refuses to produce a release if Gatekeeper still rejects the
bundle**, so a half-signed build cannot reach users by accident. The app updates itself
only from a download signed by this app's developer and notarized by Apple.

## Spend estimates

Computed locally from `~/.claude/projects/**/*.jsonl`,
`~/.codex/sessions/**/rollout-*.jsonl` and OpenCode's own database, priced from a live
catalog that matches exact model ids. They are an estimate for orientation, **not a
bill** — they cannot see plan-included usage, discounts, or anything that happened
outside these CLIs.

Two things are easy to get wrong here and are pinned by tests: Claude Code writes the
same assistant turn into every session file that replays it (deduplicated on
`message.id` + `requestId`), and Codex reports `input_tokens` inclusive of
`cached_input_tokens` (not double-charged).

## Architecture

- `Sources/QuotaCore` — provider protocol, HTTP helpers, config and keychain store,
  credential readers, cost estimator and usage archive, pricing catalog, status pages,
  updater, one file per provider group.
- `Sources/QuotaBar` — the app: an AppKit status item and panels hosting SwiftUI — usage
  store, menu-bar glyph, panel, settings, notch island, edge dock, desktop cards, share
  card, local API.
- `Tests/QuotaCoreTests` — parser fixtures, cost regressions, config migration, updater
  verification. Everything testable lives in QuotaCore.
- The website and the Quota Run service live in separate repositories.

Adding a provider, and every design decision worth knowing before changing one:
[ARCHITECTURE.md](ARCHITECTURE.md). Every change to the app is logged, dated, in
[CHANGELOG.en.md](CHANGELOG.en.md) (English) and [CHANGELOG.md](CHANGELOG.md) (Chinese).

## Acknowledgements

QuotaBar builds on these open-source projects and this typeface. Thank you.

| Project | Author | License | What QuotaBar took |
|---|---|---|---|
| [codex-island](https://github.com/ericjypark/codex-island) | Eric Park | MIT | The notch island's look and motion |
| [OpenUsage](https://github.com/robinebers/openusage) | Robin Ebers | MIT | The menu panel, pace hints and the share card |
| [CodexBar](https://github.com/steipete/CodexBar) | Peter Steinberger | MIT | How providers report their usage; QuotaBar is a clean-room Swift implementation inspired by it |
| [theSVG](https://github.com/GLINCKER/thesvg) | thesvg.org | MIT | The vector masters of the provider logos, kept in `Assets/logos-src-*.svg` |
| [Instrument Sans](https://github.com/Instrument/instrument-sans) | The Instrument Sans Project Authors | SIL OFL 1.1 | The typeface of the QuotaBar wordmark and the website |

QuotaBar is an independent third-party app. It is not affiliated with, endorsed by, or
sponsored by Anthropic, OpenAI, Cursor, Google, xAI, GitHub, X or any other company it
mentions. Their names and logos belong to their respective owners.

## License

MIT — see [LICENSE](LICENSE).
