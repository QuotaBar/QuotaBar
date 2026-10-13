import Foundation

/// Only the latest read of an enabled provider may replace its card. The
/// same invalidation applies to account changes and disable/re-enable.
public struct ProviderReadTracker: Sendable {
    private var versions: [ProviderID: UInt64] = [:]
    public init() {}

    @discardableResult
    public mutating func begin(_ provider: ProviderID) -> UInt64 {
        versions[provider, default: 0] &+= 1
        return versions[provider, default: 0]
    }

    public mutating func invalidate(_ provider: ProviderID) { begin(provider) }

    public func accepts(_ version: UInt64, for provider: ProviderID, isEnabled: Bool) -> Bool {
        isEnabled && versions[provider] == version
    }
}
