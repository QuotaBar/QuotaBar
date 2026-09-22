import SwiftUI
import QuotaCore

// MARK: - iPhone

struct PhonePane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sync: CloudSyncCenter
    @ObservedObject var relay: RelaySyncCenter
    @ObservedObject var run: RunCenter

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space4) {
            iCloudCard
            RelayCard(relay: relay, run: run)
        }
    }

    private var iCloudCard: some View {
        SettingsCard(
            L10n.t("iCloud sync", "iCloud 同步"),
            help: L10n.t(
                "The QuotaBar app on your iPhone, and its widgets, show what this Mac reads. Only the results go: plans, figures, reset times, balances. Sign-ins, tokens and keys never leave this Mac. The readings are end-to-end encrypted in your own iCloud; nobody else, us included, can read them.",
                "iPhone 上的 QuotaBar 和它的桌面小组件显示这台 Mac 读到的额度。同步的只有结果：套餐、用量、重置时间、余额；登录信息、token 和 Key 不会离开这台 Mac。数据端到端加密存放在你自己的 iCloud 里，包括我们在内的任何人都读不到。"))
        {
            SettingToggle(
                L10n.t("Send readings to iPhone", "把额度同步到 iPhone"),
                caption: L10n.t(
                    "Sent after a refresh that changed something, and every 20 minutes otherwise, so the phone knows this Mac is awake. Turning it off removes this Mac's readings from iCloud.",
                    "有变化的刷新之后同步一次；没有变化时每 20 分钟同步一次，让手机知道这台 Mac 还在线。关闭后会从 iCloud 删除这台 Mac 的数据。"),
                isOn: Binding(
                    get: { store.experience.iCloudSync },
                    set: { value in store.updateExperience { $0.iCloudSync = value } }))
                .disabled(!sync.isAvailable)
                .opacity(sync.isAvailable ? 1 : 0.45)
            if let request = sync.lastRequest {
                SettingRow(L10n.t("From the phone", "来自手机")) {
                    Text(L10n.t(
                        "\(request.from) asked for a refresh \(QuotaFormat.age(of: request.requestedAt))",
                        "\(request.from) \(QuotaFormat.age(of: request.requestedAt))请求刷新"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, Design.rowLabelInset)
                }
            }
            // A failure stays in sight, not behind the question mark.
            SettingRow(L10n.t("Status", "状态")) {
                HStack(alignment: .top, spacing: Design.space3) {
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(isFailing ? Color.red : Color.secondary)
                        .lineLimit(2)
                        // On the label's line, as `SettingRow` sets its title.
                        .padding(.top, Design.rowLabelInset)
                    Spacer(minLength: 0)
                    if store.experience.iCloudSync, sync.isAvailable {
                        Button(L10n.t("Sync now", "立即同步")) { sync.syncNow() }
                            .glassAction()
                    }
                }
            }
        }
    }

    private var isFailing: Bool {
        if case .failed = sync.status { return true }
        return false
    }

    private var statusLine: String {
        switch sync.status {
        case .off:
            L10n.t("Off.", "未开启。")
        case .unavailable:
            L10n.t(
                "This build cannot use iCloud. Install QuotaBar from quota.bar or Homebrew.",
                "这个版本不能使用 iCloud，请从 quota.bar 或 Homebrew 安装正式版。")
        case .starting:
            L10n.t("Connecting to iCloud…", "正在连接 iCloud…")
        case let .synced(date):
            L10n.t("Synced \(QuotaFormat.age(of: date))", "已同步 \(QuotaFormat.age(of: date))")
        case let .failed(message):
            L10n.t("Not synced: \(message)", "未能同步：\(message)")
        }
    }
}

// MARK: - Through Quota Run

/// For a phone on another iCloud account: the owner signs in to the same
/// Quota Run account on both, and allows the phone here. Nothing is sent
/// until a phone is allowed.
private struct RelayCard: View {
    @ObservedObject var relay: RelaySyncCenter
    @ObservedObject var run: RunCenter

