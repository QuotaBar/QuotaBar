import Foundation

// MARK: - Editions

/// Kimi Code runs as two services with separate accounts: the China edition
/// on kimi.com and the global one on kimi.ai. A token, key or cookie belongs
/// to one of them.
public enum KimiEdition: String, Sendable, CaseIterable, Codable {
    case china
    case global

    /// Kimi Code's `mainland-cn` and `global` region profiles.
    public var apiBase: URL {
        switch self {
        case .china: URL(string: "https://api.kimi.com/coding/v1")!
        case .global: URL(string: "https://api.kimi.ai/coding/v1")!
        }
    }

    public var oauthHost: String {
        switch self {
        case .china: "https://auth.kimi.com"
        case .global: "https://auth.kimi.ai"
        }
    }

    public var site: String {
        switch self {
        case .china: "kimi.com"
        case .global: "kimi.ai"
        }
    }

    public var usagesURL: URL { apiBase.appendingPathComponent("usages") }

    /// Where the plan and API keys are managed; Kimi Code's own help menu
    /// links here.
    public var consoleURL: URL { URL(string: "https://www.\(site)/code/console")! }

    /// For the plan chip.
    public var label: String {
        switch self {
        case .china: L10n.t("China", "国内版")
        case .global: L10n.t("Global", "国际版")
        }
    }

    /// For Settings, with the site that tells the two apart.
    public var longLabel: String {
        L10n.t("\(label) (\(site))", "\(label)（\(site)）")
    }

    /// Named after the Code API host, which is where the account lives.
    public static func forAPIHost(_ host: String?) -> KimiEdition {
        host == "api.kimi.ai" ? .global : .china
    }
}

/// Where a Kimi reading came from, as `UsageSnapshot.source` keeps it: a
/// stable id, worded only when shown.
public enum KimiSource: String, Sendable, CaseIterable {
    /// The Kimi Code app or CLI's sign-in on this Mac.
    case signIn
    /// The older Python CLI's sign-in in `~/.kimi`.
    case legacySignIn
    case apiKey
    case cookie
    /// Kimi Desktop, the chat app, read from its own cookie store.
    case desktop

    public var label: String {
        switch self {
        case .signIn: L10n.t("Kimi Code sign-in", "Kimi Code 本机登录")
        case .legacySignIn: L10n.t("Older Kimi CLI sign-in", "旧版 Kimi CLI 登录")
        case .apiKey: L10n.t("API key", "API Key")
        case .cookie: L10n.t("kimi-auth cookie", "kimi-auth Cookie")
        case .desktop: L10n.t("Kimi Desktop sign-in", "Kimi 桌面版登录")
        }
    }
}
