<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**Every AI coding limit, at a glance — in the menu bar, the notch, at the screen's edge or on the desktop.**

[![Release](https://img.shields.io/github/v/release/QuotaBar/QuotaBar?color=6ee02b&label=release)](https://github.com/QuotaBar/QuotaBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/QuotaBar/QuotaBar/total?color=6ee02b&label=downloads)](https://github.com/QuotaBar/QuotaBar/releases)
[![Stars](https://img.shields.io/github/stars/QuotaBar/QuotaBar?style=flat&color=f5c518&label=stars)](https://github.com/QuotaBar/QuotaBar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/QuotaBar/QuotaBar?color=black&label=last%20commit)](https://github.com/QuotaBar/QuotaBar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/QuotaBar/QuotaBar?color=black&label=commits)](https://github.com/QuotaBar/QuotaBar/graphs/commit-activity)
[![CI](https://github.com/QuotaBar/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/QuotaBar/QuotaBar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/QuotaBar/QuotaBar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar is a macOS menu-bar app that shows how much of each AI coding service's quota
you have used, when each window resets, and roughly what it has cost — for twenty-three
providers, read and worked out on your own Mac. No account, no telemetry.

[Download](https://github.com/QuotaBar/QuotaBar/releases/latest) ·
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

Or download the `.dmg` from [Releases](https://github.com/QuotaBar/QuotaBar/releases/latest)
and drag `QuotaBar.app` into `/Applications`. Builds are signed with a Developer ID
certificate and notarized by Apple, so Gatekeeper opens them without a detour.

Requires macOS 14 (Sonoma) or later. Apple Silicon and Intel. The interface is in
English and Simplified Chinese and follows the system language unless you pick one.

## Recent updates

<!-- changelog:start -->
<!-- Generated from CHANGELOG.en.md by Scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.5.12** (2026-09-22) · **2** changes in development · [full changelog](CHANGELOG.en.md)

<details open>
<summary><b>2026-09-22</b> · Unreleased · 2 fixed</summary>

**Fixed**

- With Cursor chosen for the menu-bar icon, it showed Grok Bot's usage rather than the month's plan (a plan just reset at 0.2%, an icon at 69.3%). With no limit chosen for Cursor the menu bar was on Automatic, and Automatic took the fullest of every limit reported, an allowance beside the plan such as Grok Bot included. Automatic now takes the fullest of the plan's own limits: Cursor's Grok Bot, Codex's reserve and its per-model extras are left out unless one is being drawn on (Codex's reserve once the plan is spent) or you pick it yourself. The menu bar, the island, the dock, the card's ring, desktop cards and the usage alert all follow the rule.
- Since 0.5.12 the menu bar's limit is its own choice, but the only way to it was Settings; the icon's own right-click menu had none. Right-click the icon: under "Show in Menu Bar" there is now "Cursor Limit Shown" (named for whichever provider is chosen), with the plan's limits and Automatic.

</details>

<details>
<summary><b>2026-09-22</b> · 0.5.12 · 1 added · 1 fixed</summary>

**Added**

- The menu bar, the island and the dock can each show a different limit. All three used to follow the card's "Ring Follows" choice, so a provider showed the same figure everywhere; with a 5-hour and a weekly limit you could not watch the 5-hour in the menu bar and the week on the dock, and the places only repeated each other. Each now chooses for itself: Settings → Presentation → "Which limit each place shows" has a row per provider and a pop-up per place, where Automatic is whichever limit is fullest; right-click a card → "Limit Shown In" does the same; and double-clicking a limit in the dock's callout sets the dock's own. The card's ring is still chosen by double-clicking on the card, and desktop cards follow the card. The island's flash, glow and auto-open judge by the limit the island itself shows. On update the three places keep the choice you had, and are independent from then on.

**Fixed**

- "Copy as Image" on the Codex card copied the weekly window only; the 5-hour window could not be copied. The image draws the limits the card shows before it is expanded, and that choice (right-click the card → "Limits on the Card") had been saved while the account was on Pro, which has a week and no 5-hour limit. When the account moved to Plus it gained a 5-hour limit the saved choice had never listed, so it stayed folded: off the card, and out of the image. A choice now records which limits existed when it was made; a limit that appears later was never folded by you and takes the place the card gives it by default, so with a 5-hour limit on Codex or Claude both the card and the copied image show the 5-hour and the week. Limits you folded yourself stay folded. And copying a card while it is expanded now includes the folded limits' rows too (the trend, the spend and the links stay on the card).

</details>

<details>
<summary><b>2026-09-21</b> · 0.5.11 · 5 fixed</summary>

**Fixed**

- The island raised the alarm for providers it was not showing. With one provider a side it draws two figures, Codex and Claude, but the red flash round its outline, the glow's colour and "Open when a limit nears" looked at every provider allowed on the island. With Cursor at 99.8% the island flashed red over two figures with plenty left, which read as something wrong with those two accounts. The island now speaks only for the providers it shows: the flash, the glow, the auto-open and the reset banner all follow the ones drawn on it, and a provider it has no room for can run out without the island reacting (the panel, the dock and system notifications are unchanged). On a screen with no notch the pill now follows "Per side" too: two figures at one a side, where it used to be a fixed three.
- Hovering the island sometimes opened it, sometimes did nothing, and sometimes opened it only for it to close again. Six causes, fixed together:- Throwing the pointer at the top of the screen, the natural way to reach the notch, reports a height exactly on the island's top edge, and the test counted that edge as outside. The whole island stopped taking the mouse, and an open panel closed the moment the pointer pressed upward.- Whether the island takes the mouse was only judged again when the pointer moved, and against the window's size mid-animation. For the 0.34 seconds the panel grows downward, a pointer moving down into it was judged to have left. It is now judged against the shape the island is going to, and again whenever that shape changes.- Hover was only noticed on the pointer's next move after it arrived; a pointer that stopped was never noticed. Hover now comes from the same test.- The closed island is as tall as the menu bar, and a hand grazing its edge restarted the half-second wait. Slipping off for under 0.12 seconds no longer counts as leaving.- Once the panel began to close (a 0.3-second animation), bringing the pointer back to the still-visible panel did not stop it, and the half-second wait started over. Coming back now keeps it open. The wait before closing is 0.32 seconds, up from 0.25, the same as the edge dock's.- The strip and the panel swapped in a single frame, and the margin round the outline jumped in one frame too (the transition written for it never ran). They now cross-fade, the margin follows the window's own curve, and the panel's content is clipped to the outline.
- Turning the island off and on again in Settings could leave its glow and flash frozen for good; doing so while a reset banner was up brought the island back a row too tall before it shrank. Both fixed.
- With the system's Reduce Motion on, the island's window still eased while its content was already in place. The window now moves at once as well.
- A closed panel keeps nothing: it was only hidden, its views stayed alive, and any per-frame animation inside went on costing a Mac something nobody could see. The content is released when the panel closes and built again when it opens.

</details>

<!-- changelog:end -->

## Activity

<p align="center">
  <img src="Assets/readme/activity.svg" alt="Commits per day over the last 26 weeks" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#QuotaBar/QuotaBar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=QuotaBar/QuotaBar&type=Date&theme=dark">
      <img alt="Star history" src="https://api.star-history.com/svg?repos=QuotaBar/QuotaBar&type=Date" width="760">
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
