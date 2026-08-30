// MARK: - Threshold alerts

public enum AlertLevel: Int, Comparable, Sendable, Codable {
    case none = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Tints for the menu-bar glyph. Deeper than the system alert colours on
    /// purpose: a 22pt glyph is mostly antialiased edges, and a light red
    /// washes out to pink against the menu bar.
    public var hex: String? {
        switch self {
        case .none: nil
        case .warning: "D97706"
        case .critical: "DC2626"
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

/// The colour a usage figure is drawn in, everywhere it appears.
///
/// One function because this mapping was copied into seven views plus a
/// divergent eighth in the snapshot renderer, which had `80` and `95` written
/// into it while the real thing reads the user's own thresholds — so the
/// snapshots could disagree with the app.
///
/// Keyed off **used** percent, never the displayed figure. The dock handle fills
/// with whatever `MeterMode` says, so in remaining mode a long bar means plenty
/// left; the colour still has to come from usage or a nearly-empty quota would
/// be drawn full and green.
public enum UsageTint {
    public static func hex(used: Double, alerts: AlertSettings) -> String {
        alerts.level(for: used).hex ?? "34C759"
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
