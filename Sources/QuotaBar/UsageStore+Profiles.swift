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
        if before?.claudeItem != after?.claudeItem { readAgain(.claude) }
        if before?.codexAccountID != after?.codexAccountID { readAgain(.codex) }
    }

    /// A profile named for where it sits: Personal, then Work, then numbered.
    func addProfile() {
        let names = [L10n.t("Personal", "个人"), L10n.t("Work", "工作")]
        let index = accountProfiles.count
        let name = index < names.count ? names[index] : L10n.t("Profile \(index + 1)", "账号组 \(index + 1)")
        updateProfiles { $0.append(AccountProfile(name: name)) }
    }

    func readClaudeSignIns() async {
        await claudeSignIns.read(cardService: claudeCardService)
    }

    private func readAgain(_ id: ProviderID) {
        guard isEnabled(id) else { return }
        states[id] = nil
        refresh(id)
        if id == .claude { Task { await readClaudeSignIns() } }
    }
}
