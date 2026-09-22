import Foundation

// MARK: - Provider protocol

public protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    /// Whether the required credentials can be resolved right now.
    func isConfigured(config: ConfigStore) -> Bool
    func fetch(config: ConfigStore) async throws -> UsageSnapshot
    /// What the next fetch would use, for Settings — nil when there is only
    /// one way in and nothing to tell apart. Reads local files and the
    /// keychain memo, never the network.
    func sourceInfo(config: ConfigStore) -> ProviderSourceInfo?
}

extension QuotaProvider {
    public func sourceInfo(config: ConfigStore) -> ProviderSourceInfo? { nil }
}

/// Which of a provider's credentials is in use, said in a line.
public struct ProviderSourceInfo: Sendable, Equatable {
    /// "Kimi Code sign-in · Global (kimi.ai)".
    public var summary: String
    /// A second, quieter line: what else is there, or why something is not done.
    public var note: String?
    /// The console for the account in use, when it differs by edition.
    public var consoleURL: URL?

    public init(summary: String, note: String? = nil, consoleURL: URL? = nil) {
        self.summary = summary
        self.note = note
        self.consoleURL = consoleURL
    }
}
