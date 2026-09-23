import SwiftUI
import QuotaCore

/// The Codex accounts QuotaBar keeps (issue #6): which there are, which one
/// the CLI is signed in as, what each kept one has left, and switching.
///
/// The account the CLI is signed in as is the Codex card itself, read like
/// any provider; this is everything else. Kept apart from `UsageSnapshot` —
/// the model the iPhone app and iCloud share — so the other accounts stay on
/// the Mac that holds their sign-ins.
@MainActor
final class CodexAccountsModel: ObservableObject {
    struct Reading {
        var snapshot: UsageSnapshot?
        var error: String?
    }

    @Published private(set) var saved: [CodexAccount] = []
    @Published private(set) var activeID: String?
    @Published private(set) var readings: [String: Reading] = [:]
    /// A switch or a save in progress; the buttons wait for it.
    @Published private(set) var working = false

    let vault: CodexAccountVault

    init(vault: CodexAccountVault = .shared) {
        self.vault = vault
    }

    /// Kept accounts other than the one the CLI is signed in as.
    var others: [CodexAccount] { saved.filter { $0.id != activeID } }

    var isActiveSaved: Bool {
        guard let activeID else { return false }
        return saved.contains { $0.id == activeID }
    }

    func reload() async {
        saved = await vault.accounts()
        activeID = await vault.live()?.accountID
    }

    /// Every kept account but the active one, read with its own tokens. A
    /// failure keeps the last good reading beside the reason.
    func readOthers() async {
        await reload()
        let ids = others.map(\.id)
        guard !ids.isEmpty else {
            readings = [:]
            return
        }
        let vault = vault
        var fresh: [String: Reading] = [:]
        await withTaskGroup(of: (String, Reading).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        let file = try await vault.credentials(for: id)
                        let snapshot = try await CodexProvider.usage(accessToken: file.accessToken, accountID: file.accountID)
                        return (id, Reading(snapshot: snapshot))
                    } catch {
                        return (id, Reading(snapshot: nil, error: error.localizedDescription))
                    }
                }
            }
            for await (id, reading) in group {
                var reading = reading
                if reading.snapshot == nil { reading.snapshot = readings[id]?.snapshot }
                fresh[id] = reading
            }
        }
        readings = fresh
    }

    @discardableResult
    func saveCurrent() async throws -> CodexAccount {
        working = true
        defer { working = false }
        let account = try await vault.saveCurrent()
        await reload()
        return account
    }

    func remove(_ id: String) async {
        await vault.remove(id)
        readings[id] = nil
        await reload()
    }

    func switchTo(_ id: String) async throws {
        working = true
        defer { working = false }
        try await vault.switchTo(id)
        await reload()
    }

    /// Off-screen renders (`--snapshot`): accounts to draw, without the keychain.
    func seedForPreview(saved: [CodexAccount], activeID: String?, readings: [String: Reading]) {
        self.saved = saved
        self.activeID = activeID
        self.readings = readings
    }

    /// "a@example.com", or which account it is when the address is not to be shown.
    func label(_ account: CodexAccount, masked: Bool) -> String {
        guard !masked, let email = account.email, !email.isEmpty else {
            let index = (saved.firstIndex { $0.id == account.id } ?? 0) + 1
            return L10n.t("Account \(index)", "账号 \(index)")
        }
        return email
    }
}

// MARK: - Store actions

extension UsageStore {
    func switchCodexAccount(_ id: String) {
        Task {
            do {
                try await codexAccounts.switchTo(id)
                refresh(.codex)
                let name = codexAccounts.saved.first { $0.id == id }.map { codexAccounts.label($0, masked: isPrivacyMasked) } ?? "Codex"
                flashNotice(L10n.t("Switched to \(name)", "已切换到 \(name)"))
                codexSwitchNotice = L10n.t(
                    "Codex now signs in as \(name). Codex sessions already running keep the old account until restarted.",
                    "Codex 已切换到 \(name)。已经在运行的 Codex 会话要重启后才会用新账号。")
            } catch {
                codexSwitchNotice = error.localizedDescription
            }
        }
    }

    func saveCurrentCodexAccount() {
        Task {
            do {
                let account = try await codexAccounts.saveCurrent()
                let name = codexAccounts.label(account, masked: isPrivacyMasked)
                codexSwitchNotice = L10n.t("Saved \(name).", "已保存 \(name)。")
            } catch {
                codexSwitchNotice = error.localizedDescription
            }
        }
    }

    func removeCodexAccount(_ id: String) {
        Task { await codexAccounts.remove(id) }
    }
}
