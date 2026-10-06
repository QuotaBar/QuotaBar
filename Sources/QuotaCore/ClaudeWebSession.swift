import Foundation
import CommonCrypto
import Security

/// A claude.ai web sign-in already on this Mac, for when Claude Code has none:
/// the Claude desktop app's, or a browser's. All of them are the same cookie,
/// `sessionKey`, kept in different jars — the app's and the Chromium
/// browsers' sealed with a key in the keychain ("<name> Safe Storage"),
/// Firefox's in the clear, Safari's in a binary file macOS guards. The usage
/// the web settings page shows is read with it, so switching account in the
/// app or the browser switches it here too.
///
/// A fallback: Claude Code's own OAuth sign-in comes first unless the owner
/// pins the web. The session lives in memory for one request; nothing is
/// written anywhere, and nothing but the usage figures and the account's
/// email leaves this file.
public enum ClaudeWebSession {
    static let origin = "https://claude.ai"
    /// Cloudflare sits in front of claude.ai and wants a browser-looking agent
    /// next to the `cf_clearance` the browser earned.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Claude/1.0 Chrome/130 Safari/537.36"
    /// The cookies the web app sends that matter to the usage reads.
    static let wanted = ["sessionKey", "lastActiveOrg", "cf_clearance", "__ssid", "anthropic-device-id", "routingHint"]

    // MARK: Where a sign-in can be kept

    enum Jar: Sendable, Equatable {
        /// Chromium's cookie file, and the keychain item that seals it.
        case chromium(path: String, service: String)
        case firefox(path: String)
        case safari(path: String)
    }

    struct Source: Sendable, Equatable {
        let name: String
        let jar: Jar
    }

    private static var support: String { NSHomeDirectory() + "/Library/Application Support" }

