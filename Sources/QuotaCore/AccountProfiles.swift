import Foundation

/// Work and personal (#8): a named set of accounts — one Claude Code
/// sign-in and one Codex account. The profile in use decides which account
/// the Claude and Codex cards read, and with them the menu bar, the island,
/// the dock and the desktop cards. Choosing one changes what is read, never
/// what the CLIs are signed in as.
public struct AccountProfile: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// A Claude Code keychain item: the default one, or a config dir's
    /// (`Claude Code-credentials-<hash>`). nil is the default.
    public var claudeService: String?
    /// A Codex account QuotaBar keeps (`CodexAccount.id`). nil is whichever
    /// the CLI is signed in as.
    public var codexAccountID: String?

    public init(id: String = UUID().uuidString, name: String, claudeService: String? = nil, codexAccountID: String? = nil) {
        self.id = id
        self.name = name
        self.claudeService = claudeService
        self.codexAccountID = codexAccountID
    }

    /// The Claude item this profile reads, the default spelled out.
    public var claudeItem: String { claudeService ?? LocalCredentials.claudeService }
}

extension ExperiencePrefs {
    /// The profile the cards read, while there is more than one to choose
    /// between; nil reads the CLIs' own sign-ins, as before profiles.
    public var activeProfile: AccountProfile? {
        guard accountProfiles.count > 1 else { return nil }
        return accountProfiles.first { $0.id == activeProfileID } ?? accountProfiles.first
    }
}
