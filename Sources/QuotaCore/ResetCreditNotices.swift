import Foundation

// MARK: - Resets the account is given

/// Something to say about what a provider gives an account beside its plan —
/// the early resets Codex and Claude hand out every so often, each running
/// out unspent after about a month, and the credits that carry a deadline.
public struct ResetCreditNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The count went up by this many since the reading before.
        case given(Int)
        /// This credit runs out within a day.
        case expiring(ResetCredit)
        /// This credit balance, by its row's name, runs out within a day.
        case creditExpiring(name: String, CreditAmount)
    }

    public var provider: ProviderID
    public var kind: Kind
    /// How many the account holds now.
    public var available: Int
    /// Identifies the notice, so it is said once.
    public var key: String
}

/// How near something the account was given is to running out unspent: the
/// rows that list it and the card's badge take its colour.
public enum CreditUrgency: Int, Comparable, Sendable {
    case none, day, lastHour

    public init(expiresAt: Date?, now: Date = .now) {
        guard let expiresAt, expiresAt > now else { self = .none; return }
        let left = expiresAt.timeIntervalSince(now)
        if left <= ResetCreditCheck.lastCallLead {
            self = .lastHour
        } else if left <= ResetCreditCheck.expiryLead {
            self = .day
        } else {
            self = .none
        }
    }

    public static func < (lhs: CreditUrgency, rhs: CreditUrgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thing the account was given that runs out: an early reset, or a
/// credit balance.
public struct GivenDeadline: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case reset(ResetCredit)
        /// The credit row's name and what it holds.
        case credit(name: String, CreditAmount)
    }

    public var item: Item
    public var expiresAt: Date

    public var name: String {
        switch item {
        case let .reset(credit): credit.title ?? L10n.t("Full reset", "完整重置")
        case let .credit(name, _): name
        }
    }

    public func urgency(now: Date = .now) -> CreditUrgency { CreditUrgency(expiresAt: expiresAt, now: now) }

    /// Which one it is among the provider's, for a reminder's key.
    var tag: String {
        let stamp = String(Int(expiresAt.timeIntervalSince1970))
        switch item {
        case let .reset(credit): return credit.id ?? stamp
        case .credit: return "credit-\(stamp)"
        }
    }
}

extension UsageSnapshot {
    /// What the account was given that is still to run out, soonest first:
    /// the early resets it holds and the credit rows with a deadline.
    public func givenDeadlines(now: Date = .now) -> [GivenDeadline] {
        var out: [GivenDeadline] = []
        for credit in resetCredits?.credits ?? [] {
            guard let expiresAt = credit.expiresAt, expiresAt > now else { continue }
            out.append(GivenDeadline(item: .reset(credit), expiresAt: expiresAt))
        }
        for window in windows {
            guard let credit = window.credit, let expiresAt = credit.expiresAt, expiresAt > now else { continue }
            out.append(GivenDeadline(item: .credit(name: window.displayName, credit), expiresAt: expiresAt))
        }
        return out.sorted { $0.expiresAt < $1.expiresAt }
    }
}

/// A reminder set for the last hour before a deadline. The reading that
/// would say it may come up to an hour late, so it is handed to the system
/// ahead of time and taken back once a reading no longer lists the credit.
public struct ResetCreditLastCall: Equatable, Sendable {
    public var deadline: GivenDeadline
    public var fireAt: Date
    public var key: String
}

public enum ResetCreditCheck {
    /// How long before a deadline the reminder comes.
    public static let expiryLead: TimeInterval = 24 * 3600
    /// How long before a deadline the last call comes, when it is wanted.
    public static let lastCallLead: TimeInterval = 3600

    /// The notices a new reading brings.
    ///
    /// A reset given needs a reading from before to compare with: the first
    /// one ever read sets the baseline and says nothing, the way the pace
    /// alerts do. A reading from before that carried no count had none to
    /// spend. A reminder is keyed by the credit, so each speaks once, however
    /// many times the list is read in its last day. A credit balance has no
    /// id of its own — its row's name follows the language — so it is keyed
    /// by its deadline and the account it belongs to.
    public static func notices(
        provider: ProviderID,
        previous: UsageSnapshot?,
        current: ResetCredits?,
        credits: [UsageWindow] = [],
        account: String? = nil,
        notified: [String],
        now: Date = .now) -> [ResetCreditNotice]
    {
        var out: [ResetCreditNotice] = []
        if let current {
            if let previous {
                let before = previous.resetCredits?.available ?? 0
                if current.available > before {
                    let key = "\(provider.rawValue)|given|\(current.available)"
                    out.append(ResetCreditNotice(provider: provider, kind: .given(current.available - before), available: current.available, key: key))
                }
            }
            for credit in current.credits {
                guard let expiresAt = credit.expiresAt, expiresAt > now, expiresAt.timeIntervalSince(now) <= expiryLead else { continue }
                let key = "\(provider.rawValue)|expiring|\(credit.id ?? String(Int(expiresAt.timeIntervalSince1970)))"
                guard !notified.contains(key) else { continue }
                out.append(ResetCreditNotice(provider: provider, kind: .expiring(credit), available: current.available, key: key))
            }
        }
        for window in credits {
            guard let credit = window.credit, let expiresAt = credit.expiresAt,
                  expiresAt > now, expiresAt.timeIntervalSince(now) <= expiryLead
            else { continue }
            let key = "\(provider.rawValue)|credit|\(tag(account))|\(Int(expiresAt.timeIntervalSince1970))"
            guard !notified.contains(key) else { continue }
            out.append(ResetCreditNotice(
                provider: provider, kind: .creditExpiring(name: window.displayName, credit),
                available: current?.available ?? 0, key: key))
        }
        return out
    }

    /// The last calls a reading backs: one an hour before each deadline that
    /// falls within the day, while that hour is still ahead. A deadline first
    /// seen inside its last hour has had the day's reminder just now.
    public static func lastCalls(provider: ProviderID, snapshot: UsageSnapshot, now: Date = .now) -> [ResetCreditLastCall] {
        let prefix = lastCallPrefix(provider: provider, account: snapshot.account)
        return snapshot.givenDeadlines(now: now).compactMap { deadline in
            let fireAt = deadline.expiresAt.addingTimeInterval(-lastCallLead)
            guard fireAt > now, deadline.expiresAt.timeIntervalSince(now) <= expiryLead else { return nil }
            return ResetCreditLastCall(deadline: deadline, fireAt: fireAt, key: prefix + deadline.tag)
        }
    }

    /// What every last call for this provider's account starts with: a
    /// reading of one account takes back only that account's.
    public static func lastCallPrefix(provider: ProviderID, account: String?) -> String {
        "\(provider.rawValue)|last-hour|\(tag(account))|"
    }

    /// Where an early reset is spent, for the reminder and the row.
    public static func spendHint(for provider: ProviderID) -> String? {
        switch provider {
        case .claude: L10n.t("Use it with /limit-reset in Claude Code.", "可以在 Claude Code 里用 /limit-reset 兑换。")
        case .codex: L10n.t("Use it with /usage in the Codex CLI.", "可以在 Codex CLI 里用 /usage 兑换。")
        default: nil
        }
    }

    /// A short tag that tells accounts apart in a key without keeping the
    /// address in the settings file: FNV-1a, stable across launches.
    static func tag(_ account: String?) -> String {
        guard let account, !account.isEmpty else { return "-" }
        var hash: UInt32 = 2_166_136_261
        for byte in account.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(hash, radix: 36)
    }
}
