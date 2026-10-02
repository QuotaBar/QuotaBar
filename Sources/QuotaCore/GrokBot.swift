import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Grok Bot, xAI's desktop agent, runs on Cursor's backend: everyone signs in
/// to it with a Cursor account. What differs is who pays for its weekly
/// allowance — a Cursor plan, or a SuperGrok subscription linked to that
/// account — and the allowance is shown on that one's card: Cursor's or
/// Grok's, never both.
public enum GrokBot {
    public enum Billing: Sendable, Equatable {
        case cursor
        case grok
    }

    // MARK: The allowance

    /// What cursor.com's `get-sand-usage-status` answers ("Sand" is Grok
    /// Bot's name inside Cursor) — the endpoint Grok Bot reads for its own
    /// usage page.
    struct Status: Decodable, Sendable {
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let usagePercent: Double?
        let hasAvailableUsage: Bool?
        let hasNonZeroIncludedLimit: Bool?
        /// Whose billing system runs the allowance. It says
        /// `SAND_BILLING_BRAND_CURSOR` for a SuperGrok-included allowance too
        /// (seen live, October 2026, on a Cursor Free account), so it is not
        /// who pays; a value naming Grok or xAI still counts as Grok's.
        let billingBrand: String?
        /// The SuperGrok tier ("supergrok") when a linked SuperGrok
        /// subscription is what includes the allowance — who pays.
        let includedUsageSuperGrokPlan: String?
        /// The tier as Grok names it, "SuperGrok".
        let grokPlanLabel: String?

        var billing: Billing {
            if superGrokPlan != nil { return .grok }
            let brand = billingBrand?.uppercased() ?? ""
            if brand.contains("GROK") || brand.contains("XAI") || brand.contains("X_AI") { return .grok }
            return .cursor
        }

        /// "SuperGrok": Grok's own label when it gives one, else the tier id.
        var superGrokPlan: String? {
            guard let plan = includedUsageSuperGrokPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !plan.isEmpty
            else { return nil }
            let label = grokPlanLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return label?.isEmpty == false ? label : plan
        }
    }

    static let statusURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!

    /// `cookie` is a whole Cookie header for cursor.com.
    static func status(cookie: String) async throws -> Status {
        try await HTTP.post(statusURL, headers: [
            "Accept": "application/json",
            "Cookie": cookie,
            "Origin": "https://cursor.com",
        ]).requireOK().json(Status.self)
    }

    /// Only accounts whose plan includes Grok Bot get the row: the endpoint
    /// answers for everyone, with `hasNonZeroIncludedLimit` false for the rest,
    /// and a 0% bar for an allowance that does not exist would be a lie.
    static func window(_ status: Status) -> UsageWindow? {
        guard status.hasNonZeroIncludedLimit == true, let percent = status.usagePercent else { return nil }
        let start = Dates.parseISO(status.currentPeriodStart)
        let end = Dates.parseISO(status.nextResetTimestampUtc)
        var seconds: Int?
        if let start, let end, end > start {
            seconds = Int(end.timeIntervalSince(start).rounded())
        }
        var window = UsageWindow(
            title: "Grok Bot",
            usedPercent: percent,
            resetsAt: end,
            windowSeconds: seconds,
            scope: "Grok Bot")
        window.extra = true
        return window
    }

    // MARK: For the Grok card

    /// What the Grok card has of Grok Bot.
    enum Reading: Sendable {
        /// SuperGrok pays: the row, the tier, and the account it belongs to.
        case row(UsageWindow, plan: String?, account: String?)
        /// A Cursor plan pays, so the row is on the Cursor card.
        case onCursorCard
        case needsAuthorization
        /// Not signed in on this Mac, or signed in without an allowance.
        case nothing
    }