    /// Browsers on Chromium, as the folder under Application Support and the
    /// name of the keychain item that holds their cookie key.
    static let chromiumBrowsers: [(name: String, folder: String, service: String)] = [
        ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
        ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
        ("Arc", "Arc/User Data", "Arc Safe Storage"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
        ("Chromium", "Chromium", "Chromium Safe Storage"),
    ]

    /// Every jar on this Mac that holds a claude.ai `sessionKey`, the Claude
    /// app first. Memoized for a minute: it looks at files and databases.
    static func sources() -> [Source] {
        if let cached = sourcesMemo.cached() { return cached }
        let found = scan()
        sourcesMemo.store(found)
        return found
    }

    /// Drops the memo; the "test" button asks the files, not a minute-old answer.
    public static func invalidate() { sourcesMemo.store(nil) }

    public static var exists: Bool { !sources().isEmpty }

    /// "Claude app, Chrome", for Settings.
    public static var detectedNames: [String] {
        var seen: [String] = []
        for source in sources() where !seen.contains(source.name) { seen.append(source.name) }
        return seen
    }

    private static let sourcesMemo = SourcesMemo()

    final class SourcesMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Source]?
        private var at = Date.distantPast
        func cached() -> [Source]? {
            lock.withLock { Date().timeIntervalSince(at) < 60 ? value : nil }
        }
        func store(_ sources: [Source]?) {
            lock.withLock { value = sources; at = sources == nil ? .distantPast : Date() }
        }
    }

    private static func scan() -> [Source] {
        var out: [Source] = []
        let fm = FileManager.default
        let app = support + "/Claude/Cookies"
        if hasSession(.chromium(path: app, service: "Claude Safe Storage")) {
            out.append(Source(name: L10n.t("Claude app", "Claude 桌面应用"), jar: .chromium(path: app, service: "Claude Safe Storage")))
        }
        for browser in chromiumBrowsers {
            let base = support + "/" + browser.folder
            let profiles = ((try? fm.contentsOfDirectory(atPath: base)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            for profile in profiles {
                for file in ["/Network/Cookies", "/Cookies"] {
                    let path = "\(base)/\(profile)\(file)"
                    let jar = Jar.chromium(path: path, service: browser.service)
                    if fm.fileExists(atPath: path), hasSession(jar) {
                        out.append(Source(name: browser.name, jar: jar))
                        break
                    }
                }
            }
        }
        let firefox = support + "/Firefox/Profiles"
        for profile in ((try? fm.contentsOfDirectory(atPath: firefox)) ?? []).sorted() {
            let jar = Jar.firefox(path: "\(firefox)/\(profile)/cookies.sqlite")
            if hasSession(jar) { out.append(Source(name: "Firefox", jar: jar)) }
        }
        for path in [NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies",
                     NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"] {
            let jar = Jar.safari(path: path)
            if hasSession(jar) { out.append(Source(name: "Safari", jar: jar)); break }
        }
        return out
    }

    /// Whether a jar holds the cookie, which needs no key.
    private static func hasSession(_ jar: Jar) -> Bool {
        switch jar {
        case let .chromium(path, _):
            return !withCopy(of: path) {
                SQLiteRead.rows(inFile: $0, query: "select 1 from cookies where host_key like '%claude.ai' and name = 'sessionKey' limit 1", immutable: false)
            }.isEmpty
        case let .firefox(path):
            return !withCopy(of: path) {
                SQLiteRead.rows(inFile: $0, query: "select 1 from moz_cookies where host like '%claude.ai' and name = 'sessionKey' limit 1", immutable: false)
            }.isEmpty
        case let .safari(path):
            return safariCookies(at: path)["sessionKey"] != nil
        }
    }

    /// A browser keeps its cookie file open, often with a `-wal` beside it
    /// that holds the newest rows; both are copied so what is read is what the
    /// browser sees, and the original is never touched.
    static func withCopy<T>(of path: String, _ body: (String) -> [T]) -> [T] {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) else { return [] }
        let dir = fm.temporaryDirectory.appendingPathComponent("quotabar-cookies-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return [] }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("cookies.db")
        guard (try? fm.copyItem(atPath: path, toPath: copy.path)) != nil else { return [] }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: copy.path + suffix)
        }
        return body(copy.path)
    }

    // MARK: Session

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

    /// The jar's claude.ai cookies, opened. `interactive` lets macOS ask for
    /// the key; a refresh never does.
    static func read(_ source: Source, interactive: Bool) -> Lookup {
        let names = wanted.map { "'\($0)'" }.joined(separator: ",")
        var cookies: [String: String] = [:]
        switch source.jar {
        case let .firefox(path):
            let rows = withCopy(of: path) {
                SQLiteRead.rows(inFile: $0, query: "select name, value from moz_cookies where host like '%claude.ai' and name in (\(names))", immutable: false)
            }
            for row in rows { if let name = row[0], let value = row[1] { cookies[name] = value } }
        case let .safari(path):
            cookies = safariCookies(at: path).filter { wanted.contains($0.key) }
        case let .chromium(path, service):
            let rows = withCopy(of: path) {
                SQLiteRead.rows(inFile: $0, query: "select name, hex(encrypted_value) from cookies where host_key like '%claude.ai' and name in (\(names))", immutable: false)
            }
            guard !rows.isEmpty else { return .missing }
            let version = withCopy(of: path) {
                SQLiteRead.rows(inFile: $0, query: "select value from meta where key = 'version'", immutable: false)
            }.first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
            let key: Data
            switch keys.key(service: service, interactive: interactive, read: { readPassword(service: service, interactive: $0) }) {
            case let .key(derived): key = derived
            case .refused: return .refused
            case .missing: return .missing
            }
            for row in rows {
                guard let name = row[0], let hex = row[1], let sealed = data(fromHex: hex),
                      let value = decrypt(sealed, key: key, hashPrefixed: version >= 24)
                else { continue }
                cookies[name] = value
            }
        }
        return cookies["sessionKey"] == nil ? .missing : .session(Session(cookies: cookies))
    }

    // MARK: Fetch

    public static func fetch() async throws -> UsageSnapshot {
        let candidates = sources()
        guard !candidates.isEmpty else { throw ProviderError.notConfigured(hint: noSessionHint) }
        var refused = false, rejected = false
        var failure: Error?
        for source in candidates {
            switch read(source, interactive: false) {
            case .refused:
                refused = true
            case .missing:
                continue
            case let .session(session):
                do {
                    var snapshot = try await usage(session)
                    snapshot.source = source.name
                    return snapshot
                } catch ProviderError.sessionExpired {
                    rejected = true
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw failure }
        if rejected { throw ProviderError.sessionExpired(expiredHint) }
        if refused { throw ProviderError.needsAuthorization(hint: authorizationHint) }
        throw ProviderError.notConfigured(hint: noSessionHint)
    }

    static var noSessionHint: String {
        L10n.t(
            "No claude.ai sign-in was found on this Mac. Sign in in the Claude app, or at claude.ai in Chrome, Edge, Brave, Arc, Firefox or Safari.",
            "这台 Mac 上没有找到 claude.ai 的登录。在 Claude 桌面应用里登录，或在 Chrome、Edge、Brave、Arc、Firefox、Safari 里登录 claude.ai。")
    }

    static var authorizationHint: String {
        L10n.t(
            "A sign-in was found, but it is sealed with a keychain item, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "找到了登录，但它由钥匙串里的一项加密保存，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }

    static var expiredHint: String {
        L10n.t(
            "The claude.ai sign-in found was not accepted. Open claude.ai in the Claude app or the browser once, signing in again if it asks.",
            "找到的 claude.ai 登录没有被接受。在 Claude 桌面应用或浏览器里打开一次 claude.ai，如果它要求，重新登录。")
    }

    static func usage(_ session: Session) async throws -> UsageSnapshot {
        let headers = [
            "Cookie": session.header, "User-Agent": userAgent, "Accept": "application/json",
        ]
        guard let org = await organization(session, headers: headers) else { throw ProviderError.sessionExpired(expiredHint) }
        let response = try await HTTP.get(URL(string: "\(origin)/api/organizations/\(org.id)/usage")!, headers: headers)
        if response.status == 401 || response.status == 403 { throw ProviderError.sessionExpired(expiredHint) }
        var snapshot = try ClaudeProvider.parse(try response.requireOK().data)
        if snapshot.planName == nil, let tier = org.tier { snapshot.planName = LocalCredentials.claudePlan(["rateLimitTier": tier]) }
        snapshot.account = await email(for: session, headers: headers)
        return snapshot
    }

    /// The organization the app last had open, else the first the account has.
    static func organization(_ session: Session, headers: [String: String]) async -> (id: String, tier: String?)? {
        guard let response = try? await HTTP.get(URL(string: "\(origin)/api/organizations")!, headers: headers),
              response.status == 200,
              let list = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]]
        else { return session.organization.map { ($0, nil) } }
        let pick = list.first { $0["uuid"] as? String == session.organization } ?? list.first
        guard let id = pick?["uuid"] as? String else { return nil }
        return (id, pick?["rate_limit_tier"] as? String)
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

    /// The keychain button's read, dialog allowed, for every sealed jar that
    /// holds a sign-in.
    @discardableResult
    public static func authorize() -> Bool {
        invalidate()
        var any = false
        for source in sources() {
            if case .session = read(source, interactive: true) { any = true }
        }
        return any
    }

    // MARK: Cookie sealing

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

    // MARK: Safari

    /// Safari's `Cookies.binarycookies`: "cook", a big-endian page count and
    /// page sizes, then pages of little-endian cookie records. Reading it needs
    /// Full Disk Access, and without it the file is simply not readable.
    static func safariCookies(at path: String) -> [String: String] {
        guard let file = FileManager.default.contents(atPath: path) else { return [:] }
        return parseBinaryCookies(file)
    }

    static func parseBinaryCookies(_ file: Data, host: String = "claude.ai") -> [String: String] {
        let bytes = [UInt8](file)
        func be32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func le32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at + 3]) << 24 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 1]) << 8 | Int(bytes[at])
        }
        func string(_ at: Int) -> String? {
            guard at >= 0, at < bytes.count else { return nil }
            var end = at
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            return String(bytes: bytes[at..<end], encoding: .utf8)
        }
        guard bytes.count > 8, Array(bytes[0..<4]) == Array("cook".utf8), let pages = be32(4), pages >= 0, pages < 4096
        else { return [:] }
        var sizes: [Int] = []
        for index in 0..<pages { guard let size = be32(8 + index * 4) else { return [:] }; sizes.append(size) }
        var out: [String: String] = [:]
        var page = 8 + pages * 4
        for size in sizes {
            defer { page += size }
            guard let count = le32(page + 4), count >= 0, count < 100_000 else { continue }
            for index in 0..<count {
                guard let offset = le32(page + 8 + index * 4) else { continue }
                let cookie = page + offset
                guard let domainAt = le32(cookie + 16), let nameAt = le32(cookie + 20), let valueAt = le32(cookie + 28),
                      let domain = string(cookie + domainAt), let name = string(cookie + nameAt),
                      let value = string(cookie + valueAt),
                      domain == host || domain.hasSuffix("." + host)
                else { continue }
                out[name] = value
            }
        }
        return out
    }

    // MARK: Keychain

    enum KeyAnswer { case key(Data), refused, missing }

    private static let keys = KeyMemo()

    /// A key does not change while its app stays installed: read once, kept
    /// for the life of the process. A refusal is kept for a minute so a
    /// refresh timer cannot knock on the keychain every cycle.
    final class KeyMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: Data] = [:]
        private var refusedAt: [String: Date] = [:]

        func key(service: String, interactive: Bool, read: (Bool) -> GrokBot.KeychainRead) -> KeyAnswer {
            lock.lock(); defer { lock.unlock() }
            if let key = keys[service] { return .key(key) }
            if !interactive, Date().timeIntervalSince(refusedAt[service] ?? .distantPast) < 60 { return .refused }
            switch read(interactive) {
            case let .password(password):
                guard let derived = GrokBot.deriveKey(password: password) else { return .missing }
                keys[service] = derived
                return .key(derived)
            case .refused:
                refusedAt[service] = Date()
                return .refused
            case .missing:
                return .missing
            }
        }
    }

    private static func readPassword(service: String, interactive: Bool) -> GrokBot.KeychainRead {
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
}
