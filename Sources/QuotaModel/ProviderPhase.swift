import Foundation

/// Presentation of a provider's last read. A confirmed move to another
/// card replaces old numbers; a transient failure keeps them visible.
public enum ProviderPhase: Sendable {
    case loading
    case loaded(UsageSnapshot)
    case stale(UsageSnapshot, error: String)
    case failed(String)
    case redirected(provider: ProviderID, message: String)
    /// The current account has no readable quota: setup is missing, the
    /// account signed out, or the service confirmed there is no plan.
    case notice(String)

    public var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot), let .stale(snapshot, _): snapshot
        case .loading, .failed, .redirected, .notice: nil
        }
    }

    public var errorMessage: String? {
        switch self {
        case let .stale(_, error), let .failed(error): error
        case .loading, .loaded, .redirected, .notice: nil
        }
    }

    public static func failure(_ error: Error, previous: ProviderPhase?) -> ProviderPhase {
        if let error = error as? ProviderError {
            switch error {
            case let .usageOnOtherProvider(provider, hint):
                return .redirected(provider: provider, message: hint)
            case .notConfigured, .noPlan, .signedOut, .usageUnavailable:
                return .notice(error.localizedDescription)
            default: break
            }
        }
        if let snapshot = previous?.snapshot {
            return .stale(snapshot, error: error.localizedDescription)
        }
        return .failed(error.localizedDescription)
    }

    public var discardsCachedReading: Bool {
        switch self {
        case .redirected, .notice: true
        default: false
        }
    }

    /// Informational text also changes a callout's height, even though it
    /// deliberately does not count as an update failure.
    public var explanation: String? {
        switch self {
        case let .redirected(_, message), let .notice(message): message
        default: errorMessage
        }
    }
}
