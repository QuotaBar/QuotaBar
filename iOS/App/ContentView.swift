import QuotaModel
import SwiftUI

struct ContentView: View {
    let model: ReadingsModel
    @State private var showsHelp = false
    @AppStorage(MeterPreference.key, store: MeterPreference.store) private var meterMode: MeterMode = .remaining
    @State private var path: [ProviderID] = []
    /// "Image copied", for a moment.
    @State private var notice: String?

    var body: some View {
        NavigationStack(path: $path) {
            // A List rather than a stack of cards in a ScrollView: its rows
            // reorder with the system's own long-press drag (`onMove`), no
            // edit mode, and a tap still opens the detail.
            List {
                Group {
                    header
                    FreshnessBanner(readings: model.readings, error: model.error, macRefresh: model.macRefresh)
                    if model.isDemo && !Demo.isForScreenshots {
                        DemoBanner { withAnimation(.snappy) { model.endDemo() } }
                    }
                    if !pendingMacs.isEmpty {
                        AllowOnMacPrompt(macs: pendingMacs, code: model.quotaRun.safetyCode)
                    }
                    if model.readings.items.isEmpty && pendingMacs.isEmpty {
                        EmptyReadings(model: model)
                    }
                }
                .moveDisabled(true)
                .modifier(CardRows())
                ForEach(model.readings.items) { item in
                    Button {
                        path.append(item.provider)
                    } label: {
                        ProviderCard(item: item, money: model.readings.money, status: model.status[item.provider])
                    }
                    .buttonStyle(.plain)
                    // Press and hold: the menu; press, hold and move: the
                    // card is picked up and reorders instead.
                    .contextMenu {
                        CardShareActions(item: item, model: model, notice: $notice)
                    }
                    .modifier(CardRows())
                }
                .onMove { from, to in
                    withAnimation(.snappy) { model.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(12)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .refreshable { await model.refresh() }
            .background(Color.black)
            // The name is drawn as the Mac draws it, not as a system title.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsHelp) { HowItWorks(model: model) }
            // The approval page over the main page; the sync sheet shows its
            // own when the sign-in starts there.
            .sheet(isPresented: Binding(
                get: { model.quotaRun.showsPage && !showsHelp },
                set: { model.quotaRun.showsPage = $0 }))
            {
                if case let .waiting(url) = model.quotaRun.phase { ApprovalPage(url: url).ignoresSafeArea() }
            }
            #if DEBUG
            // `-QuotaBarOpen claude`: straight to one provider's detail, for
            // screenshots.
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard let index = arguments.firstIndex(of: "-QuotaBarOpen"), index + 1 < arguments.count,
                      let provider = ProviderID(rawValue: arguments[index + 1]), path.isEmpty
                else { return }
                try? await Task.sleep(for: .seconds(0.5))
                path = [provider]
            }
            #endif
                        .navigationDestination(for: ProviderID.self) { provider in
                ProviderDetail(model: model, provider: provider, notice: $notice)
            }
        }
        .overlay(alignment: .bottom) { NoticePill(text: notice) }
        .animation(.snappy, value: notice)
        // Signed in to Quota Run and a Mac still to allow this phone, or to
        // send its first readings: look again every few seconds, so the
        // cards appear while the owner is still at the Mac.
        .task(id: awaitingMac) {
            guard awaitingMac else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await model.refresh(statusPages: false)
            }
        }
    }

    /// Macs on the Quota Run account that have not allowed this phone yet,
    /// less any whose readings arrive through iCloud anyway.
    private var pendingMacs: [RelayMac] {
        let viaCloud = Set(model.readings.devices.map(\.name))
        return model.quotaRun.waitingMacs.filter { !viaCloud.contains($0.name) }
    }

    private var awaitingMac: Bool {
        model.quotaRun.account != nil && (!pendingMacs.isEmpty || model.readings.items.isEmpty)
    }

    private var header: some View {
        HStack(spacing: 0) {
            BrandLockup()
            Spacer(minLength: 0)
            // Every figure on the page, as what is left or what is used.
            Button {
                withAnimation(.snappy) { meterMode = meterMode == .remaining ? .used : .remaining }
            } label: {
                Text(meterMode.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: meterMode)
            .accessibilityLabel(L10n.t("Show", "显示"))
            .accessibilityValue(meterMode.displayName)
            .accessibilityHint(L10n.t("Switches between what is left and what is used", "在剩余和已用之间切换"))
            // Asks the Mac to read everything now, rather than waiting for
            // its next refresh.
            Button {
                Task { await model.askMacToRefresh() }
            } label: {
                Group {
                    if case .asking = model.macRefresh {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(model.readings.devices.isEmpty && !model.isDemo)
            .accessibilityLabel(L10n.t("Ask the Mac to refresh", "让 Mac 立即刷新"))
            Button {
                showsHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("How it works", "工作原理"))
        }
        .padding(.top, 8)
    }
}

/// Rows drawn as the cards they hold: no separators, no row fill, the
/// page's own margins.
private struct CardRows: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

// MARK: - How far to trust the figures

/// Said at the top, always: when the Mac last wrote, and whether it seems to
/// have stopped. A figure from a sleeping Mac is never shown as current.
private struct FreshnessBanner: View {
    let readings: MergedReadings
    let error: String?
    /// A "refresh now" in flight takes the place of the age, in this line —
    /// "正在请求更新…", then "已刷新" — rather than a line of its own.
    var macRefresh: ReadingsModel.MacRefresh = .idle

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                Image(systemName: symbol(at: context.date))
                    .foregroundStyle(color(at: context.date))
                Text(line(at: context.date))
                    .font(.footnote)
                    .foregroundStyle(color(at: context.date))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .animation(.snappy, value: macRefresh)
        }
    }

    private var mac: String {
        let name = readings.latestDeviceName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        let others = readings.devices.count - 1
        return name + (others > 0 ? L10n.t(" and \(others) more", " 等 \(others + 1) 台") : "")
    }

    private func line(at now: Date) -> String {
        switch macRefresh {
        case .asking:
            return L10n.t("\(mac) · asking for an update…", "\(mac) · 正在请求更新…")
        case .done:
            return L10n.t("\(mac) · refreshed", "\(mac) · 已刷新")
        case .noAnswer:
            return L10n.t(
                "\(mac) did not answer — asleep, or iCloud sync is off",
                "\(mac) 没有响应，可能已睡眠或没开 iCloud 同步")
        case let .failed(message):
            return message
        case .idle:
            break
        }
        if let error, readings.updatedAt == nil { return error }
        switch readings.freshness(now: now) {
        case .nothing:
            return L10n.t("Waiting for your Mac…", "正在等待 Mac…")
        case .current:
            let age = readings.updatedAt.map { QuotaFormat.age(of: $0, now: now) } ?? ""
            return L10n.t("\(mac) · updated \(age)", "\(mac) · \(age)更新")
        case let .macQuiet(since):
            return L10n.t(
                "Your Mac has not sent anything since \(QuotaFormat.age(of: since, now: now)) — it may be asleep. Figures may be out of date.",
                "Mac 从 \(QuotaFormat.age(of: since, now: now))起没有再同步，可能已睡眠，数字可能已过时。")
        }
    }

    private func color(at now: Date) -> Color {
        switch macRefresh {
        case .done: return Color(hex: UsageRamp.hex(used: 0))
        case .noAnswer, .failed: return .orange
        case .asking: return .secondary
        case .idle: return isWarning(at: now) ? .orange : .secondary
        }
    }

    private func isWarning(at now: Date) -> Bool {
        if case .macQuiet = readings.freshness(now: now) { return true }
        return error != nil && readings.updatedAt == nil
    }

    private func symbol(at now: Date) -> String {
        switch macRefresh {
        case .noAnswer, .failed: return "exclamationmark.triangle"
        default:
            if case .idle = macRefresh, isWarning(at: now) { return "exclamationmark.triangle" }
            return readings.devices.first?.kind.symbolName ?? "desktopcomputer"
        }
    }
}

// MARK: - Nothing yet

/// No Mac yet: the two ways a phone gets readings. Same iCloud account —
/// nothing to do here; another one — sign in to Quota Run. Neither needs
/// the other, and the app works without signing in.
private struct EmptyReadings: View {
    let model: ReadingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("No readings yet", "还没有数据"))
                .font(.headline)
            Text(L10n.t(
                "QuotaBar for iPhone shows what QuotaBar on your Mac reads. Pick how it gets here:",
                "iPhone 版 QuotaBar 显示的是 Mac 版 QuotaBar 读到的额度。选择同步方式："))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            choice(
                symbol: "icloud",
                title: L10n.t("Same iCloud account", "同一个 iCloud 账号"),
                detail: L10n.t(
                    "No sign-in. On the Mac, open Settings › iPhone and turn on “Send readings to iPhone”.",
                    "无需登录。在 Mac 上打开 设置 › iPhone，开启「把额度同步到 iPhone」。"))
            if model.quotaRun.account == nil {
                choice(
                    symbol: "person.crop.circle",
                    title: L10n.t("Another iCloud account", "不是同一个 iCloud 账号"),
                    detail: L10n.t(
                        "Sign in to the Quota Run account your Mac uses, then allow this phone on the Mac. End-to-end encrypted.",
                        "登录 Mac 所用的 Quota Run 账号，再在 Mac 上允许这台手机。端到端加密。"))
                SignInButton(model: model, prominent: true)
            } else {
                choice(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: L10n.t("Signed in to Quota Run", "已登录 Quota Run"),
                    detail: L10n.t(
                        "Waiting for your Mac. On the Mac, sign in to the same Quota Run account and allow this phone in Settings › iPhone.",
                        "正在等待 Mac。请在 Mac 上登录同一个 Quota Run 账号，并在 设置 › iPhone 里允许这台手机。"))
            }
            HStack(spacing: 16) {
                Button(L10n.t("See an example", "查看示例")) {
                    withAnimation(.snappy) { model.showDemo() }
                }
                Link(L10n.t("Get QuotaBar for Mac", "获取 Mac 版 QuotaBar"), destination: URL(string: "https://quota.bar")!)
            }
            // In a list row, buttons without their own hit area all answer a
            // tap anywhere in the row.
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func choice(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Said while the samples are on, with the way back.
private struct DemoBanner: View {
    let exit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Example readings", "示例数据"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.t(
                    "Not your quotas. Connect a Mac to see your own.",
                    "这些不是你的额度。连接 Mac 后显示你自己的。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.t("Exit", "退出示例"), action: exit)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HowItWorks: View {
    let model: ReadingsModel
    @Environment(\.dismiss) private var dismiss

    /// "1.0.0 (3)": the version, and the build that tells two uploads of it apart.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.t(
                        "Your Mac reads each service with the sign-ins already on it, and sends the results — plans, figures, reset times, balances — end-to-end encrypted, to your private iCloud or through your Quota Run account. This phone only reads them. Sign-ins, tokens and keys never leave the Mac.",
                        "Mac 用它本机已有的登录信息读取各服务的额度，再把结果（套餐、用量、重置时间、余额）端到端加密后，存到你的私有 iCloud 或经你的 Quota Run 账号转交。这台手机只负责读取。登录信息、token 和 Key 不会离开 Mac。"))
                }
                QuotaRunSection(model: model)
                if !model.readings.devices.isEmpty {
                    Section(L10n.t("Macs sending readings", "已同步的 Mac")) {
                        ForEach(model.readings.devices) { device in
                            DeviceRow(device: device)
                        }
                    }
                }
                Section {
                    Button(L10n.t("Back to the Mac's order", "恢复为 Mac 上的顺序")) {
                        model.resetOrder()
                        dismiss()
                    }
                    .disabled(CardOrder.saved.isEmpty)
                } header: {
                    Text(L10n.t("Card order", "卡片顺序"))
                } footer: {
                    Text(L10n.t(
                        "Press and hold a card, then drag it. The order is kept on this phone and the Overview widget follows it; the Mac keeps its own.",
                        "长按卡片后拖动即可调整顺序。顺序只保存在这台手机上，「总览」小组件也会按这个顺序显示；Mac 上的顺序不受影响。"))
                }
                Section {
                    Text(L10n.t(
                        "The Mac sends after a refresh that changed something, and every 20 minutes otherwise. The phone picks that up within minutes, not instantly — iOS decides when apps and widgets may update. While the Mac is asleep nothing new arrives, and the app says so.",
                        "Mac 在数字有变化的刷新之后同步，没有变化时每 20 分钟同步一次。手机通常在几分钟内收到，不是实时的，因为 App 和小组件什么时候更新由 iOS 决定。Mac 睡眠时不会有新数据，App 会明确提示。"))
                } header: {
                    Text(L10n.t("When figures arrive", "数据什么时候更新"))
                } footer: {
                    // Which build this is, for a report or a check that an
                    // update landed.
                    Text("QuotaBar iOS \(Self.version)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle(L10n.t("How it works", "工作原理"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(
                get: { model.quotaRun.showsPage },
                set: { model.quotaRun.showsPage = $0 }))
            {
                if case let .waiting(url) = model.quotaRun.phase { ApprovalPage(url: url).ignoresSafeArea() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done", "完成")) { dismiss() }
                }
            }
        }
    }
}

/// One Mac: its icon by model, the name its owner gave it, what it is, and
/// when it last sent — amber once it has gone quiet.
private struct DeviceRow: View {
    let device: MergedReadings.Device

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let quiet = device.freshness(now: context.date) != .current
            HStack(spacing: 12) {
                Image(systemName: device.kind.symbolName)
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name.isEmpty ? "Mac" : device.name)
                        .font(.subheadline.weight(.medium))
                    Text([device.model, device.appVersion.isEmpty ? nil : "QuotaBar \(device.appVersion)"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(L10n.t(
                    "\(QuotaFormat.age(of: device.updatedAt, now: context.date))",
                    "\(QuotaFormat.age(of: device.updatedAt, now: context.date))同步"))
                    .font(.caption)
                    .foregroundStyle(quiet ? Color.orange : Color.secondary)
            }
        }
    }
}