    /// `cursorCardShown`: whether this Mac has a Cursor card for a
    /// Cursor-paid allowance to go on. Without one — Cursor not installed or
    /// turned off — the row comes here rather than nowhere.
    static func readingForGrokCard(cursorCardShown: Bool = true) async throws -> Reading {
        let lookup = lookup(interactive: false)
        switch lookup.state {
        case .missing: return .nothing
        case .needsAuthorization: return .needsAuthorization
        case .available: break
        }
        guard let session = lookup.session else { return .nothing }
        let status: Status
        do {
            status = try await self.status(cookie: session.cookieHeader)
        } catch ProviderError.unauthorized {
            throw ProviderError.sessionExpired(L10n.t(
                "Grok Bot's sign-in has run out. Open Grok Bot once and it renews it.",
                "Grok Bot 的登录已过期。打开一次 Grok Bot，它会自己续期。"))
        }
        guard belongsOnGrokCard(status, cursorCardShown: cursorCardShown) else { return .onCursorCard }
        guard let window = window(status) else { return .nothing }
        return .row(window, plan: status.superGrokPlan, account: session.email)
    }

    /// SuperGrok pays: here. A Cursor plan pays: on the Cursor card, unless
    /// this Mac has none.
    static func belongsOnGrokCard(_ status: Status, cursorCardShown: Bool) -> Bool {
        status.billing == .grok || !cursorCardShown
    }

