import Foundation

// MARK: - What one Mac leaves in iCloud for the phone

/// The readings one Mac last had, as it writes them to the owner's private
/// iCloud database for the iPhone app and its widgets.
///
/// Results only. The phone cannot read a provider itself — the sign-ins live
/// in files and keychain items on the Mac — and no credential ever goes into
/// this: plans, windows, figures, reset times, balances, the last error.
public struct CloudReadings: Sendable {
    /// Bumped only when an older phone could no longer make sense of the
    /// readings; a field added is not a new version.
    public static let currentVersion = 1

    public var version: Int
    /// This Mac's own id: one record per Mac, so two Macs never overwrite
    /// each other.
    public var deviceID: String
    /// "Studio", "MacBook Pro": for telling the Macs apart on the phone.
    public var deviceName: String
    /// "MacBook Pro (16-inch, M5 Max)", "Mac mini" — what the machine is,
    /// beside the name its owner gave it. Nil from a Mac that could not say.
    public var deviceModel: String?
    public var appVersion: String
    /// "zh" or "en". A reading is worded when it is taken — window names,
    /// plan details — so the phone knows which language it is looking at.
    public var language: String
    /// When the Mac wrote this. Moves even when no figure did, so the phone
    /// can tell a Mac that is quiet from one that is off.
    public var updatedAt: Date
    /// How often this Mac reads its providers — the owner's 5, 15 or 30
    /// minutes. A figure is at most this old when the Mac is up.
    public var refreshSeconds: Int
    /// The currency the Mac shows spend in, and its rate.
    public var money: CloudMoney
    /// In the Mac's own order.
    public var providers: [Entry]

    public struct Entry: Sendable {
        /// `ProviderID.rawValue`, kept as a string: a provider a newer Mac
        /// knows and this phone does not is skipped, not a failed decode.
        public var id: String
        /// The last good reading, still sent after a failed refresh — with
        /// `error` set, so it is shown as old rather than taken as current.
        public var snapshot: UsageSnapshot?
        /// Why the last refresh failed, worded; nil when it worked.
        public var error: String?
        /// For the detail page; nil for a provider with no CLI logs behind it.
        public var spend: CloudSpend?
        public var links: CloudLinks?

        public init(
            id: String, snapshot: UsageSnapshot?, error: String? = nil,
            spend: CloudSpend? = nil, links: CloudLinks? = nil)
        {
            self.id = id
            self.snapshot = snapshot
            self.error = error
            self.spend = spend
            self.links = links
        }

        public var provider: ProviderID? { ProviderID(rawValue: id) }
    }

    public init(
        version: Int = CloudReadings.currentVersion,
        deviceID: String,
        deviceName: String,
        deviceModel: String? = nil,
        appVersion: String,
        language: String,
        updatedAt: Date,
        refreshSeconds: Int = 300,
        money: CloudMoney = CloudMoney(),
        providers: [Entry])
    {
        self.version = version
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.language = language
        self.updatedAt = updatedAt
        self.refreshSeconds = refreshSeconds
        self.money = money
        self.providers = providers
    }
}

// MARK: - Coding

extension CloudReadings.Entry: Codable {
    private enum CodingKeys: String, CodingKey { case id, snapshot, error, spend, links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        snapshot = try? c.decodeIfPresent(UsageSnapshot.self, forKey: .snapshot)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        spend = try? c.decodeIfPresent(CloudSpend.self, forKey: .spend)
        links = try? c.decodeIfPresent(CloudLinks.self, forKey: .links)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(spend, forKey: .spend)
        try c.encodeIfPresent(links, forKey: .links)
    }
}

