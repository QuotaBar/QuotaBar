import SwiftUI
import QuotaCore

// MARK: - In Settings

/// Settings › Providers: the profiles, and the Claude sign-in and Codex
/// account each one reads. Shown once there is something to choose between.
struct ProfilesSettingsCard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var signIns: ClaudeSignInsModel
    @ObservedObject var accounts: CodexAccountsModel

    private var shown: Bool {
        !store.accountProfiles.isEmpty || signIns.services.count > 1 || accounts.saved.count > 1
    }

    var body: some View {
        Group {
            if shown {
                SettingsCard(L10n.t("Profiles", "账号组"), help: L10n.t(
                    "A profile is one Claude sign-in and one Codex account — Personal and Work, say. The profile in use decides which accounts the Claude and Codex cards read, and the menu bar, the island and the dock follow. Switch with the arrow after the address on the Claude or Codex card, or from the panel's ⋯ menu. It never changes what the CLIs are signed in as.",
                    "一个账号组就是一个 Claude 登录加一个 Codex 账号，比如「个人」和「工作」。当前账号组决定 Claude 和 Codex 卡片读取哪些账号，菜单栏、刘海岛和停靠条都跟着变。用 Claude、Codex 卡片上邮箱后面的箭头切换，或在面板的 ⋯ 菜单里切换。切换不会改变 CLI 当前登录的账号。"))
                {
                    steps
                    ForEach(store.accountProfiles) { profile in
                        Divider().opacity(0.4)
                        row(profile)
                    }
                    Divider().opacity(0.4)
                    HStack(spacing: Design.space2) {
                        Button(L10n.t("Add Profile", "添加账号组")) { store.addProfile() }
                            .glassAction(prominent: store.accountProfiles.count < 2)
                        if store.accountProfiles.count < 2 {
                            Text(L10n.t(
                                "Profiles take effect once there are two to switch between.",
                                "有两个账号组时才能切换，才会生效。"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task {
            await store.readClaudeSignIns()
            await accounts.reload()
        }
    }

    /// What it takes, in order — the reporter of #8 found it on the third go.
    private var steps: some View {
        VStack(alignment: .leading, spacing: Design.space1) {
            Text(L10n.t(
                "1. Sign in to each account once. Codex: `codex login`, then Save Current Account in the Codex row above. Claude: `CLAUDE_CONFIG_DIR=<dir> claude`, then /login, for each organization beside the default one.",
                "1. 每个账号先登录一次。Codex：运行 `codex login`，再到上面 Codex 那一行点「保存当前账号」。Claude：默认登录之外的每个组织，用 `CLAUDE_CONFIG_DIR=<目录> claude` 启动并 /login。"))
            Text(L10n.t(
                "2. Add a profile for each — Personal, Work — and pick its Claude sign-in and Codex account.",
                "2. 为每组账号添加一个账号组，比如「个人」「工作」，选好它的 Claude 登录和 Codex 账号。"))
            Text(L10n.t(
                "3. Switch with the arrow after the address on the Claude or Codex card, or from the panel's ⋯ menu.",
                "3. 用 Claude、Codex 卡片上邮箱后面的箭头切换，或在面板的 ⋯ 菜单里切换。"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            HStack(spacing: Design.space2) {
                GlassTextField(
                    placeholder: L10n.t("Name", "名称"),
                    text: Binding(
                        get: { profile.name },
                        set: { name in rename(profile.id, to: name) }),
                    monospaced: false)
                    .frame(width: 160)
                Spacer(minLength: Design.space2)
                if store.activeProfile?.id == profile.id {
                    Text(L10n.t("In use", "使用中"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if store.accountProfiles.count > 1 {
                    Button(L10n.t("Use", "使用")) { store.setActiveProfile(profile.id) }
                        .glassAction(compact: true)
                }
                Button(L10n.t("Remove", "移除")) {
                    store.updateProfiles { $0.removeAll { $0.id == profile.id } }
                }
                .glassAction(compact: true)
            }
            SettingRow("Claude") {
                GlassPopUp(
                    options: claudeChoices(including: profile.claudeItem),
                    selection: profile.claudeItem,
                    onSelect: { service in
                        store.updateProfiles { profiles in
                            guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                            profiles[index].claudeService = service == LocalCredentials.claudeService ? nil : service
                        }
                    })
                    .frame(width: 320)
            }
            SettingRow("Codex") {
                GlassPopUp(
                    options: codexChoices(including: profile.codexAccountID),
                    selection: profile.codexAccountID ?? "",
                    onSelect: { id in
                        store.updateProfiles { profiles in
                            guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                            profiles[index].codexAccountID = id.isEmpty ? nil : id
                        }
                    })
                    .frame(width: 320)
            }
        }
    }

    private func rename(_ id: String, to name: String) {
        store.updateProfiles { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].name = name
        }
    }

    /// Every Claude Code sign-in on this Mac, the default first; one a
    /// profile picked that has since gone stays listed, so the choice reads
    /// as what it is.
    private func claudeChoices(including picked: String) -> [(value: String, label: String)] {
        var services = signIns.services.isEmpty ? [LocalCredentials.claudeService] : signIns.services
        if !services.contains(picked) { services.append(picked) }
        return services.map { (value: $0, label: signIns.choiceLabel($0, masked: store.isPrivacyMasked)) }
    }

    /// Every kept account. Following the CLI's sign-in is offered only
    /// before any is kept, or while this profile still does: once both
    /// accounts are kept it is always one of them again (#8).
    private func codexChoices(including picked: String?) -> [(value: String, label: String)] {
        var choices: [(value: String, label: String)] = []
        if accounts.saved.isEmpty || picked == nil {
            choices.append((value: "", label: L10n.t("Follow the Codex CLI's sign-in", "跟随 Codex CLI 当前登录的账号")))
        }
        for account in accounts.saved {
            var label = accounts.label(account, masked: store.isPrivacyMasked)
            if let plan = CodexProvider.planName(account.plan) { label += " · \(plan)" }
            choices.append((value: account.id, label: label))
        }
        if let picked, !accounts.saved.contains(where: { $0.id == picked }) {
            choices.append((value: picked, label: L10n.t("An account no longer kept", "已不再保存的账号")))
        }
        return choices
    }
}
