import Foundation

/// A service-confirmed X Subscription. The identifiers identify the shared
/// allowance, rather than the login's email or a display name.
public struct XSubscriptionInfo: Sendable, Equatable, Codable {
    public var tier: String
    public var workspaceID: String?
    public var seatID: String?
    /// Providers whose verified snapshots were projected into this reading.
    /// Persisted so old widget selections and links still find the shared card.
    public var memberProviders: [ProviderID]

    public static let supportedTiers: Set<String> = ["free", "plus", "premium", "super", "ultra"]

    public init(
        tier: String, workspaceID: String? = nil, seatID: String? = nil,
        memberProviders: [ProviderID] = [])
    {
        self.tier = tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.workspaceID = Self.identifier(workspaceID)
        self.seatID = Self.identifier(seatID)
        self.memberProviders = Self.members(memberProviders)
    }

    public var tierLabel: String { tier.prefix(1).uppercased() + tier.dropFirst() }

    public struct Identity: Sendable, Hashable {
        public var workspaceID: String
        public var seatID: String
    }

    /// Both IDs are required. A personal email, a plan name, or a matching
    /// reset time cannot prove that two services spend one allowance.
    public var verifiedIdentity: Identity? {
        guard let workspaceID = Self.identifier(workspaceID), let seatID = Self.identifier(seatID) else { return nil }
        return Identity(workspaceID: workspaceID, seatID: seatID)
    }

    private static func identifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func members(_ values: [ProviderID]) -> [ProviderID] {
        [.cursor, .grok].filter { values.contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case tier, workspaceID, seatID, memberProviders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tier: try c.decode(String.self, forKey: .tier),
            workspaceID: try? c.decodeIfPresent(String.self, forKey: .workspaceID),
            seatID: try? c.decodeIfPresent(String.self, forKey: .seatID),
            memberProviders: ((try? c.decodeIfPresent([String].self, forKey: .memberProviders)) ?? [])
                .compactMap { ProviderID(stored: $0) })
    }
}

/// Display projection only: it never changes sign-ins or adds up provider
/// percentages, balances or spend. Old plans and unverified identities stay
/// separate; the newest shared reading remains authoritative even if unknown.
public enum XSubscriptionGrouping {
    public struct Projection: Sendable {
        public var snapshots: [ProviderID: UsageSnapshot]
        /// A hidden/previous provider selection resolves to its shared owner.
        public var aliases: [ProviderID: ProviderID]
        /// The raw provider supplying the owner's newest entire snapshot.
        public var authoritativeProviders: [ProviderID: ProviderID]

        public func owner(for provider: ProviderID) -> ProviderID { aliases[provider] ?? provider }
    }

    public static func project(
        _ snapshots: [ProviderID: UsageSnapshot], presentProviders: Set<ProviderID>? = nil) -> Projection
    {
        let present = presentProviders ?? Set(snapshots.keys)
        var result = Projection(
            snapshots: snapshots, aliases: [:],
            authoritativeProviders: Dictionary(uniqueKeysWithValues: snapshots.keys.map { ($0, $0) }))
        if let cursor = snapshots[.cursor], let grok = snapshots[.grok],
           let cursorIdentity = cursor.xSubscription?.verifiedIdentity,
           let grokIdentity = grok.xSubscription?.verifiedIdentity,
           cursorIdentity == grokIdentity
        {
            let source: ProviderID = cursor.fetchedAt > grok.fetchedAt ? .cursor : .grok
            var shared = source == .cursor ? cursor : grok
            shared.xSubscription?.memberProviders = [.cursor, .grok]
            result.snapshots[.grok] = shared
            result.snapshots.removeValue(forKey: .cursor)
            result.aliases[.cursor] = .grok
            result.authoritativeProviders[.grok] = source
            result.authoritativeProviders.removeValue(forKey: .cursor)
        }
        // A previously projected reading may already be the only entry in a
        // synced cache. Do not redirect a real, now-separate account's card.
        for (owner, snapshot) in result.snapshots where owner == .grok || owner == .cursor {
            guard let info = snapshot.xSubscription, info.verifiedIdentity != nil else { continue }
            for member in info.memberProviders where member != owner && !present.contains(member) {
                result.aliases[member] = owner
            }
        }
        return result
    }
}
