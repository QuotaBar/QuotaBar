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
                    Text(error).foregroundStyle(Palette.amber)
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

    var body: some View {
        if signIns.services.count > 1 { menu } else { plain }
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            ForEach(Array(signIns.others.enumerated()), id: \.element.id) { index, reading in
                HStack(spacing: Design.space2) {
                    Text(signIns.label(reading.identity, number: index + 2, masked: store.isPrivacyMasked))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let email = signIns.detail(reading.identity, masked: store.isPrivacyMasked) {
                        Text(email)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let plan = reading.snapshot?.planName ?? reading.plan {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .help(reading.error ?? reading.id)
            }
            Text(L10n.t(
                "Claude Code keeps one sign-in per config dir, and each is tied to one organization. Sign in to another with `CLAUDE_CONFIG_DIR=<dir> claude`, then /login, and it shows up here and under the Claude card's arrow by itself. QuotaBar only reads these sign-ins; Claude Code renews each while it runs with that dir.",
                "Claude Code 每个配置目录一个登录，每个登录对应一个组织。用 `CLAUDE_CONFIG_DIR=<目录> claude` 启动并 /login 登录另一个组织或账号后，它会自动出现在这里和 Claude 卡片展开后的列表里。QuotaBar 只读取这些登录；每个登录由 Claude Code 在用那个目录运行时自己续期。"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await store.readClaudeSignIns() }
    }
}
