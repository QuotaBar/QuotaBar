import CommonCrypto
import Foundation
import Security

// MARK: - Qoder's sign-in, read from the desktop app

/// Qoder (com.qoder.app) keeps its sign-in in `auth.v1.dat`, sealed with
/// Electron `safeStorage` — the same Chromium scheme Grok Bot uses: "v10",
/// then AES-128-CBC under PBKDF2-SHA1(the keychain password, "saltysalt",
/// 1003 rounds), IV sixteen spaces, the password in the login keychain under
/// "Qoder App Safe Storage". macOS asks before another app may read that key,
/// so the one read is behind the "Allow keychain access" button, like Grok
/// and Claude.
///
/// The decrypted file carries the account (`user.id`, `name`, `email`) and the
/// access `token`. That token is a plain bearer for Qoder's own backend —
/// `GET center.qoder.sh/api/v2/user/plan` and `/api/v3/user/status` take
/// `Authorization: Bearer <token>` directly — so QuotaBar reads the plan and
/// quota while Qoder is closed, with no request signing. The token lasts about
/// a billing cycle and Qoder refreshes it whenever it runs; an expired one is
/// reported as a sign-in to renew by opening Qoder.
public struct QoderSignIn: Sendable, Equatable {
    public let token: String
    public let accountId: String?
    public let name: String?
    public let email: String?
}

public enum QoderApp {
    // MARK: Where the app keeps things

    /// The app's data directory. The stable channel is `com.qoder.app.stable`;
    /// the plain id is tried too in case a build uses it.
    static var supportDirectories: [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return ["com.qoder.app.stable", "com.qoder.app"].map { base.appendingPathComponent($0) }
    }

    static var authFiles: [URL] {
        supportDirectories.map { $0.appendingPathComponent("auth.v1.dat") }
    }