extension CloudReadings: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, deviceID, deviceName, deviceModel, appVersion, language, updatedAt, refreshSeconds, currency, usdRate, providers
    }

    /// An entry that will not decode is dropped on its own; the others stay.
    private struct LossyEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? ""
        deviceModel = try? c.decodeIfPresent(String.self, forKey: .deviceModel)
        appVersion = (try? c.decodeIfPresent(String.self, forKey: .appVersion)) ?? ""
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? "en"
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        refreshSeconds = max(60, (try? c.decodeIfPresent(Int.self, forKey: .refreshSeconds)) ?? 300)
        money = CloudMoney(
            currency: (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "USD",
            usdRate: try? c.decodeIfPresent(Double.self, forKey: .usdRate))
        providers = ((try? c.decodeIfPresent([LossyEntry].self, forKey: .providers)) ?? []).compactMap(\.entry)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(deviceModel, forKey: .deviceModel)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(language, forKey: .language)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(refreshSeconds, forKey: .refreshSeconds)
        try c.encode(money.currency, forKey: .currency)
        try c.encodeIfPresent(money.usdRate, forKey: .usdRate)
        try c.encode(providers, forKey: .providers)
    }

    /// A CloudKit record holds at most 1MB. Readings are a few kilobytes;
    /// only a balance sheet's charts and per-key usage can grow, and a
    /// month of spend, so past `limit` those go first — the balance and the
    /// spend totals always stay.
    public func encoded(limit: Int = 512 * 1024) throws -> Data {
        let full = try Self.encoder.encode(self)
        guard full.count > limit else { return full }
        var trimmed = self
        for index in trimmed.providers.indices {
            guard var balance = trimmed.providers[index].snapshot?.balance else { continue }
            balance.chart = [:]
            balance.keys = nil
            trimmed.providers[index].snapshot?.balance = balance
        }
        for index in trimmed.providers.indices where trimmed.providers[index].spend != nil {
            trimmed.providers[index].spend?.trend = []
            for period in trimmed.providers[index].spend!.periods.indices {
                trimmed.providers[index].spend!.periods[period].models = []
            }
        }
        return try Self.encoder.encode(trimmed)
    }

    public static func decode(_ data: Data) throws -> CloudReadings {
        try decoder.decode(CloudReadings.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - When the Mac writes

/// When a Mac writes its readings again: after a refresh that moved something,
/// and on a heartbeat between refreshes, so a Mac set to read every half hour
/// still says it is up. The phone cannot be woken more often than this anyway.
public enum CloudSyncPolicy {
    /// Changes wait at least this long after the last write.
    public static let minimumInterval: TimeInterval = 2 * 60
    /// Written this often even when nothing moved, so the phone can tell a
    /// quiet Mac from one that is asleep or off.
    public static let heartbeat: TimeInterval = 20 * 60

    /// `last` is the signature of what was last written and when; nil when
    /// nothing has been written by this launch.
    public static func shouldWrite(
        current: CloudReadings.Signature,
        last: (signature: CloudReadings.Signature, at: Date)?,
        now: Date) -> Bool
    {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last.at)
        // A clock that went backwards: write, rather than wait for it.
        if elapsed < 0 { return true }
        if elapsed >= heartbeat { return true }
        return current != last.signature && elapsed >= minimumInterval
    }
}

extension CloudReadings {
    /// What the phone would draw differently: the providers and their order,
    /// plans, whether each is failing, every window's figure to the whole
    /// point and its reset to the minute, and each balance. Not when a
    /// reading was taken, which moves every minute on its own.
    public struct Signature: Equatable, Sendable {
        fileprivate var parts: [String]
    }

    public var signature: Signature {
        Signature(parts: providers.map { entry in
            var line = [entry.id, entry.error == nil ? "ok" : "failing"]
            if let snapshot = entry.snapshot {
                line.append(snapshot.planName ?? "")
                line.append(snapshot.edition ?? "")
                for window in snapshot.windows {
                    let used = window.usedPercent.map { String(Int($0.rounded())) } ?? "-"
                    let reset = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 60).rounded())) } ?? "-"
                    line.append("\(window.id)=\(used)@\(reset)")
                }
                if let balance = snapshot.balance {
                    line.append(balance.balances.map { "\($0.currency):\(String(format: "%.2f", $0.total))" }
                        .joined(separator: ","))
                }
            }
            return line.joined(separator: "|")
        })
    }
}

// MARK: - Reading it on the phone

