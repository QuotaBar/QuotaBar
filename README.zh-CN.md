<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**每个 AI 编码额度，抬眼就看见——在菜单栏、刘海、屏幕边缘或桌面上。**

[![Release](https://img.shields.io/github/v/release/gentpan/QuotaBar?color=6ee02b&label=%E7%89%88%E6%9C%AC)](https://github.com/gentpan/QuotaBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gentpan/QuotaBar/total?color=6ee02b&label=%E4%B8%8B%E8%BD%BD)](https://github.com/gentpan/QuotaBar/releases)
[![Stars](https://img.shields.io/github/stars/gentpan/QuotaBar?style=flat&color=f5c518&label=%E6%98%9F%E6%A0%87)](https://github.com/gentpan/QuotaBar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gentpan/QuotaBar?color=black&label=%E6%9C%80%E8%BF%91%E6%8F%90%E4%BA%A4)](https://github.com/gentpan/QuotaBar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/gentpan/QuotaBar?color=black&label=%E6%8F%90%E4%BA%A4)](https://github.com/gentpan/QuotaBar/graphs/commit-activity)
[![CI](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/QuotaBar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar 是一款 macOS 菜单栏应用，显示每个 AI 编码服务的额度用了多少、各个窗口何时重置、
大约花了多少钱。支持 23 个服务商，全部在你自己的 Mac 上读取和计算。无需注册账号，没有任何统计上报。

[下载](https://github.com/gentpan/QuotaBar/releases/latest) ·
[官网](https://quota.bar) ·
[更新日志](CHANGELOG.md) ·
[架构说明](ARCHITECTURE.md)

[English](README.md) · **简体中文**

</div>

---

## 安装

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 需要先信任第三方 tap
brew install --cask quotabar
```

也可以从 [Releases](https://github.com/gentpan/QuotaBar/releases/latest) 下载 `.dmg`，
把 `QuotaBar.app` 拖进「应用程序」。安装包使用 Developer ID 证书签名并经过 Apple 公证，
Gatekeeper 可以直接打开。

需要 macOS 14（Sonoma）或更高版本，支持 Apple 芯片和 Intel。界面提供英文和简体中文，
默认跟随系统语言，也可以在设置里指定。

## 最近更新

<!-- changelog:start -->
<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->

最新版本 **0.5.9**（2026-09-19） · [完整更新日志](CHANGELOG.md)

<details open>
<summary><b>2026-09-19</b> · 0.5.9 · 修复 1</summary>

**修复**

- Kimi Code 卡片把用满的额度显示成没用过（「已用 0%」，按默认的剩余方式显示则是「剩余 100%」）：5 小时额度实际已用 100 / 100，本周已用 21 / 100。这个问题只出现在读取本机登录或 API Key 时（9 月 17 日新增的两种方式），粘贴 kimi-auth cookie 不受影响。Kimi 返回的用量里有两种数字，一种是已用比例，一种是「已用 / 上限」计数。这次比例报的是 0，而 QuotaBar 只要有比例就只看比例。现在每个额度窗口两种数字都读，按已用更多的那个显示。按计数显示时，`QuotaBar --json` 和本地 API 会一并给出「已用 / 上限」。

</details>

<details>
<summary><b>2026-09-17</b> · 0.5.9 · 新增 6 · 样式 2 · 修复 7</summary>

**新增**

- Kimi Code 可以直接读取本机 Kimi Code 应用或 CLI（`kimi`）的登录，不用再粘贴 kimi-auth cookie，国内版（kimi.com）和国际版（kimi.ai）会自动识别。卡片显示 5 小时和每周额度（套餐有月额度时一并显示）以及各自的重置时间。Kimi Code 登录、退出、切换版本或自己续期登录后，QuotaBar 会在 30 秒内重新读取额度。
- Kimi Code 保存的登录令牌每 15 分钟就会过期。QuotaBar 运行时，每次刷新如果发现令牌已经过期或剩不到一分钟，会先替它续期再读取额度，所以额度一直能显示，不用先去用一次 Kimi Code。QuotaBar 和 Kimi Code 轮流续期，续期结果按 Kimi Code 的格式写回，两边不会同时续期、把对方的登录挤掉，Mac 刚从睡眠中唤醒时也是如此。续期期间如果在 Kimi Code 里退出或重新登录，以你的操作为准。`QuotaBar --json` 这类一次性命令只读取登录、不续期；退出 QuotaBar 时会等进行中的续期保存完。
- 续期没能完成时，卡片会说明情况：Kimi Code 正在续期时，下次刷新再读取；网络或服务器出错时，保留上一次的读数，下次刷新重试；续期结果没能保存时，下次刷新先把它存好，再发其他请求；续期被拒绝时，不改动 Kimi Code 的登录文件，只提示重新登录。Kimi Code 的登录连续 30 天没有续期（Kimi Code 和 QuotaBar 都没有替它续期）、已经无法再续期，或者已经退出登录时，也会提示重新登录。本机留着的另一个版本的登录，或旧版 Python CLI 留下的失效登录，都不会拿来顶替。
- 有几种登录 QuotaBar 只读取、不续期。旧版 CLI 的登录过期后，卡片提示登录 Kimi Code 应用或新版 `kimi` CLI。Kimi Code 还没在这台 Mac 上生成设备 ID（Kimi Code 首次启动时生成），或者这份登录不是 Kimi Code 当前使用的那份时，令牌过期后卡片提示打开或用一次 Kimi Code。这几种情况，设置的「当前使用」下都会注明只读和原因。
- Kimi Code 也可以在设置里粘贴 Kimi Code API Key（在所用版本的 Kimi Code 控制台获取）。原来的 kimi-auth cookie 仍然可用，现在国际版（kimi.ai）的 cookie 也能用；设置里的「浏览器登录…」对国际版账号也有效，登录落在 kimi.ai 时同样能取到 cookie。粘贴的内容会自动区分是 Key 还是 cookie，并优先于本机登录使用，清除后改回读取本机登录。复制来的 `Authorization: Bearer …` 请求头、带引号的 cookie、浏览器开发者工具里的 cookie 行都能识别。既不是 Key 也不是 cookie 的内容，不会发送到任何地方。QuotaBar 先向国内版查询，国内版不认这个 Key 或 cookie 时才查国际版，之后直到退出 QuotaBar 都只查回应过的那个版本；cookie 只会发往 kimi.com 和 kimi.ai。Key 或 cookie 被拒绝时，卡片提示清除它或换一个。
- Kimi Code 卡片的套餐标签旁显示所用版本（国内版 / 国际版）。设置 → 服务商 → Kimi Code 新增「当前使用」一行，写明用的是本机登录、API Key 还是 kimi-auth cookie，以及哪个版本；「如何登录」列出这三种方式。设置里和下拉面板卡片上的「控制台」链接都按版本打开 kimi.com 或 kimi.ai，重新启动应用后也是如此。`QuotaBar --json` 和本地 API 新增 `edition`（`china` / `global`）和 `source`（`signIn` / `legacySignIn` / `apiKey` / `cookie`）两个字段，分别标明版本和所用的凭据，不随界面语言变化。切换版本或凭据后，趋势线重新开始，也不会被当成额度重置。

**样式**

- 刷新失败、仍在显示旧读数的服务商，会在服务状态旁显示橙色的「● 未能更新」。刘海岛、下拉面板的卡片和边缘停靠条的卡片上都会显示。鼠标悬停可以看到原因和数据是多久前的，点击打开设置里这个服务商。它在刘海岛上的数字和进度条会变暗，在下拉面板和停靠条卡片上的进度条也会变暗。旧读数里已经过了重置时间的窗口，「已到重置时间」改用橙色显示，不再像是当前数据；重置后用了多少不会凭空估算。
- 下拉面板和边缘停靠条的卡片里，旧读数上方会写明「显示的是 X 前的数据」，下面直接写出刷新失败的原因。以前下拉面板要把鼠标悬停上去才能看到原因，停靠条卡片连数据是多久前的都没有写。

**修复**

- 刘海岛展开面板底栏的「N 个未能更新」点了没有反应，也看不出是哪些服务商、为什么没更新。原因是这行字只是一个计数，没有地方列出详情。现在鼠标在这行字上停一下或点一下，上方会列出每个未能更新的服务商，包括图标、名称和上次刷新的出错原因；仍显示旧读数的，还会注明数据是多久前的。点其中一个，直接打开设置 → 服务商里它的那一行。点一下打开的列表会一直开着，列表开着时再点这行字就会收起。
- 在刘海岛上点「立即刷新」，如果读取很快返回，转圈一闪而过，看起来像没点到。原因是转圈只在读取进行时显示，刷新完又直接回到原来的文字，看不出这次刷新的结果。现在转圈至少持续 0.8 秒（下拉面板的「全部刷新」也一样），结束后刘海岛底栏约 2 秒显示「已全部更新」或「已刷新 · N 个未能更新」。
- 刷新进行中时，上次刷新失败、又还没有读数的服务商会被当成「加载中」。下拉面板和边缘停靠条上它的卡片显示「加载中…」，出错原因不见了；刘海岛和下拉面板底栏的圆点也从橙色变成绿色，直到读取返回。原因是每次刷新开始时，没有读数的服务商一律被改回加载状态，上次的错误也就丢了。现在新的读取返回之前，它保留出错原因，仍算作未能更新。
- Claude Code 在这台 Mac 上退出登录后，Claude 卡片提示「尚未配置。运行一次 `claude` 并登录以生成 OAuth 会话。」，像是从来没有登录过。原因是退出登录后钥匙串里的条目还在、只是登录令牌被清空，而 QuotaBar 把这和完全没登录过当成一回事。现在卡片会说明 Claude Code 已在这台 Mac 上退出登录，请在终端运行 `claude`，再输入 /login 登录。设置 → 服务商里 Claude 的状态显示「需登录」，展开后的提示也说明是已退出登录。`QuotaBar --credentials` 也会写明 Claude Code 已退出登录。
- 设置 → 服务商里，Cursor、Grok、OpenCode Go、GitHub Copilot 在没有粘贴凭据、实际用的是本机登录时，状态也显示「钥匙串」。原因是状态只看服务商能不能粘贴凭据，不看它实际用的是哪一种。现在用本机登录时显示「自动」（这次新支持本机登录的 Kimi Code 也一样），用粘贴的凭据时才显示「钥匙串」。
- 在设置里粘贴凭据时，如果这个服务商正在读取，粘贴后可能要等到下次刷新才生效，或者用旧凭据的那次读取后返回、又把出错信息放回来。现在会立即用新凭据读取，旧凭据那次的结果直接丢弃。
- 服务商返回大得换算不了的数字时，QuotaBar 会闪退。比如 Kimi Code 返回和 64 位整数最大值一样大的额度上限，或者没有尽头的重置时间。原因是把这类数字转成整数或日期时超出了范围。现在遇到这类数字，只是不显示用量计数或重置时间。

</details>

<details>
<summary><b>2026-09-16</b> · 0.5.9 · 修复 1 · 删除 1</summary>

**修复**

- 边缘停靠条收起时的把手没有跟随选定的服务商。比如在停靠条上选了 Antigravity（圆环下有绿点），把手仍按停靠条上最快用完的服务商（比如 Cursor）显示满格红条并闪烁提醒。原因是把手一直只看停靠条上最紧张的服务商，不管选的是哪个。现在把手的进度、颜色和低额度闪烁都跟随选定的服务商，它额度充足就不闪；没有选定服务商时，才看停靠条上最紧张的那个。

**删除**

- 升级后不再自动弹出「分享用量卡片」窗口。以前每升级到一个新版本，第一次启动时只要这周有用量，它就会自己打开一次；连续升级时每次都弹，容易误以为出了问题。分享卡片仍可以从下拉面板、刘海岛总览页右上角的分享图标，以及设置 → 用量统计里打开。

</details>

<!-- changelog:end -->

## 项目动态

<p align="center">
  <img src="Assets/readme/activity.zh.svg" alt="近 26 周每天的提交次数" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#gentpan/QuotaBar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date&theme=dark">
      <img alt="星标增长曲线" src="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date" width="760">
    </picture>
  </a>
</p>

## 服务商

| 服务商 | 数据来源 | 凭据 |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | 自动 |
| Claude | Claude Code 钥匙串项 → `api.anthropic.com/api/oauth/usage` | 自动 |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | 自动 |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | 自动 / 手动 |
| Antigravity | `~/.gemini/jetski-standalone-oauth-token` → `cloudcode-pa.googleapis.com` | 自动 |
| Cursor | Cursor 自己的 `state.vscdb` 会话 → `cursor.com/api/usage-summary` | 自动 / 手动 |
| OpenCode Go | `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage` | 自动 / 手动 |
| Kimi Code | Kimi Code 应用 / CLI 登录（`~/.kimi-code/credentials`）→ `api.kimi.com` / `api.kimi.ai` `/coding/v1/usages`，或用 `kimi-auth` JWT 读 `kimi.com` 计费网关 | 自动 / 手动 |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | 手动填写 API Key |
| MiniMax | `api.minimax.io` 编码套餐余量 | 手动填写 token / Cookie |
| Manus | `api.manus.im` 额度 | 手动填写会话 token |
| DeepSeek | `api.deepseek.com/user/balance` | 手动填写 API Key |
| Qwen Cloud | `home.qwencloud.com` 控制台 → token 套餐用量 | 手动填写 Cookie 请求头 |
| GitHub Copilot | GitHub CLI 登录 (`gh auth token`) → `api.github.com/copilot_internal/user` | 自动 / 手动 |
| 阿里云百炼 Coding Plan *（实验性）* | 百炼控制台网关 → 编码套餐额度 | Cookie 请求头 / 应用内登录 |
| 火山方舟 *（实验性）* | `arkcli usage plan --format json` | 自动（arkcli 登录） |
| 智谱 GLM *（实验性）* | `open.bigmodel.cn/api/monitor/usage/quota/limit` | 手动填写 API Key |
| Kimi 开放平台 *（实验性）* | `api.moonshot.cn/v1/users/me/balance` | 手动填写 API Key |
| OpenRouter *（实验性）* | `openrouter.ai/api/v1/credits` + `/key` | 手动填写 API Key |
| 小米 MiMo *（实验性）* | `platform.xiaomimimo.com/api/v1` 余额 + token 套餐 | Cookie 请求头 / 应用内登录 |
| Qoder *（实验性）* | `qoder.com/api/v2/me/usages/big_model_credits` | 手动填写 Cookie 请求头 |
| Windsurf *（实验性）* | Windsurf 自己的 `state.vscdb` 缓存套餐 | 自动 |
| Kiro *（实验性）* | `kiro-cli` 会话 → AWS `GetUsageLimits` | 自动 |

标为*实验性*的服务商按各家控制台和命令行工具的接口实现，但还没有用真实账号验证过，
设置里会同样标注。

**正常情况下不会弹窗。** Claude 是唯一一个把登录会话存放在*另一个应用*钥匙串项里的服务商。
QuotaBar 和 Claude Code 自己一样，通过 `/usr/bin/security` 读取；该工具写入的每个钥匙串项都信任它，
所以无论安装包用什么签名，macOS 都不需要询问。只有这次读取被拒绝时，才会出现
**允许访问钥匙串** 按钮；后台刷新从不弹出系统对话框，只有点这个按钮时才会。

## 在哪里看额度

**菜单栏与下拉面板**
- 11 种图标样式，其中 4 种是*阶梯*式，格数可以直接数出来，读数更准；也可以只显示文字、
  只显示 logo，或完全隐藏。
- 图标把**短周期**（5 小时滚动窗口）和**长周期**（每周、账单周期）分开显示，
  合在一起就看不出到底是哪个额度快用完了。
- 点击图标打开面板。顶部是花费卡片，可切换花费、token 数或每百万 token 花费，
  时间可选今日、昨日或 30 天，并按命令行工具拆分。下面每个服务商一张卡片，
  显示最重要的两个额度窗口；其余窗口、趋势、30 天花费和状态页收在展开区里。
- 点任意百分比在已用和剩余之间切换，点重置时间在倒计时和具体时刻之间切换。
  右键卡片可以复制为图片。
- `Esc` 关闭，`⌘R` 全部刷新，`⌘,` 打开设置。还可以设置全局快捷键，在任何地方打开面板。

**刘海岛**：带刘海的 Mac 上，数字显示在刘海两侧。鼠标悬停展开，有额度、用量、总览三页，
图表有五种样式。额度接近告警线时，光晕从蓝色渐变为琥珀色和红色；第一次越过告警线时，
刘海岛会自动弹出。低功耗模式下只在有变化时发光。

**屏幕边缘停靠条**：平时隐藏，鼠标移到屏幕边缘时出现。双击某个窗口（5 小时、每周、
某个模型单独的额度），选择圆环显示哪一个。

**桌面卡片**：数量不限，默认放在桌面上、窗口下方，也可以保持在最前。有大数字、仪表、
花费趋势、每日对比、服务商网格、快用完排行和经典列表几种样式，每种都有小、中、大三个尺寸。
拖动可移动，双击打开面板，右键可更换样式、尺寸或服务商。

接了两块屏幕时，可以选择刘海岛、停靠条和桌面卡片显示在哪块屏幕上。

## 节奏、提醒与花费

- **节奏**：每条进度条上有一条细竖线，标出匀速使用时此刻应在的位置。预计余量很紧时会提示；
  预计重置前用完时显示火苗和用完时间。
- **提醒**：告警和严重两档阈值，外加"快用完""余量很紧""重置前会用完"三种节奏提醒；
  每次越线只提醒一次，每个重置周期也只提醒一次。
- **额度重置**：窗口一重置，QuotaBar 立刻重新读取该服务商，并用该服务商的颜色标出来：
  停靠条滑出、圆环被扫满并弹出卡片，刘海岛展开「额度已重置」横幅，菜单栏图标回满并闪过一道高光，
  对应额度行显示「刚刚重置」；如果该窗口之前用过 90% 以上，还会发一条通知。
- **花费**：根据 Claude Code、Codex CLI 和 OpenCode 的本地会话日志估算，可以显示为美元或
  另外 10 种货币（每天更新参考汇率），token 可选全部计入或只算输入和输出。
  QuotaBar 自己按天、按模型保存存档，命令行工具清理旧日志后统计也不会变少。
- **用量页**：设置里有全年热力图和用量图表。
- **分享卡片**：最近 7 天、30 天、3 个月、今年或全部时间的用量，按 API 价值或 token 数展示；
  超过 1000 美元变黑卡，超过 1 万美元变蓝卡。比例可选 4:5、1:1、9:16，
  可保存为 1080 像素 PNG 或直接复制。
- **服务状态**：读取各服务商官方状态页，按写代码相关的组件判断（例如 Claude Code、Codex CLI），
  设置里可以查看 30 天记录。

## 你的数据

自动型服务商复用命令行工具已有的登录会话，应用不会向你索要密码。手动填写的 token 保存在
**macOS 登录钥匙串**中，不写入任何文件。偏好设置保存在 `~/.config/quotabar/config.json`
（权限 `0600`），其中不含任何密钥。没有统计，也没有遥测。

QuotaBar 只会连接这些地方：

- 你开启的服务商的用量接口，使用你自己的登录会话或密钥；
- 各服务的公开状态页，例如 `status.claude.com`；
- `open.er-api.com`，每天一次，获取汇率；
- GitHub，检查和下载更新，以及获取模型价目表（LiteLLM 的价目表）；
- `quota.bar`，仅在你提交反馈时。

设置了代理（HTTP、HTTPS 或 SOCKS5）时，以上请求都经过代理。你的用量不会发送到我们的服务器。
共享屏幕或录屏时，QuotaBar 可以隐藏数字，菜单栏只留下 logo。

## 给其他工具用

在「设置 → 通用」里打开**本地接口**，QuotaBar 会在本机提供 JSON 数据，只对这台 Mac 开放：

```bash
curl http://127.0.0.1:6736/v1/limits   # 所有额度窗口、百分比和重置时间
curl http://127.0.0.1:6736/v1/spend    # 今日、昨日、30 天的花费和 token 数
```

接口不包含任何凭据和账号名。也可以不打开应用，直接在终端获取同样的额度数据：

```bash
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json          # 最多使用 5 分钟内的缓存
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json --force  # 立即向每个服务商重新获取
```

## 首次使用

1. 全新安装时，QuotaBar 只开启本机已登录工具对应的服务商，并在面板里用一张欢迎卡片告诉你开启了几个。
2. 自动型服务商需要对应的命令行工具已登录（`codex`、`claude`、`gemini`、`grok`、`gh`），
   或已安装对应应用（Cursor、Windsurf）。
3. 手动型服务商：打开「设置 → 服务商」，按该行下方的说明粘贴 token，然后点**测试连接**，
   它会跳过所有缓存，直接向数据源请求。

面板每 5、15 或 30 分钟自动刷新，唤醒后和网络恢复时也会刷新；页脚的按钮可以一次刷新全部。
如果你从把凭据存在 `config.json` 里的旧版本升级，首次启动时凭据会迁移到钥匙串，并从文件中删除。

## 构建与运行

需要 macOS 14+ 和**完整的 Xcode 工具链**。只装 CommandLineTools 缺少 SwiftUI 宏插件，
编译会在 `@State` 处失败。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
UNIVERSAL=0 ./Scripts/package_app.sh   # 在当前目录生成 QuotaBar.app；去掉 UNIVERSAL=0 会同时构建 Intel 版
open QuotaBar.app
```

这是一个菜单栏应用，没什么窗口可截图，可以离屏渲染各个界面，CI 会把前两条作为冒烟测试。
加上 `--lang en` 或 `--lang zh` 可以只渲染一种语言：

```bash
.build/debug/QuotaBar --snapshot ./snapshots             # 面板、停靠条、刘海条
.build/debug/QuotaBar --settings-preview ./settings      # 设置的每个分区，中英文各一份
.build/debug/QuotaBar --icon-preview ./icons             # 11 种菜单栏图标样式
.build/debug/QuotaBar --island-preview ./island          # 刘海岛各页与图表样式
.build/debug/QuotaBar --widget-concepts ./cards          # 每种桌面卡片的每个尺寸
```

毛玻璃、半透明材质和弹簧动画只在屏幕上存在，`ImageRenderer` 画不出来。要看这些效果，
请打开真实窗口：

```bash
.build/debug/QuotaBar --settings-window about
.build/debug/QuotaBar --panel-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

单独测试某个服务商：`QuotaBar --provider claude`；查看状态页：`QuotaBar --status`。

## 分发

只通过 Developer ID 分发，不上架 App Store。沙盒禁止读取 `~/.codex`、`~/.claude`
和其他应用的钥匙串项，而这正是全部功能所依赖的。

`package_app.sh` 会自动选择签名等级：

| 你有什么 | 其他用户看到什么 |
|---|---|
| 什么都没有 | 临时签名，只能在你自己的 Mac 上运行。其他人会看到*"QuotaBar 已损坏"*。 |
| Developer ID 证书 | 启用强化运行时。其他人会看到*"Apple 无法检查其是否包含恶意软件"*。 |
| 证书 + 公证 | Gatekeeper 放行，只有常规的*"从互联网下载"*提示。 |

公证凭据只需保存一次（需要一个 [App 专用密码](https://appleid.apple.com)）：

```bash
xcrun notarytool store-credentials QuotaBar \
  --apple-id you@example.com --team-id <YOUR_TEAM_ID>
```

### 发布新版本

```bash
./Scripts/release.sh
```

脚本会公证、装订票据、用 `ditto` 打包 zip（保留票据），构建签名并公证的 `.dmg`，
计算两者的 SHA-256，并把可直接提交的 Homebrew cask 写到 `dist/quotabar.rb`。
**如果 Gatekeeper 仍然拒绝这个安装包，脚本会拒绝生成发布**，签名不完整的版本不会误发给用户。
应用内更新只安装由本应用开发者签名并经 Apple 公证的下载包。

## 花费估算

根据本地的 `~/.claude/projects/**/*.jsonl`、`~/.codex/sessions/**/rollout-*.jsonl`
和 OpenCode 自己的数据库计算，价格来自按模型 ID 精确匹配的实时价目表。结果仅供参考，
**不是账单**：套餐内包含的用量、折扣，以及这些命令行工具之外发生的用量都统计不到。

有两处很容易算错，已经用测试固定下来：Claude Code 会把同一条助手回复写进每个重放它的会话文件
（按 `message.id` + `requestId` 去重）；Codex 报告的 `input_tokens` 已经包含
`cached_input_tokens`（不会重复计费）。

## 代码结构

- `Sources/QuotaCore`：服务商协议、HTTP 工具、配置与钥匙串存储、凭据读取、花费估算与用量存档、
  价目表、状态页、更新器，每组服务商一个文件。
- `Sources/QuotaBar`：应用本体，由 AppKit 状态栏项和面板承载 SwiftUI 界面，包括用量数据、
  菜单栏图标、下拉面板、设置、刘海岛、停靠条、桌面卡片、分享卡片和本地接口。
- `Tests/QuotaCoreTests`：解析样例、花费回归、配置迁移、更新校验。所有可测试的逻辑都在 QuotaCore 里。
- 官网和 Quota Run 服务在单独的仓库里。

新增服务商的方法，以及修改前值得了解的设计决策，见 [ARCHITECTURE.md](ARCHITECTURE.md)。
应用的每次改动都按日期记录在 [CHANGELOG.md](CHANGELOG.md)（英文版 [CHANGELOG.en.md](CHANGELOG.en.md)）。

## 开源致谢

QuotaBar 参考或使用了以下开源项目和字体，在此致谢。

| 项目 | 作者 | 许可 | QuotaBar 参考或使用的部分 |
|---|---|---|---|
| [codex-island](https://github.com/ericjypark/codex-island) | Eric Park | MIT | 刘海岛的样式与动效 |
| [OpenUsage](https://github.com/robinebers/openusage) | Robin Ebers | MIT | 下拉面板、用量节奏提示与分享卡片 |
| [CodexBar](https://github.com/steipete/CodexBar) | Peter Steinberger | MIT | 各服务商用量的读取方式；QuotaBar 受其启发，用 Swift 独立重新实现 |
| [theSVG](https://github.com/GLINCKER/thesvg) | thesvg.org | MIT | 服务商标志的矢量原图，保存在 `Assets/logos-src-*.svg` |
| [Instrument Sans](https://github.com/Instrument/instrument-sans) | The Instrument Sans Project Authors | SIL OFL 1.1 | QuotaBar 字标和官网所用的字体 |

QuotaBar 是独立的第三方应用，与 Anthropic、OpenAI、Cursor、Google、xAI、GitHub、X
以及文中提及的其他公司均无隶属、认可或赞助关系。相关名称和标志归各自所有者所有。

## 许可

MIT，详见 [LICENSE](LICENSE)。