    public static var authorizationHint: String {
        L10n.t(
            "Grok Bot keeps its sign-in encrypted with a key in the keychain, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "Grok Bot 的登录用钥匙串里的密钥加密，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }

    public static var onCursorCardHint: String {
        L10n.t(
            "Grok Bot on this Mac is paid for with a Cursor plan, so it is on the Cursor card. Sign in with the grok CLI to read Grok's own credits here.",
            "这台 Mac 上的 Grok Bot 由 Cursor 套餐付费，显示在 Cursor 卡片里。用 grok CLI 登录后，这里显示 Grok 自己的额度。")
    }

    // MARK: The sign-in Grok Bot keeps

    public enum SessionState: Sendable, Equatable {
        case available
        /// Signed in, with the sign-in encrypted by a keychain key that macOS
        /// asks about before another app may read it, and no button has
        /// asked yet.
        case needsAuthorization
        /// Not installed, or not signed in.
        case missing
    }

    struct Lookup: Sendable {
        let state: SessionState
        var session: LocalCredentials.CursorSession? = nil
        /// Cursor.app's session, signed in to the same account.
        var viaCursorApp = false
    }

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    /// Grok Bot is signed in on this Mac. Reads the file, never the keychain.
    public static func isSignedIn() -> Bool {
        (try? Data(contentsOf: storeURL)).flatMap(Store.init(data:)) != nil
    }

    /// Never prompts. For the settings row: whether the button is needed.
    public static func sessionState() -> SessionState {
        lookup(interactive: false).state
    }

    /// For `--credentials`: what a quiet lookup found, and where. Never the
    /// secret.
    public static func sessionDescription() -> String {
        let found = lookup(interactive: false)
        switch found.state {
        case .missing: return "missing"
        case .needsAuthorization: return "needs authorization (press Allow keychain access in Settings › Grok)"
        case .available: return found.viaCursorApp ? "available (Cursor.app, same account)" : "available (Grok Bot's own sign-in)"
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

    /// The account Grok Bot is signed in to, as a cursor.com session. When
    /// Cursor.app is signed in to the same account its session is used as it
    /// is, and the keychain is never touched: Grok Bot keys its accounts by
    /// the sha256 of the token's `sub`, which needs no decrypting to compare.
    static func lookup(
        interactive: Bool,
        store: Store? = (try? Data(contentsOf: storeURL)).flatMap(Store.init(data:)),
        editor: @autoclosure () -> LocalCredentials.CursorSession? = LocalCredentials.cursorSession(),
        password: (Bool) -> KeychainRead = readPassword) -> Lookup
    {
        guard let store else { return Lookup(state: .missing) }
        if let active = store.active, let editor = editor(), accountID(sub: editor.subject) == active {
            return Lookup(state: .available, session: editor, viaCursorApp: true)
        }
        if let token = Store.plaintext(store.accessToken) {
            return session(token: token, profile: store.profile.flatMap(Store.plaintext))
        }
        let key: Data
        switch memo.key(interactive: interactive, read: password) {
        case let .key(found): key = found
        case .refused: return Lookup(state: .needsAuthorization)
        case .missing: return Lookup(state: .missing)
        }
        guard let token = decrypt(Store.ciphertext(store.accessToken), key: key) else {
            return Lookup(state: .missing)
        }
        let profile = store.profile.flatMap { decrypt(Store.ciphertext($0), key: key) }
        return session(token: token, profile: profile)
    }

    private static func session(token: String, profile: String?) -> Lookup {
        let email = profile
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap { $0["email"] as? String }
        guard let session = LocalCredentials.makeCursorSession(accessToken: token, email: email) else {
            return Lookup(state: .missing)
        }
        return Lookup(state: .available, session: session)
    }

    static func accountID(sub: String) -> String {
        SHA256.hash(data: Data(sub.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `sand-secrets.json`: a flat map of strings. `cursor-accounts` is plain
    /// JSON — `{active, accounts}`, accounts keyed by `accountID(sub:)` — and
    /// each account's entries are stored one of three ways: base64 of
    /// `safeStorage` ciphertext, the same behind `scoped:v1:<account>:`, or
    /// `plaintext:v1:` and base64 of the value where there is no keychain.
    struct Store: Sendable {
        let active: String?
        let accessToken: String
        let profile: String?

        init?(data: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let accounts = (root["cursor-accounts"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let active = accounts?["active"] as? String
            let entry = active.flatMap { (accounts?["accounts"] as? [String: Any])?[$0] as? [String: String] }
            // An older layout kept the one token at the top level.
            guard let token = entry?["cursor-access-token"] ?? root["cursor-access-token"] as? String,
                  !token.isEmpty
            else { return nil }
            self.active = entry == nil ? nil : active
            accessToken = token
            profile = entry?["cursor-account-profile"]
        }

        static let plaintextPrefix = "plaintext:v1:"
        static let scopedPrefix = "scoped:v1:"

        static func plaintext(_ stored: String) -> String? {
            guard stored.hasPrefix(plaintextPrefix),
                  let data = Data(base64Encoded: String(stored.dropFirst(plaintextPrefix.count)))
            else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func ciphertext(_ stored: String) -> String {
            guard stored.hasPrefix(scopedPrefix) else { return stored }
            let rest = stored.dropFirst(scopedPrefix.count)
            guard let colon = rest.firstIndex(of: ":") else { return stored }
            return String(rest[rest.index(after: colon)...])
        }
    }

    // MARK: Electron safeStorage

    /// Chromium's macOS scheme, which Electron's `safeStorage` is: "v10",
    /// then AES-128-CBC under PBKDF2-SHA1(the keychain password, "saltysalt",
    /// 1003 rounds), with an IV of sixteen spaces.
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

    static func decrypt(_ base64: String, key: Data) -> String? {
        guard let sealed = Data(base64Encoded: base64), sealed.starts(with: Array("v10".utf8)) else { return nil }
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
        return String(data: out.prefix(written), encoding: .utf8)
    }

    // MARK: Keychain

    enum KeychainRead: Sendable {
        case password(Data)
        /// macOS would ask, or did and was told no.
        case refused
        case missing
    }

    static let keychainService = "Grok Bot Safe Storage"

    private static func readPassword(interactive: Bool) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status: OSStatus = interactive
            ? SecItemCopyMatching(query as CFDictionary, &result)
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

    /// The key never changes while Grok Bot stays installed, so once read it
    /// is kept for the life of the process: one "Allow" is enough until the
    /// next launch. A refusal is kept for a minute, so a refresh timer cannot
    /// knock on the keychain every cycle.
    private static let memo = KeyMemo()

    final class KeyMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var key: Data?
        private var refusedAt: Date = .distantPast

        func key(interactive: Bool, read: (Bool) -> KeychainRead) -> KeyAnswer {
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

        func reset() {
            lock.lock(); key = nil; refusedAt = .distantPast; lock.unlock()
        }
    }

    /// For tests: forget the key and any refusal.
    static func resetKeyMemo() {
        memo.reset()
    }
}
