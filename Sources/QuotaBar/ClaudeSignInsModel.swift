import SwiftUI
import QuotaCore

/// The Claude Code sign-ins besides the card's (issue #8) — one per
/// `CLAUDE_CONFIG_DIR`, often another organization of the same email — read
/// on the card's beat. Kept apart from `UsageSnapshot`, like the Codex
/// accounts, so they stay on the Mac that holds them.
@MainActor
final class ClaudeSignInsModel: ObservableObject {
    @Published private(set) var others: [ClaudeSignIns.Reading] = []
    /// Who the card's own sign-in is.
    @Published private(set) var card: ClaudeProvider.Identity?
    /// Every Claude Code keychain item on this Mac, the default first: what a
    /// profile can be set to read.
    @Published private(set) var services: [String] = []
    /// Who each of them is, as far as read.
    @Published private(set) var identities: [String: ClaudeProvider.Identity] = [:]
    private var reading = false
    private var readAt = Date.distantPast

    /// A failure keeps the last good figures beside the reason. At most once
    /// every 90 seconds unless `force`: the card's own refresh asks for it
    /// each time, and Anthropic answers too many reads with a 429.
    func read(cardService: String = LocalCredentials.claudeService, force: Bool = false) async {
        guard !reading, force || Date().timeIntervalSince(readAt) >= 90 else { return }
        reading = true
        readAt = Date()
        defer { reading = false }
        card = await ClaudeSignIns.cardIdentity(service: cardService)
        let fresh = await ClaudeSignIns.readOthers(card: cardService)
        services = [LocalCredentials.claudeService] + LocalCredentials.claudeExtraServices()
        if let card { identities[cardService] = card }
        for reading in fresh { if let identity = reading.identity { identities[reading.id] = identity } }
        let last = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        others = fresh.map { reading in
            var reading = reading
            if reading.snapshot == nil { reading.snapshot = last[reading.id]?.snapshot }
            if reading.identity == nil { reading.identity = last[reading.id]?.identity }
            return reading
        }
    }

    /// A profile switch (#8): the card's sign-in and one under the arrow
    /// trade places, each with what it last read. Nothing is asked of the
    /// server; the next refresh reads them as usual.
    func moveCard(to service: String, from previous: String, previousSnapshot: UsageSnapshot?) {
        guard service != previous, !services.isEmpty else { return }
        let outgoing = ClaudeSignIns.Reading(
            id: previous, identity: card ?? identities[previous],
            plan: previousSnapshot?.planName, snapshot: previousSnapshot)
        card = identities[service]
        others = ClaudeSignIns.afterSwitch(others, to: service, from: outgoing, card: card)
    }

    /// Off-screen renders (`--snapshot`): sign-ins to draw, without the keychain.
    func seedForPreview(card: ClaudeProvider.Identity?, others: [ClaudeSignIns.Reading]) {
        self.card = card
        self.others = others
        services = [LocalCredentials.claudeService] + others.map(\.id)
        identities[LocalCredentials.claudeService] = card
        for reading in others { identities[reading.id] = reading.identity }
    }

    /// A profile's choice, named: the organization, else the email, else
    /// which item it is.
    func choiceLabel(_ service: String, masked: Bool) -> String {
        let identity = identities[service]
        let isDefault = service == LocalCredentials.claudeService
        if !masked, let name = identity?.organization ?? identity?.email {
            let email = identity?.organization != nil ? identity?.email.map { " · \($0)" } ?? "" : ""
            return name + email + (isDefault ? L10n.t(" (default)", "（默认）") : "")
        }
        return isDefault
            ? L10n.t("Default sign-in", "默认登录")
            : L10n.t("Sign-in \(service.suffix(8))", "登录 \(service.suffix(8))")
    }

    /// The organization, which is what tells two sign-ins of one email
    /// apart; else the email; numbered when neither is to be shown.
    func label(_ identity: ClaudeProvider.Identity?, number: Int, masked: Bool) -> String {
        if !masked, let name = identity?.organization ?? identity?.email { return name }
        return L10n.t("Organization \(number)", "组织 \(number)")
    }

    /// The email under an organization's name, when it adds something.
    func detail(_ identity: ClaudeProvider.Identity?, masked: Bool) -> String? {
        guard !masked, identity?.organization != nil else { return nil }
        return identity?.email
    }
}