    var body: some View {
        SettingsCard(
            L10n.t("Through Quota Run", "通过 Quota Run"),
            help: L10n.t(
                "For an iPhone signed in to another iCloud account. Sign in to the same Quota Run account on the phone, then allow it here. The readings are sealed on this Mac with a key only the phones you allow can open; quota.run only passes them on and cannot read them. Nothing is sent until you allow a phone.",
                "适用于和这台 Mac 不是同一个 iCloud 账号的 iPhone。在手机上登录同一个 Quota Run 账号，再在这里允许它。额度在这台 Mac 上加密，只有你允许的手机能解开；quota.run 只负责转交，读不到内容。允许任何手机之前，什么都不会发出去。"))
        {
            if run.account == nil {
                SettingRow(L10n.t("Account", "账号")) {
                    HStack(alignment: .top, spacing: Design.space3) {
                        Text(L10n.t(
                            "This Mac is not signed in to Quota Run.",
                            "这台 Mac 还没有登录 Quota Run。"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, Design.rowLabelInset)
                        Spacer(minLength: 0)
                        Button(L10n.t("Sign in…", "去登录…")) {
                            NotificationCenter.default.post(name: SettingsWindow.showSection, object: SettingsSection.run.rawValue)
                        }
                        .glassAction()
                    }
                }
            } else {
                phoneRows
                if let error = relay.actionError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                }
                SettingRow(L10n.t("Status", "状态")) {
                    HStack(alignment: .top, spacing: Design.space3) {
                        Text(statusLine)
                            .font(.system(size: 12))
                            .foregroundStyle(isFailing ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .padding(.top, Design.rowLabelInset)
                        Spacer(minLength: 0)
                        if relay.phones.contains(where: { $0.grantedAt != nil }) {
                            Button(L10n.t("Sync now", "立即同步")) { relay.syncNow() }
                                .glassAction()
                        }
                    }
                }
            }
        }
        .onAppear { relay.watch(true) }
        .onDisappear { relay.watch(false) }
    }

    @ViewBuilder
    private var phoneRows: some View {
        if !relay.phonesLoaded {
            SettingRow(L10n.t("Phones", "手机")) {
                ProgressView().controlSize(.small).padding(.top, Design.space1)
            }
        } else if relay.phones.isEmpty, let error = relay.phonesError {
            SettingRow(L10n.t("Phones", "手机")) {
                Text(L10n.t("Could not list the phones: \(error)", "无法列出手机：\(error)"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Design.rowLabelInset)
            }
        } else if relay.phones.isEmpty {
            SettingRow(L10n.t("Phones", "手机")) {
                Text(L10n.t(
                    "None yet. In QuotaBar on the iPhone, sign in to Quota Run as @\(run.account?.username ?? "").",
                    "还没有。在 iPhone 上的 QuotaBar 里用 @\(run.account?.username ?? "") 登录 Quota Run。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Design.rowLabelInset)
            }
        } else {
            ForEach(relay.phones) { phone in
                PhoneRow(phone: phone, relay: relay)
            }
        }
    }

    private var isFailing: Bool {
        if case .failed = relay.status { return true }
        return false
    }

    private var statusLine: String {
        switch relay.status {
        case .signedOut, .idle:
            L10n.t("Nothing sent: no phone allowed.", "未发送：还没有允许任何手机。")
        case let .synced(date):
            L10n.t("Sent \(QuotaFormat.age(of: date))", "已发送 \(QuotaFormat.age(of: date))")
        case let .failed(message):
            L10n.t("Not sent: \(message)", "未能发送：\(message)")
        }
    }
}

private struct PhoneRow: View {
    let phone: RelayClient.Phone
    @ObservedObject var relay: RelaySyncCenter

    private var code: String? {
        phone.agreementKey.flatMap(Base64URL.decode).map(SyncCrypto.safetyCode(for:))
    }

    var body: some View {
        SettingRow(phone.name) {
            HStack(alignment: .top, spacing: Design.space3) {
                VStack(alignment: .leading, spacing: Design.space1) {
                    Text(stateLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let code {
                        Text(L10n.t("Code \(code)", "安全码 \(code)"))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, Design.rowLabelInset)
                Spacer(minLength: 0)
                if relay.working == phone.deviceId {
                    ProgressView().controlSize(.small).padding(.top, Design.space1)
                } else if phone.grantedAt != nil {
                    Button(L10n.t("Revoke", "撤销")) { relay.revoke(phone) }
                        .glassAction()
                        .disabled(relay.working != nil)
                } else if phone.agreementKey != nil {
                    Button(L10n.t("Allow", "允许")) { relay.allow(phone) }
                        .glassAction(prominent: true)
                        .disabled(relay.working != nil)
                        .help(L10n.t(
                            "Allow only if the phone shows the same code.",
                            "手机上显示的安全码和这里一致时再允许。"))
                }
            }
        }
    }

    private var stateLine: String {
        if phone.grantedAt != nil {
            let seen = phone.lastSeenAt.map { QuotaFormat.age(of: Date(timeIntervalSince1970: $0)) }
            return seen.map { L10n.t("Allowed · last seen \($0)", "已允许 · \($0)在线") }
                ?? L10n.t("Allowed", "已允许")
        }
        if phone.agreementKey != nil {
            return L10n.t("Waiting for you to allow it", "等待你允许")
        }
        return L10n.t("Signed in; open QuotaBar on the phone once", "已登录，请在手机上打开一次 QuotaBar")
    }
}
