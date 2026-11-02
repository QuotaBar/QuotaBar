import CryptoKit
import Foundation

/// Prepares an isolated, interactive Claude subscription login. No tokens
/// are copied; the owner completes authentication in Claude Code's browser.
public enum ClaudeAccountSetup {
    public struct Prepared {
        public let service: String
        public let command: URL
        public let directory: URL
    }

    public static func prepare(home: URL = FileManager.default.homeDirectoryForCurrentUser, binary: URL? = nil) throws -> Prepared {
        guard let binary = binary ?? ClaudeCodeRenewal.claudeBinary(home: home) else {
            throw ProviderError.notConfigured(hint: L10n.t("Install Claude Code before adding an account.", "请先安装 Claude Code，再添加账号。"))
        }
        let directory = home.appendingPathComponent(".claude-quotabar-\(UUID().uuidString.lowercased())", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = directory.appendingPathComponent("login.command")
        try Data(script(binary: binary, directory: directory).utf8).write(to: command, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let hash = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return Prepared(service: "Claude Code-credentials-\(hash)", command: command, directory: directory)
    }

    /// A login window for a sign-in that is already listed: a config dir's,
    /// or the default one, which Claude Code keeps when no `CLAUDE_CONFIG_DIR`
    /// is set — so for it the script sets none.
    public static func loginCommand(service: String) throws -> URL {
        guard let binary = ClaudeCodeRenewal.claudeBinary() else {
            throw ProviderError.notConfigured(hint: L10n.t("Install Claude Code before adding an account.", "请先安装 Claude Code，再添加账号。"))
        }
        var directory: URL?
        if service != LocalCredentials.claudeService {
            guard let found = LocalCredentials.claudeConfigDir(service: service) else {
                throw ProviderError.notConfigured(hint: L10n.t("Add this account again.", "请重新添加这个账号。"))
            }
            directory = found
        }
        let command = AppSupport.directory.appendingPathComponent("claude-login-\(UUID().uuidString).command")
        try Data(script(binary: binary, directory: directory).utf8).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return command
    }

    // MARK: What QuotaBar made

    /// The folders `prepare` makes start with this; nothing else is ever
    /// cleaned up, whatever a hidden sign-in's name points at.
    static let ownedPrefix = ".claude-quotabar-"

    /// The folder behind a sign-in, when QuotaBar made it. Nil for the default
    /// sign-in and for any config dir the owner made themself.
    public static func ownedDirectory(service: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let directory = LocalCredentials.claudeConfigDir(service: service, home: home),
              directory.lastPathComponent.hasPrefix(ownedPrefix),
              directory.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path
        else { return nil }
        return directory
    }

    /// Takes away what a sign-in QuotaBar made left on this Mac: its folder
    /// and its keychain item (through `security`, which Claude Code's items
    /// trust). False, touching nothing, for anything QuotaBar did not make.
    @discardableResult
    public static func discard(service: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let directory = ownedDirectory(service: service, home: home) else { return false }
        try? FileManager.default.removeItem(at: directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LocalCredentials.SecurityTool.path)
        process.arguments = ["delete-generic-password", "-s", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
        return true
    }

    public struct LoginStamp: Equatable, Sendable {
        public var tokenDigest: String?
        public var identity: ClaudeProvider.Identity?
        public init(tokenDigest: String? = nil, identity: ClaudeProvider.Identity? = nil) {
            self.tokenDigest = tokenDigest
            self.identity = identity
        }
        public func completed(since previous: LoginStamp) -> Bool {
            (tokenDigest != nil && tokenDigest != previous.tokenDigest) || (tokenDigest == nil && identity != nil && identity != previous.identity)
        }
    }

    /// A quiet, fresh local read. No network request and no keychain prompt.
    public static func loginStamp(service: String) -> LoginStamp {
        let lookup = LocalCredentials.readClaudeNow(service: service)
        let digest: String?
        if lookup.state == .available, let token = lookup.token, (lookup.expiresAt ?? .distantFuture) > Date() {
            digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        } else { digest = nil }
        return LoginStamp(tokenDigest: digest, identity: LocalCredentials.claudeConfigIdentity(service: service))
    }

    /// `directory` nil is the default sign-in: no config dir to name, and
    /// naming one would put the login in another item.
    static func script(binary: URL, directory: URL?) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let place = directory.map { directory in
            """
            export CLAUDE_CONFIG_DIR=\(quote(directory.path))
            cd \(quote(directory.path)) || exit 1
            """
        } ?? "cd \"$HOME\" || exit 1"
        return """
        #!/bin/zsh
        for qb_login_env_name in ${(k)parameters}; do
          if [[ "$qb_login_env_name" == CLAUDE* || "$qb_login_env_name" == ANTHROPIC_* ]]; then
            unset "$qb_login_env_name"
          fi
        done
        \(place)
        exec \(quote(binary.path)) auth login --claudeai

        """
    }
}
