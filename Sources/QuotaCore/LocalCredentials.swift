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

    // MARK: OpenCode (~/.local/share/opencode/auth.json written by the opencode CLI)

    /// The opencode CLI stores provider API keys in the clear, keyed by
    /// provider slug. `opencode-go` is the coding plan QuotaBar tracks.
    public static func openCodeGoKey() -> String? {
        readOpenCodeKey("opencode-go")
    }

    static func readOpenCodeKey(_ slug: String) -> String? {
        let candidates = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent(".config/opencode/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = root[slug] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty
            else { continue }
            return key
        }
        return nil
    }

    // MARK: Cursor (Cursor.app → state.vscdb signed-in session)

    public struct CursorSession: Sendable {
        /// The value cursor.com expects in its WorkosCursorSessionToken cookie:
        /// the user id and the JWT joined by "::", url-encoded at send time.
        public let sessionCookie: String
        public let email: String?
    }

    /// Reads the session Cursor.app already established, from the SQLite
    /// key/value store it keeps under Application Support. No keychain, no
    /// decryption — the values are stored in the clear.
    ///
    /// The cookie cursor.com wants is not the bare JWT but `sub::JWT`; the
    /// bare token is rejected. `sub` is a claim inside the JWT, so the two
    /// halves come from one value.
    public static func cursorSession() -> CursorSession? {
        let db = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
        guard let token = SQLiteRead.firstString(
            inFile: db,
            query: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/accessToken"),
            !token.isEmpty
        else { return nil }
        let email = SQLiteRead.firstString(
            inFile: db,
            query: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/cachedEmail")
        return makeCursorSession(accessToken: token, email: email)
    }

    /// Pure assembly step, split out so it can be tested without a database:
    /// pulls `sub` from the JWT and pairs it with the token.
    public static func makeCursorSession(accessToken: String, email: String?) -> CursorSession? {
        guard let sub = jwtClaim(accessToken, "sub"), !sub.isEmpty else { return nil }
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CursorSession(
            sessionCookie: "\(sub)::\(accessToken)",
            email: (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil)
    }

    /// Decodes a single string claim from a JWT payload without verifying the
    /// signature — this only reads a token the user's own app already trusts.
    static func jwtClaim(_ jwt: String, _ name: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore base64 padding stripped by the JWT encoding.
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[name] as? String
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
