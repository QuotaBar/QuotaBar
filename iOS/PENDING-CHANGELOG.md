# iPhone 上架时的更新日志

Mac 端的 iPhone 分区（iCloud 同步、通过 Quota Run）已经在代码里，但在 iPhone 版上架前设置里不显示
（`SettingsSection.showsPhone`）。上架那一版把这里的条目移进 `CHANGELOG.md` / `CHANGELOG.en.md` 的「未发布」，
去掉开关，再删掉这个文件。

## 中文

#### 新增

- 设置里新增「iPhone」分区，可以把额度同步到你自己的 iCloud，给即将推出的 iPhone 版 QuotaBar 和它的桌面小组件使用。默认关闭，打开「把额度同步到 iPhone」后才会同步。同步的只有读到的结果：套餐、用量、重置时间、余额、最近一次出错的原因，以及卡片展开后能看到的花费（今日、昨日、30 天和各模型明细，按你在 Mac 上选的货币）、近 30 天用量和控制台链接；登录信息、token 和 API Key 不会离开这台 Mac。数据端到端加密存放在你的 iCloud 私有数据库里，别人（包括我们）都读不到。每次刷新后，只要数字有变化就同步；没有变化时每 20 分钟同步一次，让手机知道这台 Mac 还在线。有几台 Mac 时各自存一份，手机上每个服务商取最新的那份。关闭后会从 iCloud 删除这台 Mac 的数据。开着同步时，手机上点「让 Mac 立即刷新」，Mac 会在半分钟内刷新全部服务商并马上同步回去；两次手机触发的刷新至少间隔 1 分钟，超过 10 分钟的旧请求会被忽略。分区里会直接显示同步状态和出错原因，也有「立即同步」按钮。
- 设置 → iPhone 里新增「通过 Quota Run」：iPhone 和这台 Mac 不是同一个 iCloud 账号时，也能在手机上看到额度。在手机版 QuotaBar 里登录同一个 Quota Run 账号，Mac 这里就会列出这台手机（同时发一条通知）；核对手机和 Mac 上显示的 6 位安全码一致后点「允许」即可。额度在这台 Mac 上端到端加密，只有你允许的手机能解开，quota.run 只负责转交，读不到内容；允许任何手机之前什么都不会发出去。「撤销」会立即换一把新密钥，被撤销的手机再也解不开之后的数据，其他已允许的手机自动拿到新密钥。手机上的「让 Mac 立即刷新」也会经 quota.run 送达；同一次点击同时从 iCloud 和 quota.run 到达时只刷新一次。
- 设置 → iPhone 的说明改为「通过你的 iCloud 或 Quota Run 账号」。

## English

#### Added

- A new iPhone section in Settings sends your readings to your own iCloud, for the upcoming QuotaBar for iPhone and its home-screen widgets. It is off until you turn on "Send readings to iPhone". Only the results go — plans, figures, reset times, balances, the last error, and what a card shows under its arrow: spend for today, yesterday and 30 days with its models (in the currency you chose on the Mac), a month of usage, and the console link; sign-ins, tokens and API keys never leave the Mac. The readings are end-to-end encrypted in your private iCloud database, where nobody else, us included, can read them. A refresh that changed something is sent straight away, and otherwise every 20 minutes so the phone knows the Mac is awake. With several Macs each keeps its own copy and the phone shows the newest reading per provider. Turning it off removes this Mac's readings from iCloud. While it is on, "Refresh now" on the phone has the Mac read every provider within half a minute and send the result straight back; refreshes the phone asks for are at least a minute apart, and a request older than ten minutes is ignored. The section shows the sync status and any error in plain sight, with a Sync now button.
- Settings → iPhone gains "Through Quota Run": readings on an iPhone signed in to another iCloud account than this Mac. Sign in to the same Quota Run account in QuotaBar on the phone and it shows up here (with a notification); allow it once the six-digit code matches the one on the phone. The readings are end-to-end encrypted on this Mac for the phones you allow — quota.run only passes them on and cannot read them — and nothing is sent until you allow one. Revoking a phone switches to a new key at once, so it cannot open anything sent afterwards, and the phones still allowed get the new key. "Ask the Mac to refresh" on the phone arrives this way too; one press arriving by iCloud and by quota.run refreshes once.
- Settings → iPhone now reads "through your iCloud or your Quota Run account".
