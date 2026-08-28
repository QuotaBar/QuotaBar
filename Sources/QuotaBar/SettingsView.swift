import SwiftUI
import ServiceManagement
import QuotaCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TabView {
            providersTab
                .tabItem { Label(L10n.t("Providers", "服务商"), systemImage: "square.grid.2x2") }
            generalTab
                .tabItem { Label(L10n.t("General", "通用"), systemImage: "gearshape") }
        }
        .frame(width: 560, height: 620)
        .tint(Design.accent)
    }

    // MARK: Providers

    private var providersTab: some View {
        ScrollView {
            VStack(spacing: Design.space2 + 2) {
                if let error = store.credentialError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .quotaCard()
                }
                ForEach(ProviderID.allCases) { id in
                    ProviderSettingsRow(store: store, id: id)
                }
            }
            .padding(Design.space4 - 2)
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section(L10n.t("Refresh", "刷新")) {
                Picker(L10n.t("Interval", "间隔"), selection: Binding(
                    get: { store.refreshMinutes },
                    set: { store.setRefreshMinutes($0) }))
                {
                    ForEach([1, 2, 5, 15, 30], id: \.self) { minutes in
                        Text(L10n.t("\(minutes) minutes", "\(minutes) 分钟")).tag(minutes)
                    }
                }
                Button(L10n.t("Refresh now", "立即刷新")) { store.refreshAll() }
            }

            Section(L10n.t("Appearance", "外观")) {
                Picker(L10n.t("Language", "语言"), selection: Binding(
                    get: { store.language },
                    set: { store.setLanguage($0) }))
                {
                    ForEach(L10n.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                // A segmented control cannot hold nine options, and a style is
                // easier to pick from its own glyph than from its name.
                VStack(alignment: .leading, spacing: Design.space2) {
                    Text(L10n.t("Icon style", "图标样式"))
                    MenuBarStylePicker(
                        selection: store.menuBarStyle,
                        mode: store.meterMode,
                        onSelect: { store.setMenuBarStyle($0) })
                }
                Picker(L10n.t("Meter fills with", "仪表填充"), selection: Binding(
                    get: { store.meterMode },
                    set: { store.setMeterMode($0) }))
                {
                    ForEach(MeterMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.t(
                    "Affects the menu-bar glyph only. Percentages inside the panel always show how much has been used.",
                    "只影响菜单栏图标。面板内的百分比始终表示已用量。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t(
                    "The glyph reports whichever provider the panel is focused on. Pick Overview in the panel to have it cover everything enabled.",
                    "菜单栏图标显示的是面板中当前选中的服务商。在面板里选「总览」可让它覆盖所有已启用的服务商。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.t("Presentation", "展示方式"), selection: Binding(
                    get: { store.presentation },
                    set: { store.setPresentation($0) }))
                {
                    ForEach(Presentation.allCases) { presentation in
                        Text(presentation.displayName).tag(presentation)
                    }
                }
                .pickerStyle(.segmented)

                if store.presentation == .edgeDock {
                    Picker(L10n.t("Dock edge", "停靠边缘"), selection: Binding(
                        get: { store.dockEdge },
                        set: { store.setDockEdge($0) }))
                    {
                        ForEach(DockEdge.allCases) { edge in
                            Text(edge.displayName).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(L10n.t("Keep the dock visible", "常驻显示（不自动隐藏）"), isOn: Binding(
                        get: { store.dockAlwaysVisible },
                        set: { store.setDockAlwaysVisible($0) }))
                    Text(L10n.t(
                        "Drag the dock up or down to move it; the position is remembered. Click a ring to open the panel for that provider.",
                        "上下拖动可移动停靠条，位置会被记住。点击圆环可打开该服务商的完整面板。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.t("Desktop widget", "桌面小工具")) {
                Toggle(L10n.t("Show on the desktop", "在桌面显示"), isOn: Binding(
                    get: { store.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }))
                Picker(L10n.t("Density", "信息密度"), selection: Binding(
                    get: { store.widgetDensity },
                    set: { store.setWidgetDensity($0) }))
                {
                    ForEach(WidgetDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!store.widgetEnabled)
                Toggle(L10n.t("Keep above other windows", "置于其他窗口之上"), isOn: Binding(
                    get: { store.widgetAlwaysOnTop },
                    set: { store.setWidgetAlwaysOnTop($0) }))
                    .disabled(!store.widgetEnabled)
                Text(L10n.t(
                    "Sits on the desktop, below your windows, unless kept above. Drag it to move; the position is remembered.",
                    "默认位于桌面、在窗口之下（可改为置顶）。拖动即可移动，位置会被记住。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Alerts", "提醒")) {
                Toggle(L10n.t("Notify when approaching limits", "接近额度上限时通知"), isOn: Binding(
                    get: { store.alertSettings.enabled },
                    set: { value in
                        var settings = store.alertSettings
                        settings.enabled = value
                        store.setAlertSettings(settings)
                    }))
                Picker(L10n.t("Warning at", "警告阈值"), selection: Binding(
                    get: { store.alertSettings.warning },
                    set: { value in
                        var settings = store.alertSettings
                        settings.warning = value
                        store.setAlertSettings(settings)
                    }))
                {
                    ForEach([60, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!store.alertSettings.enabled)
                Picker(L10n.t("Critical at", "紧急阈值"), selection: Binding(
                    get: { store.alertSettings.critical },
                    set: { value in
                        var settings = store.alertSettings
                        settings.critical = value
                        store.setAlertSettings(settings)
                    }))
                {
                    // Only offer thresholds at or above the warning level —
                    // a critical below it can never be reached.
                    ForEach([80, 85, 90, 95, 99].filter { $0 >= store.alertSettings.warning },
                            id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!store.alertSettings.enabled)
            }

            Section(L10n.t("System", "系统")) {
                LaunchAtLoginToggle()
                HStack {
                    Text(L10n.t("Trend history", "趋势历史"))
                    Spacer()
                    Button(L10n.t("Reset", "重置"), role: .destructive) { store.resetHistory() }
                        .controlSize(.small)
                }
                .help(L10n.t(
                    "Clears the recorded readings behind the sparklines.",
                    "清除趋势折线所依赖的历史读数。"))
            }

            Section(L10n.t("Updates", "更新")) {
                UpdateSettings(store: store)
            }

            Section(L10n.t("About", "关于")) {
                HStack(spacing: Design.space3) {
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let image = NSImage(contentsOf: url)
                    {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QuotaBar \(Self.version)")
                            .font(.headline)
                        Text(L10n.t(
                            "Every AI coding limit, in your menu bar.",
                            "把每个 AI 编码服务的额度都放进菜单栏。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.t(
                    "Automatic providers reuse the session your CLI already created. Manually entered tokens are stored in the macOS keychain — never in a file.",
                    "自动型服务商复用 CLI 已有的登录会话；手动填写的凭据保存在 macOS 钥匙串中，不写入任何文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t(
                    "Spend figures are estimates computed locally from the CLIs' session logs at published list prices. They are not a bill.",
                    "费用为本地会话日志按官方标价估算的结果，仅供参考，不等于实际账单。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @ObservedObject var store: UsageStore
    @State private var feed: String = ""
    @State private var invalid = false

    var body: some View {
        Toggle(L10n.t("Check for updates", "检查更新"), isOn: Binding(
            get: { store.checksForUpdates },
            set: { store.setChecksForUpdates($0) }))

        VStack(alignment: .leading, spacing: Design.space1) {
            TextField(L10n.t("Update source", "更新源"), text: $feed)
                .textFieldStyle(.roundedBorder)
                .disabled(!store.checksForUpdates)
                .onSubmit(save)
            Text(L10n.t(
                "A GitHub repository as owner/repo, or the URL of a JSON endpoint you host: {\"version\":\"0.3.0\",\"url\":\"…/QuotaBar-0.3.0.zip\"}",
                "填 GitHub 仓库（owner/repo），或你自建的 JSON 接口地址：{\"version\":\"0.3.0\",\"url\":\"…/QuotaBar-0.3.0.zip\"}"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if invalid {
                Text(L10n.t("Not a valid source — reverted.", "不是有效的更新源，已还原。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(L10n.t(
                "Downloads are installed only if signed by this app's developer and notarized by Apple.",
                "只有经本应用开发者签名并通过 Apple 公证的下载才会被安装。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button(L10n.t("Check now", "立即检查")) { store.checkForUpdate() }
                .controlSize(.small)
                .disabled(!store.checksForUpdates)
            Spacer()
            if store.updateIsManagedByHomebrew {
                Text(L10n.t("Installed via Homebrew", "通过 Homebrew 安装"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { feed = store.updateFeedValue }
    }

    private func save() {
        if store.setUpdateFeed(feed) {
            invalid = false
        } else {
            invalid = true
            feed = store.updateFeedValue
        }
    }
}

// MARK: - Icon style picker

/// Shows each style as its own glyph at a mid level, so the choice is made on
/// what it will actually look like in the menu bar.
struct MenuBarStylePicker: View {
    let selection: MenuBarStyle
    let mode: MeterMode
    let onSelect: (MenuBarStyle) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Design.space2), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Design.space2) {
            ForEach(MenuBarStyle.allCases) { style in
                Button {
                    onSelect(style)
                } label: {
                    VStack(spacing: Design.space1) {
                        // 34% used, so a stepped glyph shows a partial reading
                        // rather than an all-or-nothing one.
                        Image(nsImage: MenuBarIcon.render(percent: 34, style: style, mode: mode))
                            .frame(height: 22)
                        Text(style.displayName)
                            .font(.caption2)
                            .lineLimit(1)
                        Text(style.steps.map { L10n.t("\($0) steps", "\($0) 格") }
                            ?? L10n.t("continuous", "连续"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.space2)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                            .fill(style == selection ? Design.accent : Design.surfaceStrong))
                    .foregroundStyle(style == selection ? Design.ink : Color.primary)
                }
                .buttonStyle(TileButtonStyle())
                .help(style.displayName)
            }
        }
    }
}

// MARK: - Launch at login

struct LaunchAtLoginToggle: View {
    @State private var enabled = false
    @State private var available = true

    var body: some View {
        Toggle(L10n.t("Launch at login", "开机自动启动"), isOn: $enabled)
            .disabled(!available)
            .onAppear {
                // Only meaningful for a real app bundle; the dev loop runs a
                // bare binary that SMAppService cannot register.
                available = Bundle.main.bundleIdentifier != nil
                enabled = available && SMAppService.mainApp.status == .enabled
            }
            .onChange(of: enabled) { _, on in
                guard available else { return }
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}

// MARK: - Provider row

struct ProviderSettingsRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    @State private var credential: String = ""
    @State private var savedCredential: String = ""
    @State private var reveal = false
    @State private var testPhase: TestPhase = .idle

    enum TestPhase {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    private var provider: any QuotaProvider { ProviderRegistry.make(id) }
    /// Read from the store's cached set — `isConfigured` can block on the
    /// keychain, which must never happen inside a `body`.
    private var configured: Bool { store.isConfigured(id) }
    private var isManual: Bool { id.credentialHint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            header
            if store.isEnabled(id) {
                Divider()
                statusLine
                if let hint = id.credentialHint {
                    credentialEditor
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(id.setupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                testResult
            }
        }
        .quotaCard()
        .onAppear(perform: loadCredential)
    }

    private func loadCredential() {
        // Cached in ConfigStore after the first read, so this does not hit the
        // keychain on every appearance.
        savedCredential = ConfigStore.shared.credential(for: id) ?? ""
        credential = savedCredential
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Design.space2 + 2) {
            ProviderGlyph(id: id, size: 18)
            Text(id.displayName)
                .font(.headline)
            statusDot
            Spacer()
            Toggle("", isOn: Binding(
                get: { store.isEnabled(id) },
                set: { store.setEnabled(id, $0) }))
                .labelsHidden()
                .help(L10n.t("Show in the menu", "在菜单中显示"))
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(configured ? Design.accent : Color.secondary.opacity(0.4))
            .frame(width: 7, height: 7)
            .help(configured ? L10n.t("Ready", "已就绪") : L10n.t("Not configured", "未配置"))
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        if configured {
            Label(
                isManual
                    ? L10n.t("Credential saved to the keychain", "凭据已保存到钥匙串")
                    : L10n.t("Session detected automatically", "已自动检测到登录会话"),
                systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                isManual
                    ? L10n.t("No credential yet", "尚未填写凭据")
                    : L10n.t("No local session found", "未找到本地登录会话"),
                systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Credential editor

    private var credentialEditor: some View {
        HStack(spacing: Design.space1 + 2) {
            Group {
                if reveal {
                    TextField(L10n.t("Token / cookie / API key", "Token / Cookie / API Key"), text: $credential)
                } else {
                    SecureField(L10n.t("Token / cookie / API key", "Token / Cookie / API Key"), text: $credential)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(reveal ? L10n.t("Hide", "隐藏") : L10n.t("Reveal", "显示"))
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: Design.space2) {
            if isManual {
                Button(L10n.t("Save", "保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(credential == savedCredential)
                if !savedCredential.isEmpty {
                    Button(L10n.t("Clear", "清除"), role: .destructive, action: clear)
                        .controlSize(.small)
                }
            }
            Button {
                test()
            } label: {
                if case .running = testPhase {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.t("Test connection", "测试连接"))
                }
            }
            .controlSize(.small)
            .disabled({ if case .running = testPhase { return true }; return false }())
            Spacer()
            if let url = id.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.t("Open console", "打开控制台"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(url.absoluteString)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testPhase {
        case .idle, .running:
            EmptyView()
        case let .ok(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Intents

    private func save() {
        store.setCredential(credential, for: id)
        loadCredential()
        testPhase = .idle
    }

    private func clear() {
        store.setCredential("", for: id)
        loadCredential()
        testPhase = .idle
    }

    private func test() {
        testPhase = .running
        Task {
            do {
                let snapshot = try await provider.fetch(config: ConfigStore.shared)
                let connected = L10n.t("Connected", "连接成功")
                if let percent = snapshot.headlinePercent {
                    testPhase = .ok(
                        "\(connected) — \(QuotaFormat.percent(percent))"
                            + (snapshot.planName.map { " · \($0)" } ?? ""))
                } else if let first = snapshot.windows.first {
                    testPhase = .ok("\(connected) — \(first.detail ?? first.title)")
                } else {
                    testPhase = .ok(connected)
                }
            } catch {
                testPhase = .failed(error.localizedDescription)
            }
        }
    }
}
