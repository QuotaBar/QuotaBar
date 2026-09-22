import Foundation

// MARK: - Readings as JSON

/// How a reading is written down: the Mac's own cache of last readings and
/// the copy iCloud carries to the phone use the same form. Decoding is
/// lenient per field — a newer build may add something an older one cannot
/// read, and that must not cost the rest of the reading.

extension ResetCredits: Codable {
    private enum CodingKeys: String, CodingKey { case available, applicable, totalEarned, credits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try c.decode(Int.self, forKey: .available),
            applicable: try c.decodeIfPresent(Int.self, forKey: .applicable),
            totalEarned: try? c.decodeIfPresent(Int.self, forKey: .totalEarned),
            credits: (try? c.decodeIfPresent([ResetCredit].self, forKey: .credits)) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(applicable, forKey: .applicable)
        try c.encodeIfPresent(totalEarned, forKey: .totalEarned)
        if !credits.isEmpty { try c.encode(credits, forKey: .credits) }
    }
}

extension UsageWindow: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, usedPercent, detail, resetsAt, isActive, windowSeconds, scope, label, note, inUse, extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            usedPercent: try c.decodeIfPresent(Double.self, forKey: .usedPercent),
            detail: try c.decodeIfPresent(String.self, forKey: .detail),
            resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt),
            isActive: (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? false,
            windowSeconds: try c.decodeIfPresent(Int.self, forKey: .windowSeconds),
            scope: try c.decodeIfPresent(String.self, forKey: .scope),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            note: try c.decodeIfPresent(String.self, forKey: .note),
            inUse: (try? c.decodeIfPresent(Bool.self, forKey: .inUse)) ?? false)
        if let id = try c.decodeIfPresent(String.self, forKey: .id) { self.id = id }
        extra = (try? c.decodeIfPresent(Bool.self, forKey: .extra)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(note, forKey: .note)
        if inUse { try c.encode(inUse, forKey: .inUse) }
        if extra { try c.encode(extra, forKey: .extra) }
    }
}

extension UsageSnapshot: Codable {
    private enum CodingKeys: String, CodingKey { case planName, account, windows, fetchedAt, resetCredits, balance, edition, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            planName: try c.decodeIfPresent(String.self, forKey: .planName),
            account: try c.decodeIfPresent(String.self, forKey: .account),
            windows: (try? c.decodeIfPresent([UsageWindow].self, forKey: .windows)) ?? [],
            fetchedAt: try c.decode(Date.self, forKey: .fetchedAt),
            resetCredits: try? c.decodeIfPresent(ResetCredits.self, forKey: .resetCredits),
            balance: try? c.decodeIfPresent(BalanceSheet.self, forKey: .balance),
            edition: try? c.decodeIfPresent(String.self, forKey: .edition),
            source: try? c.decodeIfPresent(String.self, forKey: .source))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(planName, forKey: .planName)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(windows, forKey: .windows)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(resetCredits, forKey: .resetCredits)
        try c.encodeIfPresent(balance, forKey: .balance)
        try c.encodeIfPresent(edition, forKey: .edition)
        try c.encodeIfPresent(source, forKey: .source)
    }
}
