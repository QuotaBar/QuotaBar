import Foundation

// MARK: - Presentation

public enum Presentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case menuBar
    case island

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .menuBar: L10n.t("Menu bar", "菜单栏")
        case .island: L10n.t("Notch island", "刘海岛")
        }
    }
}

// MARK: - Menu bar icon styles

public enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar
    case ring
    case columns
    case percent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bar: L10n.t("Bar", "横向")
        case .ring: L10n.t("Ring", "圆形")
        case .columns: L10n.t("Columns", "柱形")
        case .percent: L10n.t("Percent", "数字")
        }
    }
}

// MARK: - What the meter fills with

/// Whether the menu-bar meter fills with what is left or what is spent.
///
/// Defaults to `.remaining`: an almost-empty bar reads as "nothing left" to
/// anyone who has ever looked at a battery or a signal indicator, which is the
/// opposite of what a low *usage* figure means.
public enum MeterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remaining: L10n.t("Remaining", "剩余")
        case .used: L10n.t("Used", "已用")
        }
    }

    /// Converts a used-percentage into the value the icon should show.
    public func shownPercent(fromUsed used: Double) -> Double {
        let clamped = min(max(used, 0), 100)
        return self == .remaining ? 100 - clamped : clamped
    }
}

// MARK: - Brand theme

public enum QuotaTheme {
    /// Lime green sampled from the brand reference design.
    public static let accentHex = "69EA28"
    /// Near-black ink used on top of the accent.
    public static let inkHex = "101010"
}

// MARK: - Provider identity

public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case cursor
    case kimi
    case zai
    case opencodeGo = "opencode-go"
    case minimax
    case gemini
    case manus
    case deepseek
    case grok

    public var id: String { rawValue }

    /// Brand names stay untranslated in both languages.
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .kimi: "Kimi Code"
        case .zai: "z.ai"
        case .opencodeGo: "OpenCode Go"
        case .minimax: "MiniMax"
        case .gemini: "Gemini"
        case .manus: "Manus"
        case .deepseek: "DeepSeek"
        case .grok: "Grok"
        }
    }

    /// SF Symbol placeholder used as the provider glyph in the menu grid.
    public var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .kimi: "textformat"
        case .zai: "z.square"
        case .opencodeGo: "braces"
        case .minimax: "square.stack.3d.up"
        case .gemini: "star"
        case .manus: "hand.raised"
        case .deepseek: "magnifyingglass"
        case .grok: "bolt"
        }
    }

    /// Hex accent color used for progress bars / underlines (CodexBar-style per-provider tint).
    public var accentHex: String {
        switch self {
        case .codex: "0A84FF"
        case .claude: "D97757"
        case .cursor: "30B6A5"
        case .kimi: "FF7A45"
        case .zai: "8E8EF7"
        case .opencodeGo: "5B8DEF"
        case .minimax: "E5484D"
        case .gemini: "4285F4"
        case .manus: "B08968"
        case .deepseek: "4D9F7B"
        case .grok: "22C55E"
        }
    }

    /// Web console where the user can manage the account / grab credentials.
    public var dashboardURL: URL? {
        switch self {
        case .codex: URL(string: "https://chatgpt.com/codex")
        case .claude: URL(string: "https://claude.ai")
        case .cursor: URL(string: "https://cursor.com/dashboard")
        case .kimi: URL(string: "https://www.kimi.com/code/console")
        case .zai: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")
        case .opencodeGo: URL(string: "https://opencode.ai")
        case .minimax: URL(string: "https://platform.minimax.io/user-center/payment/coding-plan")
        case .gemini: URL(string: "https://gemini.google.com")
        case .manus: URL(string: "https://manus.im")
        case .deepseek: URL(string: "https://platform.deepseek.com/usage")
        case .grok: URL(string: "https://grok.com")
        }
    }

    /// nil = credentials are discovered locally (CLI login files / Keychain).
    public var credentialHint: String? {
        switch self {
        case .codex, .claude, .gemini:
            return nil
        case .grok:
            return L10n.t(
                "Optional override; otherwise read from ~/.grok/auth.json (grok CLI login).",
                "可选覆盖；留空则读取 ~/.grok/auth.json（grok CLI 登录后生成）。")
        case .cursor:
            return L10n.t(
                "WorkosCursorSessionToken cookie value (DevTools → Application → Cookies → cursor.com).",
                "WorkosCursorSessionToken cookie 值（开发者工具 → 应用 → Cookie → cursor.com）。")
        case .kimi:
            return L10n.t(
                "kimi-auth cookie JWT (DevTools → Application → Cookies → kimi.com).",
                "kimi-auth cookie 的 JWT（开发者工具 → 应用 → Cookie → kimi.com）。")
        case .zai:
            return L10n.t("API key (z.ai → API Keys).", "API Key（z.ai → API Keys）。")
        case .opencodeGo:
            return L10n.t(
                "Session token or full Cookie header from opencode.ai.",
                "opencode.ai 的会话 token 或完整 Cookie 头。")
        case .minimax:
            return L10n.t(
                "API token or full Cookie header from platform.minimax.io.",
                "platform.minimax.io 的 API token 或完整 Cookie 头。")
        case .manus:
            return L10n.t("Session token (Bearer) from manus.im.", "manus.im 的会话 token（Bearer）。")
        case .deepseek:
            return L10n.t(
                "API key (platform.deepseek.com → API Keys).",
                "API Key（platform.deepseek.com → API Keys）。")
        }
    }

    /// How to make an automatic provider discover its session.
    public var setupHint: String {
        switch self {
        case .codex: return L10n.t("Sign in with the Codex CLI (`codex`) first.", "请先用 Codex CLI（`codex`）登录。")
        case .claude: return L10n.t(
            "Run `claude` once and sign in to create the OAuth session.",
            "运行一次 `claude` 并登录以生成 OAuth 会话。")
        case .gemini: return L10n.t("Sign in with the Gemini CLI (`gemini`) first.", "请先用 Gemini CLI（`gemini`）登录。")
        case .grok: return L10n.t(
            "Sign in with the grok CLI or paste a token in Settings.",
            "用 grok CLI 登录，或在设置中粘贴 token。")
        default: return credentialHint ?? ""
        }
    }
}

