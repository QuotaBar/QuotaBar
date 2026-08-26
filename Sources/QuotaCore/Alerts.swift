import Foundation

// MARK: - Threshold alerts

public enum AlertLevel: Int, Comparable, Sendable, Codable {
    case none = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Brand-consistent hex tints used to color the menu-bar icon.
    public var hex: String? {
        switch self {
        case .none: nil
        case .warning: "FF9F0A"
        case .critical: "FF375F"
        }
    }

    public var displayName: String {
        switch self {
        case .none: L10n.t("Normal", "正常")
        case .warning: L10n.t("Warning", "警告")
        case .critical: L10n.t("Critical", "紧急")
        }
    }
}

public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var warning: Int
    public var critical: Int

    public init(enabled: Bool = true, warning: Int = 80, critical: Int = 95) {
        self.enabled = enabled
        self.warning = warning
        self.critical = critical
    }

    /// Clamps both thresholds to 1...100 and keeps `critical` at or above
    /// `warning` — otherwise the warning band swallows the critical one and the
    /// critical notification can never fire.
    public func normalized() -> AlertSettings {
        var copy = self
        copy.warning = min(max(warning, 1), 100)
        copy.critical = min(max(critical, copy.warning), 100)
        return copy
    }

    public func level(for percent: Double) -> AlertLevel {
        guard enabled else { return .none }
        let bounds = normalized()
        if percent >= Double(bounds.critical) { return .critical }
        if percent >= Double(bounds.warning) { return .warning }
        return .none
    }
}
