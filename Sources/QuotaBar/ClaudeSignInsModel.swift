import SwiftUI
import QuotaCore

/// The Claude Code sign-ins besides the card's (issue #8) — one per
/// `CLAUDE_CONFIG_DIR`, often another organization of the same email — read
/// on the card's beat. Kept apart from `UsageSnapshot`, like the Codex
/// accounts, so they stay on the Mac that holds them.
@MainActor
final class ClaudeSignInsModel: ObservableObject {
    @Published private(set) var allReadings: [String: ClaudeSignIns.Reading] = [:]
    @Published private(set) var others: [ClaudeSignIns.Reading] = []
    /// Who the card's own sign-in is.
    @Published private(set) var card: ClaudeProvider.Identity?
    /// Every Claude Code keychain item on this Mac, the default first: what a
    /// profile can be set to read.
    @Published private(set) var services: [String] = []
    /// Who each of them is, as far as read.
    @Published private(set) var identities: [String: ClaudeProvider.Identity] = [:]
    private var hidden: [String] = []
    private var names: [String: String] = [:]
    private var generation = 0
    private var reading = false
    private var readAt = Date.distantPast

    /// A failure keeps the last good figures beside the reason. At most once
    /// every 90 seconds unless `force`: the card's own refresh asks for it
    /// each time, and Anthropic answers too many reads with a 429.
    func read(cardService: String = LocalCredentials.claudeService, force: Bool = false, hidden: [String] = [], names: [String: String] = [:]) async {
        self.hidden = hidden
        self.names = names
        if force {
            while reading {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        guard !reading, force || Date().timeIntervalSince(readAt) >= 90 else { return }
        services = ([LocalCredentials.claudeService] + Array(Set(LocalCredentials.claudeExtraServices() + Array(names.keys))).sorted()).filter { !hidden.contains($0) }
        for service in services {
            if let identity = LocalCredentials.claudeConfigIdentity(service: service) { identities[service] = identity }
        }
        let version = generation
        reading = true
        readAt = Date()
        defer { reading = false }
        let identity = await ClaudeSignIns.cardIdentity(service: cardService)
        let fresh = await ClaudeSignIns.readOthers(card: cardService, excluding: hidden, registered: Array(names.keys), deduplicate: false)
        guard version == generation else { return }
        card = identity
        services = ([LocalCredentials.claudeService] + Array(Set(LocalCredentials.claudeExtraServices() + Array(self.names.keys))).sorted()).filter { !self.hidden.contains($0) }
        if let card { identities[cardService] = card }
        for reading in fresh { if let identity = reading.identity { identities[reading.id] = identity } }
        let merged = fresh.filter { !self.hidden.contains($0.id) }.map { $0.preserving(allReadings[$0.id]) }
        allReadings = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        others = ClaudeSignIns.arranged(merged, card: card)
    }

    /// A profile switch (#8): the card's sign-in and one under the arrow
    /// trade places, each with what it last read. Nothing is asked of the
    /// server; the next refresh reads them as usual.
    func moveCard(to service: String, from previous: String, previousSnapshot: UsageSnapshot?) {
        guard service != previous, !services.isEmpty else { return }
        let outgoing = ClaudeSignIns.Reading(
            id: previous, identity: card ?? identities[previous],
            plan: previousSnapshot?.planName, snapshot: previousSnapshot)
        generation += 1
        card = identities[service]
        allReadings[previous] = outgoing
        others = ClaudeSignIns.afterSwitch(others, to: service, from: outgoing, card: card)
    }

    func invalidateReading(_ service: String) {
        generation += 1
        readAt = .distantPast
        allReadings.removeValue(forKey: service)
        others.removeAll { $0.id == service }
        if let identity = LocalCredentials.claudeConfigIdentity(service: service) { identities[service] = identity }
    }

    func forget(_ service: String) {
        generation += 1
        readAt = .distantPast
        hidden.append(service)
        names.removeValue(forKey: service)
        services.removeAll { $0 == service }
        others.removeAll { $0.id == service }
        allReadings.removeValue(forKey: service)
        identities.removeValue(forKey: service)
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
            : (!masked && names[service]?.isEmpty == false
                ? L10n.t("\(names[service]!) (not verified)", "\(names[service]!)（待确认）")
                : L10n.t("Sign-in \(service.suffix(8))", "登录 \(service.suffix(8))"))
    }

    /// The arrow's choices: the email alone, the organization only when two
    /// sign-ins share one, else which item it is.
    func pickerLabel(_ service: String, masked: Bool) -> String {
        guard !masked, let email = identities[service]?.email else { return choiceLabel(service, masked: masked) }
        let shared = services.filter { identities[$0]?.email == email }.count > 1
        let organization = shared ? identities[service]?.organization.map { " · " + $0 } ?? "" : ""
        let marker = service == LocalCredentials.claudeService ? L10n.t(" (default)", "（默认）") : ""
        return email + organization + marker
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
