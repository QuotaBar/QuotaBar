import SwiftUI
import QuotaCore

// MARK: - On the Claude card

/// Under the Claude card's arrow: the card's own sign-in first, then every
/// other config dir's with its session and weekly limits (issue #8). Nothing
/// while Claude Code has only the one sign-in.
struct ClaudeSignInsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var signIns: ClaudeSignInsModel
    var compact = false

    private var accent: Color { Color(hex: ProviderID.claude.accentHex) }

    var body: some View {
        if !signIns.others.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Text(L10n.t("Accounts", "账号"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                cardRow
                ForEach(Array(signIns.others.enumerated()), id: \.element.id) { index, reading in
                    otherRow(reading, number: index + 2)
                }
            }
        }
    }

    private var cardRow: some View {
        let snapshot = store.states[.claude]?.snapshot
        let identity = signIns.card ?? snapshot.map { ClaudeProvider.Identity(email: $0.account) }
        return VStack(alignment: .leading, spacing: 2) {
            header(identity, service: store.claudeCardService, plan: snapshot?.planName, number: 1, onCard: true)
        }
        .help(L10n.t("Claude Code's default sign-in, which the card shows.", "Claude Code 的默认登录，也就是卡片上显示的这个。"))
    }

    private func otherRow(_ reading: ClaudeSignIns.Reading, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header(reading.identity, service: reading.id, plan: reading.snapshot?.planName ?? reading.plan, number: number, onCard: false)
            Group {
                let windows = limits(reading.snapshot)
                if !windows.isEmpty {
                    Text(windows.map(figure).joined(separator: "  ·  "))
                }
                if let error = reading.error {
                    Text(error).foregroundStyle(reading.discardsCachedReading ? Color.white.opacity(0.5) : Palette.amber)
                } else if windows.isEmpty {
                    Text(L10n.t("Reading…", "读取中…"))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(2)
            .padding(.leading, 12)
        }
        .help(reading.id)
    }

    private func header(_ identity: ClaudeProvider.Identity?, service: String, plan: String?, number: Int, onCard: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(onCard ? accent : .white.opacity(0.2))
                .frame(width: 6, height: 6)
            Text(identity?.email == nil ? signIns.label(identity, number: number, masked: store.isPrivacyMasked) : signIns.pickerLabel(service, masked: store.isPrivacyMasked))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(onCard ? 0.9 : 0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            if let plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 6)
            if onCard {
                Text(L10n.t("On the card", "卡片显示中"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    /// The session and the week — the two limits every organization has —
    /// else whatever bites first.
    private func limits(_ snapshot: UsageSnapshot?) -> [UsageWindow] {
        guard let snapshot else { return [] }
        let plain = snapshot.windows.filter { !$0.extra && $0.scope == nil && $0.usedPercent != nil }
        if !plain.isEmpty { return Array(plain.prefix(2)) }
        return snapshot.headlineWindow.map { [$0] } ?? []
    }

    /// "5h · 64% left · resets in 2h 10m", in the reading's own terms.
    private func figure(_ window: UsageWindow) -> String {
        let shown = store.meterMode.shownPercent(fromUsed: window.usedPercent ?? 0)
        var parts = [
            window.shortLabel ?? window.title,
            store.meterMode == .used
                ? L10n.t("\(QuotaFormat.percent(shown)) used", "已用 \(QuotaFormat.percent(shown))")
                : L10n.t("\(QuotaFormat.percent(shown)) left", "剩余 \(QuotaFormat.percent(shown))"),
        ]
        return parts.joined(separator: " ")
    }
}

// MARK: - The arrow after the card's account

/// The account line of the Claude card with a menu on it: every sign-in on
/// this Mac, the one in use ticked. Only while there are two or more; with
/// one there is nothing to choose and the line stays plain text.
struct ClaudeAccountPicker: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var signIns: ClaudeSignInsModel
    let account: String

    var body: some View { menu }

    private var plain: some View {
        Text(account)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var menu: some View {
        Menu {
            ForEach(signIns.services, id: \.self) { service in
                Toggle(signIns.pickerLabel(service, masked: store.isPrivacyMasked), isOn: Binding(
                    get: { store.claudeCardService == service },
                    set: { on in if on { store.useClaudeSignIn(service) } }))
            }
            Divider()
            Button(L10n.t("Manage accounts…", "管理账号／添加账号…")) { SettingsWindow.open(provider: .claude) }
        } label: {
            // One run of text, so the arrow cannot land before the address.
            (Text(account) + Text(" ") + Text(Image(systemName: "chevron.down")).font(.system(size: 8, weight: .semibold)))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Switch Claude sign-in", "切换 Claude 登录"))
    }
}

// MARK: - In Settings

/// The Claude row's other sign-ins: what was found, and how to add one.
struct ClaudeSignInsSettings: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var signIns: ClaudeSignInsModel
    @State private var name = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            ForEach(signIns.services, id: \.self) { service in
                let missing = ClaudeSignIns.directoryMissing(service: service)
                let reading = signIns.allReadings[service]
                let snapshot = service == store.claudeCardService ? store.states[.claude]?.snapshot : reading?.snapshot
                let duplicate = service != LocalCredentials.claudeService && ClaudeSignIns.sameAccount(signIns.identities[service], signIns.identities[LocalCredentials.claudeService])
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Design.space2) {
                        Text(signIns.pickerLabel(service, masked: store.isPrivacyMasked))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if duplicate {
                            Text(L10n.t("Same as default", "与默认登录相同")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if reading?.needsAuthorization == true {
                            Button(L10n.t("Allow access", "授权读取")) { store.authorizeClaude() }
                                .glassAction(compact: true)
                        }
                        if missing {
                            Button(L10n.t("Add again", "重新添加")) {
                                notice = store.addClaudeAccount(name: store.experience.claudeAccountNames[service] ?? "", replacing: service)
                            }.glassAction(compact: true)
                        } else if service != LocalCredentials.claudeService && (duplicate || snapshot == nil || reading?.error != nil || store.states[.claude]?.errorMessage != nil) {
                            Button(duplicate ? L10n.t("Sign in to another account", "换账号登录") : L10n.t("Sign in", "登录")) { notice = store.reconnectClaudeAccount(service) }
                                .glassAction(compact: true)
                        }
                        if service == store.claudeCardService {
                            Text(L10n.t("In use", "使用中")).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if !missing {
                            Button(L10n.t("Use", "使用")) { store.useClaudeSignIn(service) }
                                .glassAction(compact: true)
                                .disabled(service != LocalCredentials.claudeService && reading?.snapshot == nil)
                        }
                        if service != LocalCredentials.claudeService {
                            Button(L10n.t("Remove", "移除")) { store.removeClaudeSignIn(service) }
                                .glassAction(compact: true)
                                .help(L10n.t("Forget in QuotaBar; Claude Code's login and files stay intact.", "只从 QuotaBar 移除，保留 Claude Code 的登录和文件。"))
                        }
                    }
                    if store.claudeLoginsPending.contains(service) {
                        Text(L10n.t("Waiting for browser login; updates automatically when complete.", "等待浏览器登录，完成后会自动更新。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !store.isPrivacyMasked, let note = store.experience.claudeAccountNames[service], !note.isEmpty {
                        Text(L10n.t("Note: \(note)", "备注：\(note)")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if missing {
                        Text(L10n.t("Login folder not found. Add it again or remove this entry.", "找不到登录目录，请重新添加或移除这项记录。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if service != LocalCredentials.claudeService, reading?.snapshot == nil, service != store.claudeCardService, !store.claudeLoginsPending.contains(service) {
                        Text(reading?.error ?? L10n.t("Complete browser login to update automatically.", "完成浏览器登录后，会自动更新。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack(spacing: Design.space2) {
                TextField(L10n.t("Account note (optional)", "账号备注（可选）"), text: $name)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.t("Add account", "添加账号")) {
                    notice = store.addClaudeAccount(name: name)
                    if notice == nil { name = "" }
                }.glassAction(prominent: true)
                Button(L10n.t("Check accounts", "检查账号")) {
                    LocalCredentials.invalidateClaudeToken()
                    Task { await store.readClaudeSignIns(force: true); store.refresh(.claude) }
                }.glassAction(compact: true)
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(L10n.t(
                "The list shows the account Claude actually signed in to; notes are labels only. Choose a different account in the browser; the list updates after login. Check accounts refreshes manually. Remove an entry to stop reading it.",
                "上方显示 Claude 实际登录的账号，备注只是标记。请在浏览器里选择另一个账号，登录完成后列表会自动更新；也可点击「检查账号」手动刷新。移除后不再读取或提示这项登录。"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await store.readClaudeSignIns() }
    }
}

/// Recovery stays actionable even when the card has no account snapshot.
struct ClaudeSignInRecovery: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var signIns: ClaudeSignInsModel
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 8) {
            Menu(L10n.t("Choose account", "选择账号")) {
                ForEach(signIns.services.filter { !ClaudeSignIns.directoryMissing(service: $0) }, id: \.self) { service in
                    Button(signIns.pickerLabel(service, masked: store.isPrivacyMasked)) { store.useClaudeSignIn(service) }
                }
                Button(L10n.t("Manage accounts…", "管理账号…")) { SettingsWindow.open(provider: .claude) }
            }
            if ClaudeSignIns.directoryMissing(service: store.claudeCardService) {
                Button(L10n.t("Add again", "重新添加")) {
                    notice = store.addClaudeAccount(name: store.experience.claudeAccountNames[store.claudeCardService] ?? "", replacing: store.claudeCardService)
                }
                Button(L10n.t("Remove", "移除")) { store.removeClaudeSignIn(store.claudeCardService) }
            } else {
                Button(L10n.t("Manage accounts", "管理账号")) { SettingsWindow.open(provider: .claude) }
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .foregroundStyle(Color(hex: ProviderID.claude.accentHex))
        .alert(L10n.t("Claude login", "Claude 登录"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(L10n.t("OK", "好")) { notice = nil }
        } message: { Text(notice ?? "") }
    }
}