// MARK: - Window titles

/// Turns a provider-reported window length into a human title, so a rolling
/// window is never mislabeled by a hardcoded guess.
public enum WindowTitle {
    public static func forSeconds(_ seconds: Int) -> String {
        guard seconds > 0 else { return L10n.t("Quota", "额度") }
        switch seconds {
        case 604_800:
            return L10n.t("Weekly window", "周窗口")
        case 86_400:
            return L10n.t("Daily window", "日窗口")
        case 2_592_000, 2_678_400, 2_628_000:
            return L10n.t("Monthly window", "月窗口")
        default:
            break
        }
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return L10n.t("\(days)-day window", "\(days) 天窗口")
        }
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return L10n.t("\(hours)-hour window", "\(hours) 小时窗口")
        }
        let minutes = max(1, seconds / 60)
        return L10n.t("\(minutes)-minute window", "\(minutes) 分钟窗口")
    }

    public static func forMinutes(_ minutes: Int) -> String {
        forSeconds(minutes * 60)
    }
}

// MARK: - Usage models

public struct UsageWindow: Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 0...100, nil when the provider only reports absolute values.
    public var usedPercent: Double?
    /// Human-readable absolute numbers, e.g. "$12.30 / $20.00" or "820 / 1000 credits".
    public var detail: String?
    public var resetsAt: Date?
    /// True for the window the provider says is currently governing requests.
    public var isActive: Bool

    public init(
        title: String,
        usedPercent: Double? = nil,
        detail: String? = nil,
        resetsAt: Date? = nil,
        isActive: Bool = false)
    {
        self.id = title
        self.title = title
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.detail = detail
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

public struct UsageSnapshot: Sendable {
    public var planName: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(
        planName: String? = nil,
        account: String? = nil,
        windows: [UsageWindow] = [],
        fetchedAt: Date = .now)
    {
        self.planName = planName
        self.account = account
        self.windows = UsageSnapshot.uniquingIDs(windows)
        self.fetchedAt = fetchedAt
    }

    /// `ForEach` needs stable unique ids; two providers legitimately report two
    /// windows with the same title (e.g. per-model weekly limits).
    private static func uniquingIDs(_ windows: [UsageWindow]) -> [UsageWindow] {
        var seen: [String: Int] = [:]
        return windows.map { window in
            var copy = window
            let count = (seen[window.title] ?? 0) + 1
            seen[window.title] = count
            if count > 1 { copy.id = "\(window.title)#\(count)" }
            return copy
        }
    }

    /// Highest used percent across windows — drives the menu-bar meter and grid underline.
    public var headlinePercent: Double? {
        windows.compactMap(\.usedPercent).max()
    }
}

// MARK: - Errors

public enum ProviderError: LocalizedError, Sendable {
    case notConfigured(hint: String)
    case unauthorized
    case rateLimited
    case http(Int)
    case badResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(hint):
            return L10n.t("Not configured. \(hint)", "尚未配置。\(hint)")
        case .unauthorized:
            return L10n.t(
                "Session expired — sign in again with the provider CLI or update the credential in Settings.",
                "会话已过期 —— 请重新用服务商 CLI 登录，或在设置中更新凭据。")
        case .rateLimited:
            return L10n.t(
                "Rate limited by the provider. Try again in a few minutes.",
                "被服务商限流，请几分钟后重试。")
        case let .http(code):
            return L10n.t("Provider returned HTTP \(code).", "服务商返回 HTTP \(code)。")
        case .badResponse:
            return L10n.t("Provider response could not be parsed.", "无法解析服务商返回的数据。")
        case let .network(message):
            return L10n.t("Network error: \(message)", "网络错误：\(message)")
        }
    }

    /// Distinguishes "you need to set this up" from "something went wrong",
    /// so the UI can offer the right next step.
    public var isSetupProblem: Bool {
        switch self {
        case .notConfigured, .unauthorized: return true
        default: return false
        }
    }
}