/// Every Mac's readings, made into one list: per provider, the newest
/// reading any Mac has, in the order of the Mac that wrote most recently.
public struct MergedReadings: Sendable {
    public struct Item: Sendable, Identifiable {
        public var provider: ProviderID
        public var snapshot: UsageSnapshot?
        public var error: String?
        public var spend: CloudSpend?
        public var links: CloudLinks?
        /// The Mac this reading came from.
        public var deviceName: String
        public var deviceModel: String?
        public var deviceUpdatedAt: Date

        public var id: String { provider.rawValue }
    }

    public var items: [Item]
    /// The newest write of any Mac; nil when no Mac has written.
    public var updatedAt: Date?
    /// The refresh cadence of the Mac that wrote last.
    public var refreshSeconds: Int?
    /// Every Mac that has written, the most recent first — for saying where
    /// the figures come from.
    public var devices: [Device]

    public struct Device: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var model: String?
        public var appVersion: String
        public var updatedAt: Date

        public var kind: MacKind { MacKind(model: model, name: name) }

        public func freshness(now: Date = .now) -> CloudFreshness {
            CloudFreshness(updatedAt: updatedAt, now: now)
        }
    }

    /// The name of the Mac that wrote last.
    public var latestDeviceName: String?
    /// How the Mac that wrote last shows money.
    public var money: CloudMoney

    public func freshness(now: Date = .now) -> CloudFreshness {
        CloudFreshness(updatedAt: updatedAt, now: now)
    }

    public init(_ devices: [CloudReadings]) {
        let newestFirst = devices.sorted { $0.updatedAt > $1.updatedAt }
        var order: [ProviderID] = []
        var best: [ProviderID: Item] = [:]
        for device in newestFirst {
            for entry in device.providers {
                guard let provider = entry.provider else { continue }
                let item = Item(
                    provider: provider, snapshot: entry.snapshot, error: entry.error,
                    spend: entry.spend, links: entry.links,
                    deviceName: device.deviceName, deviceModel: device.deviceModel, deviceUpdatedAt: device.updatedAt)
                guard let current = best[provider] else {
                    order.append(provider)
                    best[provider] = item
                    continue
                }
                if Self.isNewer(item, than: current) { best[provider] = item }
            }
        }
        items = order.compactMap { best[$0] }
        updatedAt = newestFirst.first?.updatedAt
        refreshSeconds = newestFirst.first?.refreshSeconds
        latestDeviceName = newestFirst.first?.deviceName
        self.devices = newestFirst.map {
            Device(id: $0.deviceID, name: $0.deviceName, model: $0.deviceModel, appVersion: $0.appVersion, updatedAt: $0.updatedAt)
        }
        money = newestFirst.first?.money ?? CloudMoney()
    }

    /// In the order the owner dragged the cards into on the phone. A
    /// provider the order has never seen — newly enabled on a Mac — goes at
    /// the end, in the Mac's order, rather than jumping to the top.
    public func ordered(by saved: [String]) -> MergedReadings {
        var copy = self
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = items.enumerated().map { (offset: $0.offset, item: $0.element) }
        copy.items = indexed.sorted { a, b in
            switch (rank[a.item.provider.rawValue], rank[b.item.provider.rawValue]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.item)
        return copy
    }

    /// A reading beats no reading; between two, the one taken later. Two Macs
    /// signed in to the same account agree on the figure, and the later one is
    /// simply the more recent look.
    private static func isNewer(_ a: Item, than b: Item) -> Bool {
        switch (a.snapshot?.fetchedAt, b.snapshot?.fetchedAt) {
        case let (x?, y?): x > y
        case (.some, nil): true
        default: false
        }
    }
}

/// How far to trust what the phone is showing. Staleness is never silent on
/// the Mac, and it is not on the phone either.
public enum CloudFreshness: Equatable, Sendable {
    /// Written recently; the Mac is up.
    case current
    /// The Mac has not written for longer than its heartbeat allows: asleep,
    /// off, or offline. Shown with how long ago it last wrote.
    case macQuiet(since: Date)
    /// No Mac has written yet.
    case nothing

