import Foundation
import CommonCrypto
import Security

/// The sign-in of Claude's desktop app, for a Mac with no Claude Code: the
/// app is a browser underneath and keeps a claude.ai web session in its
/// Chromium cookie jar, sealed with the key in the keychain item
/// `Claude Safe Storage`. The same usage the web settings page shows is read
/// with it, so switching account in the app switches it here too.
///
/// A fallback only: Claude Code's own OAuth sign-in is read first, and this
/// answers when there is none. The session lives in memory for one request;
/// nothing is written anywhere, and nothing but the usage figures and the
/// account's email leaves this file.
public enum ClaudeDesktopSession {
    static var cookiesPath: String { NSHomeDirectory() + "/Library/Application Support/Claude/Cookies" }
    static let keychainService = "Claude Safe Storage"
    static let origin = "https://claude.ai"
    /// Cloudflare sits in front of claude.ai and wants a browser-looking agent
    /// next to the `cf_clearance` the app earned.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Claude/1.0 Chrome/130 Safari/537.36"

    /// The cookies the web app sends that matter to the usage reads.
    static let wanted = ["sessionKey", "lastActiveOrg", "cf_clearance", "__ssid", "anthropic-device-id", "routingHint"]

    /// Whether the desktop app is signed in here, without any keychain read.
    public static var exists: Bool {
        !SQLiteRead.rows(
            inFile: cookiesPath,
            query: "select 1 from cookies where host_key like '%claude.ai' and name = 'sessionKey' limit 1").isEmpty
    }

    struct Session: Sendable {
        let cookies: [String: String]
        var organization: String? { cookies["lastActiveOrg"] }
        var header: String { wanted.compactMap { name in cookies[name].map { "\(name)=\($0)" } }.joined(separator: "; ") }
    }

    enum Lookup: Sendable {
        case session(Session)
        case refused
        case missing
    }

    // MARK: Fetch

    public static func fetch() async throws -> UsageSnapshot {
        switch read(interactive: false) {
        case .refused:
            throw ProviderError.needsAuthorization(hint: authorizationHint)
        case .missing:
            throw ProviderError.notConfigured(hint: ProviderID.claude.setupHint)
        case let .session(session):
            return try await usage(session)
        }
    }

    static var authorizationHint: String {
        L10n.t(
            "The Claude app keeps its sign-in sealed with a keychain item, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "Claude 桌面应用的登录由钥匙串里的一项加密保存，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }

    static var expiredHint: String {
        L10n.t(
            "The Claude app's sign-in was not accepted. Open the Claude app once, signing in again if it asks.",
            "Claude 桌面应用的登录没有被接受。打开一次 Claude 桌面应用，如果它要求，重新登录。")
    }

    static func usage(_ session: Session) async throws -> UsageSnapshot {
        guard let org = session.organization else { throw ProviderError.notConfigured(hint: ProviderID.claude.setupHint) }
        let headers = [
            "Cookie": session.header, "User-Agent": userAgent, "Accept": "application/json",
        ]
        let response = try await HTTP.get(URL(string: "\(origin)/api/organizations/\(org)/usage")!, headers: headers)
        if response.status == 401 || response.status == 403 { throw ProviderError.sessionExpired(expiredHint) }
        var snapshot = try ClaudeProvider.parse(try response.requireOK().data)
        if snapshot.planName == nil { snapshot.planName = await plan(org: org, headers: headers) }
        snapshot.account = await email(for: session, headers: headers)
        return snapshot
    }

    /// "Max 5x" from the organization's tier, spelled the way Claude Code's
    /// item is.
    static func plan(org: String, headers: [String: String]) async -> String? {
        guard let response = try? await HTTP.get(URL(string: "\(origin)/api/organizations")!, headers: headers),
              response.status == 200,
              let list = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]],
              let tier = list.first(where: { $0["uuid"] as? String == org })?["rate_limit_tier"] as? String
        else { return nil }
        return LocalCredentials.claudePlan(["rateLimitTier": tier])
    }

    /// Per session, so the large bootstrap reply is asked for once per
    /// sign-in rather than once per refresh.
    private static let emails = EmailMemo()

    final class EmailMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: String] = [:]
        func email(for key: String) -> String? { lock.withLock { known[key] } }
        func store(_ email: String, for key: String) { lock.withLock { known = [key: email] } }
    }

    static func email(for session: Session, headers: [String: String]) async -> String? {
        let key = session.cookies["sessionKey"] ?? ""
        if let cached = emails.email(for: key) { return cached }
        guard let response = try? await HTTP.get(URL(string: "\(origin)/api/bootstrap")!, headers: headers),
              response.status == 200,
              let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let email = (root["account"] as? [String: Any])?["email_address"] as? String, !email.isEmpty
        else { return nil }
        emails.store(email, for: key)
        return email
    }

    // MARK: Cookies

    /// The keychain button's read, dialog allowed.
    @discardableResult
    public static func authorize() -> Bool {
        if case .session = read(interactive: true) { return true }
        return false
    }

    static func read(interactive: Bool) -> Lookup {
        let names = wanted.map { "'\($0)'" }.joined(separator: ",")
        let rows = SQLiteRead.rows(
            inFile: cookiesPath,
            query: "select name, hex(encrypted_value) from cookies where host_key like '%claude.ai' and name in (\(names))")
        guard !rows.isEmpty else { return .missing }
        let version = SQLiteRead.rows(inFile: cookiesPath, query: "select value from meta where key = 'version'")
            .first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
        let key: Data
        switch keys.key(interactive: interactive, read: readPassword) {
        case let .key(derived): key = derived
        case .refused: return .refused
        case .missing: return .missing
        }
        var cookies: [String: String] = [:]
        for row in rows {
            guard let name = row[0], let hex = row[1], let sealed = data(fromHex: hex),
                  let value = decrypt(sealed, key: key, hashPrefixed: version >= 24)
            else { continue }
            cookies[name] = value
        }
        return cookies["sessionKey"] == nil ? .missing : .session(Session(cookies: cookies))
    }

    static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Chromium's macOS cookie seal, the one `GrokBot` opens as well; from
    /// database version 24 the plain text starts with a 32-byte hash of the
    /// host.
    static func decrypt(_ sealed: Data, key: Data, hashPrefixed: Bool) -> String? {
        guard sealed.starts(with: Array("v10".utf8)) else { return nil }
        let body = sealed.dropFirst(3)
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
        var plain = out.prefix(written)
        if hashPrefixed { plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: Keychain

    enum KeyAnswer { case key(Data), refused, missing }

    private static let keys = KeyMemo()

    /// The key does not change while the Claude app stays installed: read once,
    /// kept for the life of the process. A refusal is kept for a minute so a
    /// refresh timer cannot knock on the keychain every cycle.
    final class KeyMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var key: Data?
        private var refusedAt: Date = .distantPast

        func key(interactive: Bool, read: (Bool) -> GrokBot.KeychainRead) -> KeyAnswer {
            lock.lock(); defer { lock.unlock() }
            if let key { return .key(key) }
            if !interactive, Date().timeIntervalSince(refusedAt) < 60 { return .refused }
            switch read(interactive) {
            case let .password(password):
                guard let derived = GrokBot.deriveKey(password: password) else { return .missing }
                key = derived
                return .key(derived)
            case .refused:
                refusedAt = Date()
                return .refused
            case .missing:
                return .missing
            }
        }
    }

    private static func readPassword(interactive: Bool) -> GrokBot.KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
}