// MARK: - Provider protocol

public protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    /// Whether the required credentials can be resolved right now.
    func isConfigured(config: ConfigStore) -> Bool
    func fetch(config: ConfigStore) async throws -> UsageSnapshot
}

// MARK: - Formatting helpers

public enum QuotaFormat {
    /// "2h 14m", "3d 2h", "45m", "20s"
    public static func countdown(to date: Date, from now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return L10n.t("now", "已重置") }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return L10n.t("\(days)d \(hours)h", "\(days) 天 \(hours) 小时") }
        if hours > 0 { return L10n.t("\(hours)h \(minutes)m", "\(hours) 小时 \(minutes) 分") }
        if minutes > 0 { return L10n.t("\(minutes)m", "\(minutes) 分钟") }
        return L10n.t("\(total)s", "\(total) 秒")
    }

    /// "3 minutes ago" — how old a snapshot is.
    public static func age(of date: Date, now: Date = .now) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return L10n.t("just now", "刚刚") }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.t("\(minutes)m ago", "\(minutes) 分钟前") }
        let hours = minutes / 60
        if hours < 24 { return L10n.t("\(hours)h ago", "\(hours) 小时前") }
        return L10n.t("\(hours / 24)d ago", "\(hours / 24) 天前")
    }

    public static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rounded))%"
            : String(format: "%.1f%%", rounded)
    }

    public static func dollars(cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
    }

    public static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// 1_234_567 → "1.2M"
    public static func compact(_ count: Int) -> String {
        switch Double(count) {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}