    /// A Mac that is up writes at least once a heartbeat, whatever its
    /// refresh cadence; past a heartbeat and a half, a write that should have
    /// come did not.
    public static let quietAfter: TimeInterval = CloudSyncPolicy.heartbeat * 1.5

    public init(updatedAt: Date?, now: Date = .now) {
        guard let updatedAt else { self = .nothing; return }
        self = now.timeIntervalSince(updatedAt) > Self.quietAfter ? .macQuiet(since: updatedAt) : .current
    }
}

extension UsageWindow {
    /// The reset this reading reports has passed. The figure on file is from
    /// the window before, so the phone says the window has reset rather than
    /// showing a spent quota that is in fact fresh.
    public func hasReset(now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

// MARK: - Which kind of Mac

/// The shape of the machine, for its icon: a laptop, a Mac mini, a Mac
/// Studio, a Mac Pro or an iMac. Read from the model name the Mac reports —
/// "MacBook Pro (16-inch, M5 Max)" — or, on an Intel Mac that reports none,
/// from its model identifier ("Macmini8,1"), and failing both from the name
/// its owner gave it, which by default carries the model.
public enum MacKind: String, Sendable, CaseIterable {
    case laptop
    case mini
    case studio
    case pro
    case imac
    case unknown

    public init(model: String?, name: String = "") {
        for text in [model, name].compactMap({ $0?.lowercased() }) {
            let squeezed = text.replacingOccurrences(of: " ", with: "")
            if squeezed.contains("macbook") { self = .laptop; return }
            if squeezed.contains("macmini") { self = .mini; return }
            if squeezed.contains("macstudio") { self = .studio; return }
            if squeezed.contains("macpro") { self = .pro; return }
            if squeezed.contains("imac") { self = .imac; return }
        }
        self = .unknown
    }

    /// An SF Symbol present on both the Mac and the phone.
    public var symbolName: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .mini: "macmini"
        case .studio: "macstudio"
        case .pro: "macpro.gen3"
        case .imac: "desktopcomputer"
        case .unknown: "desktopcomputer"
        }
    }

    /// The model's plain name where the Mac gave none: an Intel Mac's
    /// "MacBookPro16,1" reads as "MacBook Pro".
    public static func displayName(forIdentifier identifier: String) -> String? {
        let prefixes: [(String, String)] = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"), ("iMac", "iMac"),
        ]
        return prefixes.first { identifier.hasPrefix($0.0) }?.1
    }
}


// MARK: - The phone asking the Mac to read now

/// A phone's "refresh now", left in iCloud for the Mac to pick up. The
/// Mac looks for one every half minute while syncing is on; the phone then
/// watches for that Mac's next write.
public struct CloudRefreshRequest: Sendable, Equatable {
    public var requestedAt: Date
    /// The phone's name, said in the Mac's Settings.
    public var from: String

    public init(requestedAt: Date, from: String) {
        self.requestedAt = requestedAt
        self.from = from
    }
}

/// Whether the Mac acts on a request it has found.
public enum RefreshRequestPolicy {
    /// A request older than this is from before the Mac was listening —
    /// asleep, or off — and the phone has long stopped waiting for it.
    public static let maximumAge: TimeInterval = 10 * 60
    /// Refreshes the phone asks for are at least this far apart: every read
    /// is a request to each provider, and Anthropic's usage endpoint turns
    /// away anything tighter than a few minutes.
    public static let minimumSpacing: TimeInterval = 60
    /// How often the Mac looks.
    public static let pollInterval: TimeInterval = 30
    /// How long the phone waits for the Mac to answer.
    public static let phoneWaits: TimeInterval = 90

    public static func shouldHonor(
        _ request: CloudRefreshRequest,
        lastHandled: Date?,
        lastRequestedRefresh: Date?,
        now: Date) -> Bool
    {
        if let lastHandled, request.requestedAt <= lastHandled { return false }
        let age = now.timeIntervalSince(request.requestedAt)
        guard age <= maximumAge, age >= -60 else { return false }
        if let lastRequestedRefresh, now.timeIntervalSince(lastRequestedRefresh) < minimumSpacing { return false }
        return true
    }
}
