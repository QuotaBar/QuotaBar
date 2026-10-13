import SwiftUI
import AppKit
import QuotaCore

/// Work and personal (#8): the profile in use decides which Claude sign-in
/// and Codex account the cards read. Switching reads both again from
/// nothing, so a card never shows one account's figures under another's.
extension UsageStore {
    static let profileProviders: [ProviderID] = [.claude, .codex]

    var accountProfiles: [AccountProfile] { experience.accountProfiles }
    var activeProfile: AccountProfile? { experience.activeProfile }

    /// The Claude item the card reads.
    var claudeCardService: String { experience.claudeItem }
    /// The Codex account the card reads: the one a profile or the arrow
    /// chose, else whichever the CLI is signed in as.
    var codexCardAccount: String? { experience.codexAccountPin ?? codexAccounts.activeID }

    func setActiveProfile(_ id: String) {
        guard activeProfile?.id != id else { return }
        updateProfiles({ _ in }, activating: id)
        if let name = activeProfile?.name { flashNotice(L10n.t("Showing \(name)", "已切换到「\(name)」")) }
    }

    /// The arrow on the Claude card: read another Claude sign-in. Nothing of
    /// Codex's changes; with a profile in use the profile's own sign-in is
    /// what is edited, else the choice is kept on its own.
    func useClaudeSignIn(_ service: String) {
        guard service != claudeCardService else { return }
        let item: String? = service == LocalCredentials.claudeService ? nil : service
        changeAccounts {
            if let id = activeProfile?.id {
                updateProfiles { list in
                    if let index = list.firstIndex(where: { $0.id == id }) { list[index].claudeService = item }
                }
            } else {
                updateExperience { $0.claudeSignInChoice = item }
            }
        }
        flashNotice(L10n.t("Claude is showing \(claudeSignIns.pickerLabel(service, masked: isPrivacyMasked))",
                           "Claude 已切换到 \(claudeSignIns.pickerLabel(service, masked: isPrivacyMasked))"))
    }

    /// The arrow on the Codex card: read another kept Codex account, without
    /// signing the CLI in as it. Claude is left alone.
    func useCodexAccount(_ id: String) {
        guard id != codexCardAccount else { return }
        // The account the CLI is on is "follow the CLI", not a pin to it.
        let pin: String? = id == codexAccounts.activeID ? nil : id
        changeAccounts {
            if let profile = activeProfile?.id {
                updateProfiles { list in
                    if let index = list.firstIndex(where: { $0.id == profile }) { list[index].codexAccountID = pin }
                }
            } else {
                updateExperience { $0.codexAccountChoice = pin }
            }
        }
        if let account = codexAccounts.saved.first(where: { $0.id == id }) {
            flashNotice(L10n.t("Codex is showing \(codexAccounts.label(account, masked: isPrivacyMasked))",
                               "Codex 已切换到 \(codexAccounts.label(account, masked: isPrivacyMasked))"))
        }
    }

    /// Runs a change to what the cards read, then reads whichever card's
    /// account moved, each from nothing.
    private func changeAccounts(_ change: () -> Void) {
        let claudeBefore = claudeCardService
        let codexBefore = codexCardAccount
        change()
        if claudeBefore != claudeCardService { switchClaude(from: claudeBefore) }
        if codexBefore != codexCardAccount, isEnabled(.codex) {
            switchAccount(.codex, showing: lastReading(.codex))
        }
    }

    /// Edits the profiles; a change to what the cards read reads them again.
    func updateProfiles(_ body: (inout [AccountProfile]) -> Void, activating id: String? = nil) {
        changeAccounts {
            updateExperience { prefs in
                body(&prefs.accountProfiles)
                if let id { prefs.activeProfileID = id }
                if !prefs.accountProfiles.contains(where: { $0.id == prefs.activeProfileID }) {
                    prefs.activeProfileID = prefs.accountProfiles.first?.id
                }
            }
        }
    }

    /// Which account a card is reading, for `accountReadings`: the Claude
    /// item, or the Codex account (the CLI's own when nothing picked one).
    func profileAccountKey(_ id: ProviderID) -> String {
        switch id {
        case .claude: return "claude|\(claudeCardService)|\(experience.claudeSource.rawValue)"
        case .codex: return "codex|\(codexCardAccount ?? "cli")"
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
            if let account = codexCardAccount {
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

    func removeClaudeSignIn(_ service: String) {
        guard service != LocalCredentials.claudeService else { return }
        claudeLoginTasks.removeValue(forKey: service)?.cancel()
        claudeLoginsPending.remove(service)
        changeAccounts { updateExperience { $0.forgetClaudeSignIn(service) } }
        claudeSignIns.forget(service)
        accountReadings = accountReadings.filter { !$0.key.hasPrefix("claude|\(service)|") }
        Task { await readClaudeSignIns(force: true) }
        flashNotice(L10n.t("Removed from QuotaBar", "已从 QuotaBar 移除"))
    }

    func reconnectClaudeAccount(_ service: String) -> String? {
        do {
            let before = ClaudeAccountSetup.loginStamp(service: service)
            let command = try ClaudeAccountSetup.loginCommand(service: service)
            guard NSWorkspace.shared.open(command) else { return L10n.t("Could not open the login window.", "无法打开登录窗口。") }
            watchClaudeLogin(service, before: before)
            return nil
        } catch { return error.localizedDescription }
    }

    @discardableResult
    func addClaudeAccount(name: String = "", replacing oldService: String? = nil) -> String? {
        do {
            let prepared = try ClaudeAccountSetup.prepare()
            updateExperience { prefs in
                prefs.claudeAccountNames[prepared.service] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard NSWorkspace.shared.open(prepared.command) else {
                return L10n.t("Could not open the login window. Try again from Settings.", "无法打开登录窗口，请在设置中重试。")
            }
            if let oldService { removeClaudeSignIn(oldService) }
            watchClaudeLogin(prepared.service, before: .init())
            Task { await readClaudeSignIns(force: true) }
            return nil
        } catch { return error.localizedDescription }
    }

    private func watchClaudeLogin(_ service: String, before: ClaudeAccountSetup.LoginStamp) {
        claudeLoginTasks.removeValue(forKey: service)?.cancel()
        claudeLoginsPending.insert(service)
        claudeLoginTasks[service] = Task { [weak self] in
            // Poll only while an explicitly opened login is in progress.
            for _ in 0..<300 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                let stamp = await Task.detached(priority: .utility) { ClaudeAccountSetup.loginStamp(service: service) }.value
                guard !Task.isCancelled, let self else { return }
                if stamp.completed(since: before) {
                    self.accountReadings = self.accountReadings.filter { !$0.key.hasPrefix("claude|\(service)|") }
                    self.claudeSignIns.invalidateReading(service)
                    LocalCredentials.invalidateClaudeToken()
                    if self.claudeCardService == service { self.switchAccount(.claude, showing: nil) }
                    await self.readClaudeSignIns(force: true)
                    self.refreshConfigured()
                    self.claudeLoginsPending.remove(service)
                    self.claudeLoginTasks[service] = nil
                    self.flashNotice(L10n.t("Claude login updated", "Claude 登录已更新"))
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.claudeLoginsPending.remove(service)
            self.claudeLoginTasks[service] = nil
        }
    }

    func readClaudeSignIns(force: Bool = false) async {
        await claudeSignIns.read(cardService: claudeCardService, force: force, hidden: experience.hiddenClaudeSignIns, names: experience.claudeAccountNames)
    }
}
