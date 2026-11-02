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
    /// Where each of them stands, as far as read: what the pickers mark.
    @Published private(set) var states: [String: ClaudeSignIns.State] = [:]
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
        let cardState = await ClaudeSignIns.currentState(service: cardService)
        let fresh = await ClaudeSignIns.readOthers(card: cardService, excluding: hidden, registered: Array(names.keys), deduplicate: false)
        guard version == generation else { return }
        card = identity
        services = ([LocalCredentials.claudeService] + Array(Set(LocalCredentials.claudeExtraServices() + Array(self.names.keys))).sorted()).filter { !self.hidden.contains($0) }
        if let card { identities[cardService] = card }
        for reading in fresh { if let identity = reading.identity { identities[reading.id] = identity } }
        var known = states.filter { services.contains($0.key) }
        known[cardService] = cardState
        for reading in fresh { known[reading.id] = reading.state ?? known[reading.id] }
        states = known
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
        states.removeValue(forKey: service)
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
        states.removeValue(forKey: service)
    }

    /// Off-screen renders (`--snapshot`): sign-ins to draw, without the keychain.
    func seedForPreview(
        card: ClaudeProvider.Identity?, others: [ClaudeSignIns.Reading],
        cardState: ClaudeSignIns.State? = nil)
    {
        self.card = card
        self.others = others
        services = [LocalCredentials.claudeService] + others.map(\.id)
        identities[LocalCredentials.claudeService] = card
        for reading in others {
            identities[reading.id] = reading.identity
            states[reading.id] = reading.state
        }
        if let cardState { states[LocalCredentials.claudeService] = cardState }
    }

    // MARK: What a picker offers

    nonisolated static func note(for state: ClaudeSignIns.State?) -> String? {
        switch state {
        case .expired?: L10n.t("expired", "已过期")
        case .signedOut?: L10n.t("signed out", "已退出登录")
        case .needsAuthorization?: L10n.t("needs access", "待授权")
        case .missing?: L10n.t("not signed in", "未登录")
        case .directoryMissing?: L10n.t("folder gone", "找不到登录目录")
        case .ready?, nil: nil
        }
    }

    /// One row of a picker: the sign-in, how it stands, and what a press could
    /// do about it.
    struct Option: Identifiable {
        let id: String
        /// Who it is, without how it stands.
        let name: String
        let state: ClaudeSignIns.State?
        let repair: ClaudeSignIns.Repair?

        /// How it stands, in words, when it is not simply fine.
        var note: String? { ClaudeSignInsModel.note(for: state) }

        /// A menu's row.
        var label: String { note.map { "\(name) · \($0)" } ?? name }

        /// A capsule's: no room for words, so a mark where it cannot read.
        var barLabel: String {
            switch state {
            case .signedOut?, .needsAuthorization?, .missing?, .directoryMissing?: "⚠︎ \(name)"
            case .ready?, .expired?, nil: name
            }
        }

        /// The row's own button, "Sign in to a@b.c".
        var repairTitle: String? {
            switch repair {
            case .signIn?: L10n.t("Sign in to \(name)", "登录 \(name)")
            case .authorize?: L10n.t("Allow access to \(name)", "授权读取 \(name)")
            case nil: nil
            }
        }
    }

    /// The choices a picker lists while `selected` is in use: one row for each
    /// account, the ones that read first, each with how it stands. `failing`:
    /// the card's own reading is failing now, which is what offers an expired
    /// sign-in a fresh login.
    func options(selected: String, failing: Bool, masked: Bool) -> [Option] {
        let choices = services.map { ClaudeSignIns.Choice(id: $0, identity: identities[$0], state: states[$0]) }
        let picked = ClaudeSignIns.pickable(choices, selected: selected)
        let listed = picked.map(\.id)
        let plain = picked.map { name(for: $0.id, among: listed, masked: masked) }
        // Two rows that still read alike are told apart by their item.
        var names = plain
        for index in names.indices where plain.filter({ $0 == plain[index] }).count > 1 && !picked[index].isDefault {
            names[index] += " · \(picked[index].id.suffix(8))"
        }
        return zip(picked, names).map { choice, name in
            let failed = choice.id == selected
                ? failing
                : (allReadings[choice.id].map { $0.error != nil && $0.snapshot == nil } ?? false)
            return Option(id: choice.id, name: name, state: choice.state, repair: ClaudeSignIns.repair(for: choice.state, failing: failed))
        }
    }

    /// `pickerLabel`, with the organization added only where two rows of the
    /// list itself share an address — a folded copy does not count.
    private func name(for service: String, among listed: [String], masked: Bool) -> String {
        guard !masked, let email = identities[service]?.email else { return choiceLabel(service, masked: masked) }
        let shared = listed.filter { identities[$0]?.email == email }.count > 1
        let organization = shared ? identities[service]?.organization.map { " · " + $0 } ?? "" : ""
        let marker = service == LocalCredentials.claudeService ? L10n.t(" (default)", "（默认）") : ""
        return email + organization + marker
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
