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

    public static func loginCommand(service: String) throws -> URL {
        guard let binary = ClaudeCodeRenewal.claudeBinary(),
              let directory = LocalCredentials.claudeConfigDir(service: service) else {
            throw ProviderError.notConfigured(hint: L10n.t("Add this account again.", "请重新添加这个账号。"))
        }
        let command = AppSupport.directory.appendingPathComponent("claude-login-\(UUID().uuidString).command")
        try Data(script(binary: binary, directory: directory).utf8).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return command
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

    static func script(binary: URL, directory: URL) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/zsh
        for qb_login_env_name in ${(k)parameters}; do
          if [[ "$qb_login_env_name" == CLAUDE* || "$qb_login_env_name" == ANTHROPIC_* ]]; then
            unset "$qb_login_env_name"
          fi
        done
        export CLAUDE_CONFIG_DIR=\(quote(directory.path))
        cd \(quote(directory.path)) || exit 1
        exec \(quote(binary.path)) auth login --claudeai

        """
    }
}
