import SwiftUI
import QuotaCore

/// Work and personal (#8): the profile in use decides which Claude sign-in
/// and Codex account the cards read. Switching reads both again from
/// nothing, so a card never shows one account's figures under another's.
extension UsageStore {
    static let profileProviders: [ProviderID] = [.claude, .codex]

    var accountProfiles: [AccountProfile] { experience.accountProfiles }
    var activeProfile: AccountProfile? { experience.activeProfile }

    /// The Claude item the card reads.
    var claudeCardService: String { activeProfile?.claudeItem ?? LocalCredentials.claudeService }

    func setActiveProfile(_ id: String) {
        guard activeProfile?.id != id else { return }
        updateProfiles({ _ in }, activating: id)
        if let name = activeProfile?.name { flashNotice(L10n.t("Showing \(name)", "已切换到「\(name)」")) }
    }

    /// Edits the profiles; a change to what the cards read reads them again.
    func updateProfiles(_ body: (inout [AccountProfile]) -> Void, activating id: String? = nil) {
        let before = activeProfile
        updateExperience { prefs in
            body(&prefs.accountProfiles)
            if let id { prefs.activeProfileID = id }
            if !prefs.accountProfiles.contains(where: { $0.id == prefs.activeProfileID }) {
                prefs.activeProfileID = prefs.accountProfiles.first?.id
            }
        }
        let after = activeProfile
        if before?.claudeItem != after?.claudeItem {
            switchClaude(from: before?.claudeItem ?? LocalCredentials.claudeService)
        }
        if before?.codexAccountID != after?.codexAccountID, isEnabled(.codex) {
            switchAccount(.codex, showing: lastReading(.codex))
        }
    }

    /// Which account a card is reading, for `accountReadings`: the Claude
    /// item, or the Codex account (the CLI's own when the profile leaves it).
    func profileAccountKey(_ id: ProviderID) -> String {
        switch id {
        case .claude: return "claude|\(claudeCardService)"
        case .codex: return "codex|\(activeProfile?.codexAccountID ?? codexAccounts.activeID ?? "cli")"
        default: return id.rawValue
        }
    }

    /// The newest figures already in hand for the account a card now reads:
    /// from its own last turn on the card, or from the list under the arrow,
    /// which reads the other accounts on every refresh.
    func lastReading(_ id: ProviderID) -> UsageSnapshot? {
        var candidates = [accountReadings[profileAccountKey(id)]]
        switch id {
        case .claude:
            candidates.append(claudeSignIns.others.first { $0.id == claudeCardService }?.snapshot)
        case .codex:
            if let account = activeProfile?.codexAccountID ?? codexAccounts.activeID {
                candidates.append(codexAccounts.readings[account]?.snapshot)
            }
        default:
            break
        }
        return candidates.compactMap { $0 }.max { $0.fetchedAt < $1.fetchedAt }
    }

    /// The card and the list under its arrow trade places, with what each
    /// last read; the list is not read again for it.
    private func switchClaude(from previous: String) {
        guard isEnabled(.claude) else { return }
        let last = lastReading(.claude)
        claudeSignIns.moveCard(to: claudeCardService, from: previous, previousSnapshot: reported[.claude])
        switchAccount(.claude, showing: last)
    }

    /// A profile named for where it sits: Personal, then Work, then numbered.
    func addProfile() {
        let names = [L10n.t("Personal", "个人"), L10n.t("Work", "工作")]
        let index = accountProfiles.count
        let name = index < names.count ? names[index] : L10n.t("Profile \(index + 1)", "账号组 \(index + 1)")
        updateProfiles { $0.append(AccountProfile(name: name)) }
    }

    func readClaudeSignIns(force: Bool = false) async {
        await claudeSignIns.read(cardService: claudeCardService, force: force)
    }
}
