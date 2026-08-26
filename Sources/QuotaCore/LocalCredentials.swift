import Foundation
import Security

/// Readers for credentials stored locally by provider CLIs (no passwords, reuse existing sessions).
public enum LocalCredentials {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `SecItemCopyMatching` blocks while macOS asks the user to authorize
    /// keychain access, so the Claude lookup is memoized briefly. Short enough
    /// that a re-login is picked up promptly, long enough that a refresh cycle
    /// and a settings render do not each trigger their own prompt.
    private static let keychainTTL: TimeInterval = 60
    private static let memo = TokenMemo()

    final class TokenMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String??
        private var storedAt: Date = .distantPast

        func cached(ttl: TimeInterval) -> String?? {
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(storedAt) < ttl else { return nil }
            return value
        }

        func store(_ token: String?) {
            lock.lock()
            value = token
            storedAt = Date()
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            storedAt = .distantPast
            lock.unlock()
        }
    }

    /// Forces the next Claude lookup to go back to the keychain.
    public static func invalidateClaudeToken() {
        memo.invalidate()
    }

    // MARK: Codex (~/.codex/auth.json)

    public struct CodexAuth: Sendable {
        public let accessToken: String
        public let accountId: String?
    }

    public static func codexAuth() -> CodexAuth? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else { return nil }
        return CodexAuth(accessToken: accessToken, accountId: tokens["account_id"] as? String)
    }

    // MARK: Claude (Keychain item written by Claude Code)

    public static func claudeOAuthToken() -> String? {
        if let cached = memo.cached(ttl: keychainTTL) { return cached }
        let token = readClaudeOAuthToken()
        memo.store(token)
        return token
    }

    private static func readClaudeOAuthToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty
        {
            return token
        }
        return root["accessToken"] as? String
    }

    // MARK: Gemini (~/.gemini/oauth_creds.json written by Gemini CLI)

    public static func geminiAccessToken() -> String? {
        let url = home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: Grok (~/.grok/auth.json written by the grok CLI)

    public static func grokAccessToken() -> String? {
        let candidates = [
            home.appendingPathComponent(".grok/auth.json"),
            home.appendingPathComponent(".config/grok/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for key in ["access_token", "accessToken", "token", "api_key"] {
                if let token = root[key] as? String, !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }
}
