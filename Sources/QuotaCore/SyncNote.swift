import Foundation

/// What a refresh of everything came to, said in the sync note for a moment
/// after the spinner stops. A click on refresh then always ends in a word,
/// even when every read came straight back with the answer it had before.
public enum RefreshOutcome: Equatable, Sendable {
    case allUpToDate
    /// This many enabled providers still did not update.
    case notUpdating(Int)

    public init(failing: Int) {
        self = failing > 0 ? .notUpdating(failing) : .allUpToDate
    }

    /// The spinner stays up at least this long. A read answered from a memo,
    /// or one that fails before it leaves the Mac, is back in milliseconds,
    /// and a spinner that shows for a frame reads as a click that did nothing.
    public static let minimumSpin: TimeInterval = 0.8
    /// How long the outcome stays in the note before the note goes back to
    /// what it says the rest of the time.
    public static let holdSeconds: TimeInterval = 2

    /// How much longer the spinner stays, `elapsed` seconds after the click.
    public static func remainingSpin(elapsed: TimeInterval) -> TimeInterval {
        max(0, minimumSpin - max(0, elapsed))
    }
}

/// The island footer's sync note: the most pressing of what it could say.
public enum SyncNote: Equatable, Sendable {
    case refreshing
    /// A refresh of everything just finished; shown for `holdSeconds`.
    case finished(RefreshOutcome)
    /// This many enabled providers' last refresh failed.
    case notUpdating(Int)
    /// Everything is reading, the newest reading from this moment.
    case synced(Date)
    /// Nothing has been read yet.
    case syncing

    /// A refresh under way first, then its outcome while it is held, then
    /// providers that are failing, then how old the newest reading is.
    public static func make(refreshing: Bool, outcome: RefreshOutcome?, failing: Int, latest: Date?) -> SyncNote {
        if refreshing { return .refreshing }
        if let outcome { return .finished(outcome) }
        if failing > 0 { return .notUpdating(failing) }
        guard let latest else { return .syncing }
        return .synced(latest)
    }

    public func text(now: Date = .now) -> String {
        switch self {
        case .refreshing:
            return L10n.t("Refreshing…", "正在刷新…")
        case .finished(.allUpToDate):
            return L10n.t("All up to date", "已全部更新")
        case let .finished(.notUpdating(count)):
            return L10n.t("Refreshed · \(count) not updating", "已刷新 · \(count) 个未能更新")
        case let .notUpdating(count):
            return L10n.t("\(count) not updating", "\(count) 个未能更新")
        case let .synced(date):
            return L10n.t("Synced \(QuotaFormat.age(of: date, now: now))", "已同步 \(QuotaFormat.age(of: date, now: now))")
        case .syncing:
            return L10n.t("Syncing…", "同步中…")
        }
    }

    /// Amber rather than green: something is not updating.
    public var isWarning: Bool {
        switch self {
        case .finished(.notUpdating), .notUpdating: true
        case .refreshing, .finished(.allUpToDate), .synced, .syncing: false
        }
    }
}

/// A reading still on show after the refresh that should have replaced it
/// failed. Said where the provider's service status sits, so an old figure
/// is never taken for a current one.
public enum StaleReading {
    /// The badge beside the provider's name.
    public static var label: String { L10n.t("Not updating", "未能更新") }

    /// "Showing numbers from 3h ago", over the windows; the badge beside the
    /// name has already said they are not updating.
    public static func note(fetchedAt: Date, now: Date = .now) -> String {
        let age = QuotaFormat.age(of: fetchedAt, now: now)
        return L10n.t("Showing numbers from \(age)", "显示的是 \(age)的数据")
    }

    /// The badge's tooltip: why, then how old the numbers are.
    public static func help(reason: String, fetchedAt: Date, now: Date = .now) -> String {
        let age = QuotaFormat.age(of: fetchedAt, now: now)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let numbers = L10n.t("The numbers shown are from \(age).", "显示的是 \(age)的数据。")
        return trimmed.isEmpty ? numbers : "\(trimmed)\n\(numbers)"
    }

    /// A window whose reset time has passed while the reading is stale: its
    /// figure is the window that ended, not the one running now. Nothing is
    /// assumed about the new one — no reading says what it holds.
    public static func resetLapsed(_ resetsAt: Date?, now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}