    public static func isInstalled() -> Bool {
        authFiles.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Session state (mirrors Grok's)

    public enum SessionState: Sendable, Equatable {
        case available
        /// Signed in, but the safeStorage key needs the user's say-so first.
        case needsAuthorization
        /// Not installed, or not signed in.
        case missing
    }

    struct Lookup: Sendable {
        let state: SessionState
        var signIn: QoderSignIn? = nil
    }

    /// Never prompts. For the settings row: whether the button is needed.
    public static func sessionState() -> SessionState {
        lookup(interactive: false).state
    }

    /// For `--credentials`: what a quiet lookup found, never the secret.
    public static func sessionDescription() -> String {
        switch lookup(interactive: false).state {
        case .missing: return "missing"
        case .needsAuthorization: return "needs authorization (press Allow keychain access in Settings › Qoder)"
        case .available: return "available (Qoder's own sign-in)"
        }
    }

    /// The one place the keychain dialog is allowed, from a button. Blocks
    /// the calling thread while the dialog is up.
    @discardableResult
    public static func authorize() -> Bool {
        lookup(interactive: true).state == .available
    }

    public static func authorizeAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: authorize())
            }
        }
    }

    /// The account Qoder is signed in to on this Mac.
    public static func signIn() -> QoderSignIn? {
        lookup(interactive: false).signIn
    }

    static func lookup(
        interactive: Bool,
        files: [URL] = authFiles,
        read: (String, Bool) -> KeychainRead = readPassword) -> Lookup
    {
        guard let data = files.compactMap({ try? Data(contentsOf: $0) }).first(where: { $0.starts(with: Array("v10".utf8)) }) else {
            return Lookup(state: .missing)
        }
        // Electron names the safeStorage item after the app, and Qoder has
        // shipped under more than one name; the key that decrypts the file is
        // the account's, so each candidate is tried until one opens it.
        var refused = false
        for service in keychainServices {
            switch memo.key(service: service, interactive: interactive, read: read) {
            case let .key(key):
                if let plain = decrypt(data, key: key), let signIn = parse(plain) {
                    return Lookup(state: .available, signIn: signIn)
                }
            case .refused: refused = true
            case .missing: break
            }
        }
        return Lookup(state: refused ? .needsAuthorization : .missing)
    }

    /// The access token and account, wherever they sit in the decrypted JSON.
    /// Read by field name rather than a fixed path, so a moved key still
    /// resolves; the token is required.
    static func parse(_ plain: Data) -> QoderSignIn? {
        guard let root = try? JSONSerialization.jsonObject(with: plain) else { return nil }
        func first(_ keys: [String]) -> String? {
            for key in keys { if let v = ProviderJSON.string(ProviderJSON.first([key], in: root)) { return v } }
            return nil
        }
        guard let token = first(["token", "accessToken", "access_token"]) else { return nil }
        let user = (root as? [String: Any])?["user"] as? [String: Any]
        func userField(_ keys: [String]) -> String? {
            guard let user else { return nil }
            for key in keys { if let v = ProviderJSON.string(user[key]) { return v } }
            return nil
        }
        return QoderSignIn(
            token: token,
            accountId: userField(["id", "uid", "userId"]),
            name: userField(["name", "nickname", "displayName"]),
            email: userField(["email", "mail"]))
    }

    // MARK: Electron safeStorage (same scheme as GrokBot)

    static func deriveKey(password: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        return status == kCCSuccess ? key : nil
    }

    static func decrypt(_ data: Data, key: Data) -> Data? {
        guard data.starts(with: Array("v10".utf8)) else { return nil }
        let body = data.dropFirst(3)
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            body.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv,
                        inBytes.baseAddress, body.count,
                        outBytes.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    // MARK: Keychain (same shape as GrokBot)

    enum KeychainRead: Sendable {
        case password(Data)
        case refused
        case missing
    }

    /// The safeStorage service names Qoder has used, newest layout first.
    static let keychainServices = ["Qoder App Safe Storage", "Qoder Safe Storage"]

    static func readPassword(_ service: String, _ interactive: Bool) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status: OSStatus = interactive
            ? LocalCredentials.KeychainUI.withPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
            : LocalCredentials.KeychainUI.withoutPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { return .missing }
            return .password(data)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .refused
        default:
            return .missing
        }
    }

    enum KeyAnswer { case key(Data), refused, missing }

    /// `QuotaBar --qoder-keychain`: the raw answer to the read the button
    /// makes, dialog allowed, for when the button seems to do nothing.
    public static func probeKeychain() -> String {
        var lines: [String] = []
        for service in keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = LocalCredentials.KeychainUI.withPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
            let found = (result as? Data).map { "\($0.count) bytes" } ?? "nothing"
            lines.append("[\(service)] status: \(status) \(message) · read: \(found)")
        }
        return lines.joined(separator: "\n")
    }

    /// The key never changes while Qoder stays installed, so once read it is
    /// kept for the life of the process. A refusal is kept for a minute so a
    /// refresh timer cannot knock on the keychain every cycle.
    private static let memo = KeyMemo()

    final class KeyMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: Data] = [:]
        private var refusedAt: Date = .distantPast

        func key(service: String, interactive: Bool, read: (String, Bool) -> KeychainRead) -> KeyAnswer {
            lock.lock(); defer { lock.unlock() }
            if let key = keys[service] { return .key(key) }
            if !interactive, Date().timeIntervalSince(refusedAt) < 60 { return .refused }
            switch read(service, interactive) {
            case let .password(password):
                guard let derived = QoderApp.deriveKey(password: password) else { return .missing }
                keys[service] = derived
                return .key(derived)
            case .refused:
                refusedAt = Date()
                return .refused
            case .missing:
                return .missing
            }
        }

        func reset() {
            lock.lock(); keys = [:]; refusedAt = .distantPast; lock.unlock()
        }
    }

    static func resetKeyMemo() {
        memo.reset()
    }

    public static var authorizationHint: String {
        L10n.t(
            "Qoder keeps its sign-in encrypted with a key in the keychain, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "Qoder 的登录用钥匙串里的密钥加密，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }
}
