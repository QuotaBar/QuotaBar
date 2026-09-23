import SwiftUI
import QuotaCore

// MARK: - On the Codex card

/// Under the Codex card's arrow: every kept account, the one the CLI is
/// signed in as first, each other one with the limit that bites first and
/// a button to switch to it (issue #6). Nothing until an account is kept.
struct CodexAccountsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: CodexAccountsModel
    var compact = false

    var body: some View {
        if !accounts.saved.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Text(L10n.t("Accounts", "账号"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                if let active = activeAccount {
                    row(active, active: true)
                }
                ForEach(accounts.others) { account in
                    row(account, active: false)
                }
            }
            .task { await accounts.reload() }
        }
    }

    /// The account the CLI is signed in as — kept or not, it is on the card.
    private var activeAccount: CodexAccount? {
        guard let id = accounts.activeID else { return nil }
        if let kept = accounts.saved.first(where: { $0.id == id }) { return kept }
        return CodexAccount(id: id, email: store.states[.codex]?.snapshot?.account, plan: nil, savedAt: .now)
    }

    private func row(_ account: CodexAccount, active: Bool) -> some View {
        let reading = accounts.readings[account.id]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Color(hex: ProviderID.codex.accentHex) : .white.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(accounts.label(account, masked: store.isPrivacyMasked))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(active ? 0.9 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = CodexProvider.planName(account.plan) {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 6)
                if active {
                    Text(L10n.t("In use", "使用中"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: ProviderID.codex.accentHex))
                } else {
                    Pressable(action: { store.switchCodexAccount(account.id) }) {
                        Text(L10n.t("Switch", "切换"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .disabled(accounts.working)
                    .help(L10n.t(
                        "Sign the Codex CLI in as this account. Sessions already running keep the old one until restarted.",
                        "让 Codex CLI 改用这个账号登录。已经在运行的会话要重启后才会用新账号。"))
                }
            }
            if !active {
                Group {
                    if let window = reading?.snapshot?.headlineWindow, let used = window.usedPercent {
                        Text(figure(window, used: used))
                    } else if let error = reading?.error {
                        Text(error).foregroundStyle(Palette.amber)
                    } else {
                        Text(L10n.t("Reading…", "读取中…"))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .padding(.leading, 12)
            }
        }
    }

    /// "Weekly · 64% left · resets in 3d 2h", in the reading's own terms.
    private func figure(_ window: UsageWindow, used: Double) -> String {
        let shown = store.meterMode.shownPercent(fromUsed: used)
        var parts = [
            window.shortLabel ?? window.title,
            store.meterMode == .used
                ? L10n.t("\(QuotaFormat.percent(shown)) used", "已用 \(QuotaFormat.percent(shown))")
                : L10n.t("\(QuotaFormat.percent(shown)) left", "剩余 \(QuotaFormat.percent(shown))"),
        ]
        if let reset = window.resetsAt { parts.append(store.resetText(reset)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - In the card's right-click menu

/// Switch to a kept account, or keep the one signed in.
struct CodexAccountsMenu: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: CodexAccountsModel

    var body: some View {
        Menu(L10n.t("Codex Accounts", "Codex 账号")) {
            ForEach(accounts.saved) { account in
                Toggle(accounts.label(account, masked: store.isPrivacyMasked), isOn: Binding(
                    get: { accounts.activeID == account.id },
                    set: { on in if on { store.switchCodexAccount(account.id) } }))
                    .disabled(accounts.working)
            }
            if !accounts.saved.isEmpty { Divider() }
            Button(accounts.isActiveSaved
                ? L10n.t("Update the Saved Copy of This Account", "更新当前账号的保存副本")
                : L10n.t("Save Current Account", "保存当前账号")) { store.saveCurrentCodexAccount() }
                .disabled(accounts.activeID == nil || accounts.working)
        }
        .task { await accounts.reload() }
    }
}

// MARK: - In Settings

/// The Codex row's account list: keep the one signed in, switch, forget.
struct CodexAccountsSettings: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: CodexAccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            ForEach(accounts.saved) { account in
                HStack(spacing: Design.space2) {
                    Text(account.email ?? account.id)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = CodexProvider.planName(account.plan) {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Design.space2)
                    if accounts.activeID == account.id {
                        Text(L10n.t("In use", "使用中"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(L10n.t("Switch", "切换")) { store.switchCodexAccount(account.id) }
                            .glassAction(compact: true)
                            .disabled(accounts.working)
                    }
                    Button(L10n.t("Remove", "移除")) { store.removeCodexAccount(account.id) }
                        .glassAction(compact: true)
                        .disabled(accounts.working)
                        .help(L10n.t(
                            "Forget this account in QuotaBar. The Codex CLI keeps it if it is the one signed in.",
                            "在 QuotaBar 里忘掉这个账号。如果它正是 Codex CLI 当前登录的账号，CLI 那边不受影响。"))
                }
            }
            HStack(spacing: Design.space2) {
                Button(accounts.isActiveSaved
                    ? L10n.t("Update Saved Copy", "更新保存副本")
                    : L10n.t("Save Current Account", "保存当前账号")) { store.saveCurrentCodexAccount() }
                    .glassAction(prominent: !accounts.isActiveSaved)
                    .disabled(accounts.activeID == nil || accounts.working)
                if let notice = store.codexSwitchNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L10n.t(
                "Sign in to each account with `codex login`, then save it here. Switching rewrites ~/.codex/auth.json and keeps the account you leave, so nothing needs signing in twice. Saved sign-ins stay in this Mac's keychain.",
                "用 `codex login` 依次登录每个账号，登录后在这里保存。切换会改写 ~/.codex/auth.json，并自动保存你离开的那个账号，不用重复登录。保存的登录信息只存在这台 Mac 的钥匙串里。"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await accounts.reload() }
    }
}
