import CryptoKit
import Foundation
import Security

/// Readers for credentials stored locally by provider CLIs (no passwords, reuse existing sessions).
public enum LocalCredentials {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The Claude lookup is memoized briefly: a refresh cycle and a settings
    /// render should share one keychain round trip, and a re-login should
    /// still be picked up within the minute.
    private static let keychainTTL: TimeInterval = 60
    private static let memo = TokenMemo()

    final class TokenMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClaudeLookup?
        private var storedAt: Date = .distantPast

        func cached(ttl: TimeInterval) -> ClaudeLookup? {
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(storedAt) < ttl else { return nil }
            return value
        }

        func store(_ lookup: ClaudeLookup) {
            lock.lock()
            value = lookup
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

    /// What a lookup of Claude Code's keychain item found.
    public enum ClaudeCredentialState: Sendable, Equatable {
        /// A token was read.
        case available
        /// The item is there, but macOS would put up its keychain dialog
        /// before handing it over, and no user action has asked for that yet.
        case needsAuthorization
        /// No item, or an item without a usable token: Claude Code has not
        /// signed in on this Mac.
        case missing
    }

    /// Which of the two reads answered. Shown by `--credentials`, nowhere else.
    public enum ClaudeLookupRoute: String, Sendable {
        /// `SecItemCopyMatching` in this process: needs this app in the item's
        /// access list.
        case keychainAPI = "keychain API"
        /// `/usr/bin/security find-generic-password`: needs only what Claude
        /// Code itself puts in the access list.
        case securityTool = "security tool"
    }

    struct ClaudeLookup: Sendable, Equatable {
        let state: ClaudeCredentialState
        let token: String?
        /// "Max 20x", "Pro" — from the same item, so no extra keychain read.
        var plan: String? = nil
        var via: ClaudeLookupRoute = .keychainAPI
    }

    static let claudeService = "Claude Code-credentials"

    /// Shown wherever the app is waiting on the user's say-so.
    public static var claudeAuthorizationHint: String {
        L10n.t(
            "Claude Code keeps its session in the keychain, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "Claude Code 的会话存在钥匙串里，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }

    /// Never prompts. Background refreshes call this every cycle, and a
    /// keychain dialog that pops up on a timer — every minute, for as long as
    /// the user keeps declining it — is exactly what this guards against.
    /// When macOS would have asked, the answer is `nil` and
    /// `claudeCredentialState()` reports `.needsAuthorization`; the dialog is
    /// only ever raised by `authorizeClaudeAccess()`, from a button.
    public static func claudeOAuthToken() -> String? {
        probeClaude().token
    }

    public static func claudeCredentialState() -> ClaudeCredentialState {
        probeClaude().state
    }

    /// The subscription Claude Code's item records, for the plan chip. The
    /// usage endpoint itself does not say.
    public static func claudePlanName() -> String? {
        probeClaude().plan
    }

    public static func claudeCredentialRoute() -> ClaudeLookupRoute {
        probeClaude().via
    }

    /// The one place the keychain dialog is allowed. Call it from a user
    /// action; it blocks the calling thread for as long as the dialog is up.
    /// A decline is remembered like any other answer, so the next refresh
    /// stays quiet and the button simply remains available.
    @discardableResult
    public static func authorizeClaudeAccess() -> Bool {
        let lookup = readClaudeOAuthToken(interactive: true)
        memo.store(lookup)
        return lookup.state == .available
    }

    /// `authorizeClaudeAccess()` off the cooperative pool: the dialog can sit
    /// there for minutes, and a pinned executor thread would be a poor trade
    /// for one keychain read.
    public static func authorizeClaudeAccessAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: authorizeClaudeAccess())
            }
        }
    }

    private static func probeClaude() -> ClaudeLookup {
        if let cached = memo.cached(ttl: keychainTTL) { return cached }
        let lookup = readClaudeOAuthToken(interactive: false)
        memo.store(lookup)
        return lookup
    }

    /// Two reads, in order. The direct one goes through this process and so
    /// depends on this app's code signature being in the item's access list —
    /// which is where the dialogs come from: an ad-hoc dev build is a new
    /// hash every time, and macOS forgets even an identity now and then. When
    /// that read would have asked, the `security` tool reads instead, with the
    /// trust Claude Code itself gave it, and nothing asks at all. The dialog
    /// (and its button) is left for the case where both fail.
    private static func readClaudeOAuthToken(interactive: Bool) -> ClaudeLookup {
        let direct = readClaudeViaKeychainAPI(interactive: interactive)
        if interactive {
            // The user pressed the button: their answer stands, and the tool
            // gets another go on the next quiet read.
            SecurityTool.retry()
            return direct
        }
        guard direct.state == .needsAuthorization, let viaTool = SecurityTool.readClaude()
        else { return direct }
        return viaTool
    }

    private static func readClaudeViaKeychainAPI(interactive: Bool) -> ClaudeLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status: OSStatus = interactive
            ? SecItemCopyMatching(query as CFDictionary, &result)
            : KeychainUI.withoutPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
        return classify(status: status, data: result as? Data)
    }

    /// Claude Code writes its item with `security add-generic-password`, and
    /// an item that tool creates trusts the tool back: `/usr/bin/security` in
    /// the access list, `apple-tool:` in the partition list. That is how
    /// Claude Code reads the item on every launch without a dialog, and a
    /// read through the same tool inherits the same trust — whatever this
    /// build is signed with, and however often Claude Code rewrites the item.
    /// Measured on macOS 27 from a process the item had never heard of: the
    /// item, no dialog.
    enum SecurityTool {
        static let path = "/usr/bin/security"
        private static let lock = NSLock()
        private static var declined = false

        /// The tool has no "stay quiet" switch. Should it ever be refused —
        /// an item some other writer created, which does not trust it — that
        /// is remembered for the life of the process, so a refresh timer
        /// cannot turn one dialog into one a minute.
        static func retry() {
            lock.lock(); declined = false; lock.unlock()
        }

        static func readClaude() -> ClaudeLookup? {
            lock.lock(); let skip = declined; lock.unlock()
            guard !skip, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["find-generic-password", "-s", claudeService, "-w"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lookup = classifyToolResult(exitCode: process.terminationStatus, output: output)
            if lookup == nil, refusals.contains(process.terminationStatus) {
                lock.lock(); declined = true; lock.unlock()
            }
            return lookup
        }

        /// The tool exits with the low byte of the OSStatus: 44 is
        /// errSecItemNotFound; 36, 51 and 128 are interaction-not-allowed,
        /// auth-failed and user-cancelled — the three "would ask, or did and
        /// was told no" answers.
        static let refusals: Set<Int32> = [36, 51, 128]

        /// Pure. `nil` leaves the direct read's verdict (and its button) in
        /// place.
        static func classifyToolResult(exitCode: Int32, output: Data) -> ClaudeLookup? {
            switch exitCode {
            case 0:
                var lookup = classify(status: errSecSuccess, data: secret(from: output))
                lookup.via = .securityTool
                return lookup
            case 44:
                return ClaudeLookup(state: .missing, token: nil, via: .securityTool)
            default:
                return nil
            }
        }

        /// `-w` prints the secret and a newline — as hex when it holds bytes
        /// the tool will not print as text.
        static func secret(from output: Data) -> Data {
            var bytes = output
            while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
            guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty,
                  text.first != "{", text.count % 2 == 0, text.allSatisfy(\.isHexDigit)
            else { return bytes }
            var decoded = Data(capacity: text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return bytes }
                decoded.append(byte)
                index = next
            }
            return decoded
        }
    }

    /// Pure, so the status mapping is pinned by tests without a keychain.
    static func classify(status: OSStatus, data: Data?) -> ClaudeLookup {
        switch status {
        case errSecSuccess:
            let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let token = root.flatMap(claudeToken)
            return ClaudeLookup(
                state: token == nil ? .missing : .available,
                token: token,
                plan: root.flatMap(claudePlan))
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // -25308 is what the documentation promises for a suppressed
            // dialog; -25293 is what macOS 27 actually returns (measured on
            // an item this process is not trusted for). -128 is the user
            // pressing Deny on the interactive path.
            return ClaudeLookup(state: .needsAuthorization, token: nil)
        default:
            return ClaudeLookup(state: .missing, token: nil)
        }
    }

    static func extractClaudeToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claudeToken(root)
    }

    static func claudeToken(_ root: [String: Any]) -> String? {
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty
        {
            return token
        }
        if let token = root["accessToken"] as? String, !token.isEmpty { return token }
        return nil
    }

    /// `rateLimitTier` is the precise one — "default_claude_max_20x" carries
    /// the multiplier — with `subscriptionType` ("max", "pro") as the
    /// fallback. Neither is documented; both are what the item holds today.
    static func claudePlan(_ root: [String: Any]) -> String? {
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        if let tier = oauth["rateLimitTier"] as? String, !tier.isEmpty {
            var words = tier.split(separator: "_").map(String.init)
            if words.first == "default" { words.removeFirst() }
            if words.first?.lowercased() == "claude" { words.removeFirst() }
            if !words.isEmpty {
                return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        if let type = oauth["subscriptionType"] as? String, !type.isEmpty {
            return type.prefix(1).uppercased() + type.dropFirst()
        }
        return nil
    }

    /// Legacy login-keychain items have no per-query "no UI" switch — the
    /// `kSecUseAuthenticationUI` keys only govern data-protection items. The
    /// process-wide `SecKeychainSetUserInteractionAllowed` is what works:
    /// measured on macOS 27, a read that would have prompted returns in 9 ms
    /// with `errSecAuthFailed` and no dialog. It has carried a deprecation
    /// since 10.10 ("SecKeychain is deprecated") with nothing offered in its
    /// place, so it is bound through `dlsym` rather than the declared symbol:
    /// the warning would otherwise sit in every build. The C signature is
    /// stable — `(Boolean) -> OSStatus`.
    enum KeychainUI {
        private typealias SetInteraction = @convention(c) (UInt8) -> OSStatus
        private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus

        // RTLD_DEFAULT; the macro does not import.
        private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
        private static let set: SetInteraction? = dlsym(handle, "SecKeychainSetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: SetInteraction.self) }
        private static let get: GetInteraction? = dlsym(handle, "SecKeychainGetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: GetInteraction.self) }
        // The switch is process-global, so two callers must not interleave
        // their save/restore.
        private static let lock = NSLock()

        static var isInteractionAllowed: Bool {
            guard let get else { return true }
            var value: UInt8 = 1
            _ = get(&value)
            return value != 0
        }

        /// Runs `body` with the keychain dialog suppressed, then puts the
        /// switch back the way it was. Without the symbols (never, on macOS)
        /// it runs `body` as-is — the old behaviour, which may prompt.
        static func withoutPrompts<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            guard let set, let get else { return body() }
            var previous: UInt8 = 1
            _ = get(&previous)
            _ = set(0)
            defer { _ = set(previous) }
            return body()
        }
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
        jwtPayload(jwt)?[name] as? String
    }

    /// The whole payload, for claims that are not strings (`exp`).
    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore base64 padding stripped by the JWT encoding.
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Kimi Code (~/.kimi-code/credentials, written by the Kimi Code app and CLI)

    /// The OAuth session the Kimi Code desktop app and the `kimi` CLI share.
    public struct KimiCodeSession: Sendable, Equatable, CustomStringConvertible {
        public let accessToken: String
        /// From the file's `expires_at`, else the token's own `exp`.
        public let expiresAt: Date?
        /// Whether the file holds a refresh token to renew the access token
        /// with. The refresh token itself is not kept: a renewal reads it
        /// from the file again, under Kimi Code's lock.
        public let hasRefreshToken: Bool
        /// When that refresh token runs out, from its own `exp` — 30 days
        /// after Kimi Code last renewed. nil when it carries none, and the
        /// server decides.
        public let refreshExpiresAt: Date?
        /// The Code API the token was issued for, `…/coding/v1`.
        public let baseURL: URL
        /// Which file answered — a name, for `--credentials`.
        public let fileName: String
        /// The name Kimi Code saves this sign-in under (`kimi-code`,
        /// `kimi-code-env-…`), which also names its renewal lock. nil for the
        /// older Python CLI's file in `~/.kimi`, which QuotaBar only reads.
        public let storageName: String?

        public init(
            accessToken: String,
            expiresAt: Date?,
            hasRefreshToken: Bool = true,
            refreshExpiresAt: Date? = nil,
            baseURL: URL,
            fileName: String,
            storageName: String? = nil)
        {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.hasRefreshToken = hasRefreshToken
            self.refreshExpiresAt = refreshExpiresAt
            self.baseURL = baseURL
            self.fileName = fileName
            self.storageName = storageName
        }

        /// China (api.kimi.com) or global (api.kimi.ai).
        public var edition: KimiEdition { KimiEdition.forAPIHost(baseURL.host) }

        /// Written by the Python CLI that came before Kimi Code.
        public var isLegacy: Bool { storageName == nil }

        /// A little early, so a token that runs out while the request is on
        /// its way is not sent.
        public static let expiryMargin: TimeInterval = 30

        /// How close to running out QuotaBar lets a token get before it
        /// renews it. Later than Kimi Code's own threshold (half of the 15
        /// minutes): QuotaBar needs the token for one request, and every
        /// renewal rotates the refresh token Kimi Code shares.
        public static let renewalMargin: TimeInterval = 60

        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= Self.expiryMargin
        }

        /// Close enough to running out to renew before use.
        public func isDueForRenewal(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= Self.renewalMargin
        }

        /// Whether the access token can still be renewed: there is a refresh
        /// token, and it has not run out.
        public func canRenew(now: Date = Date()) -> Bool {
            guard hasRefreshToken else { return false }
            guard let refreshExpiresAt else { return true }
            return refreshExpiresAt.timeIntervalSince(now) > Self.expiryMargin
        }

        /// Signed out in all but name: the access token has run out and
        /// nothing can renew it, so only signing in again brings it back.
        public func needsSignIn(now: Date = Date()) -> Bool {
            isExpired(now: now) && !canRenew(now: now)
        }

        public var usageURL: URL { baseURL.appendingPathComponent("usages") }

        /// Everything but the token, so a log line or a failed assertion
        /// cannot print it.
        public var description: String {
            "KimiCodeSession(\(fileName) → \(baseURL.host ?? "?") [\(edition.rawValue)], expires \(expiresAt.map { "\($0)" } ?? "unknown"), "
                + "renewable until \(hasRefreshToken ? refreshExpiresAt.map { "\($0)" } ?? "unknown" : "never"))"
        }
    }

    /// The two Code API hosts: api.kimi.com for mainland China, api.kimi.ai
    /// for everywhere else. A token is only ever sent to one of these.
    static let kimiCodeBaseURLs = [
        "https://api.kimi.com/coding/v1",
        "https://api.kimi.ai/coding/v1",
    ]
    static let kimiCodeOAuthHosts = ["https://auth.kimi.com", "https://auth.kimi.ai"]

    /// Kimi Code names the credential file after the hosts it signed in
    /// against: `kimi-code` for the mainland pair, otherwise `kimi-code-env-`
    /// and the first 16 hex digits of the SHA-256 of
    /// `{"oauthHost":…,"baseUrl":…}` (`resolveKimiCodeOAuthKey` in its
    /// `packages/oauth`). The global app signs in as `kimi-code-env-0e4f99c69cc27850`.
    static func kimiCodeStorageName(oauthHost: String, baseURL: String) -> String {
        if oauthHost == "https://auth.kimi.com", baseURL == "https://api.kimi.com/coding/v1" {
            return "kimi-code"
        }
        // Built by hand to match JSON.stringify byte for byte: key order and
        // unescaped slashes both matter to the hash.
        let json = #"{"oauthHost":"\#(oauthHost)","baseUrl":"\#(baseURL)"}"#
        let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        return "kimi-code-env-" + digest.prefix(16)
    }

    /// Credential file name → the Code API it belongs to, for every pairing of
    /// the known hosts. A file for any other host (set through Kimi Code's
    /// environment overrides) is not read: there is no telling where its
    /// token may be sent.
    static let kimiCodeStorageNames: [String: URL] = kimiCodeSlots.mapValues(\.baseURL)

    /// The same pairings with both hosts: what a file's token may be renewed
    /// against, and where it is spent. The edition follows the Code API host.
    static let kimiCodeSlots: [String: KimiCodeSlot] = {
        var slots: [String: KimiCodeSlot] = [:]
        for oauthHost in kimiCodeOAuthHosts {
            for base in kimiCodeBaseURLs {
                let name = kimiCodeStorageName(oauthHost: oauthHost, baseURL: base)
                slots[name] = KimiCodeSlot(storageName: name, oauthHost: oauthHost, baseURL: URL(string: base)!)
            }
        }
        return slots
    }()

    /// The Kimi Code sign-in on this Mac, read afresh on every call so a token
    /// Kimi Code renewed a minute ago is the one used. nil when there is none,
    /// or none that Kimi Code could still renew: an expired access token with
    /// a refresh token that has run out too is a sign-in to redo, not one to
    /// wait for.
    ///
    /// Kimi Code 0.3x and its desktop app keep the session in
    /// `~/.kimi-code/credentials/<name>.json`; the older Python CLI kept it in
    /// `~/.kimi/credentials/kimi-code.json`. Among the files that count (see
    /// `kimiCodeSessions`), the one config.toml says Kimi Code signs in
    /// with comes first; otherwise whichever runs out last is the live one —
    /// a region switch leaves the other behind.
    ///
    /// Only read here. Renewing is `KimiCodeRenewal`'s, under Kimi Code's
    /// own lock: the access token lasts 15 minutes, and every renewal
    /// rotates the refresh token Kimi Code shares.
    public static func kimiCodeSession(now: Date = Date()) -> KimiCodeSession? {
        kimiCodeSession(codeHome: kimiCodeHome, legacyHome: kimiLegacyHome, now: now)
    }

    /// Every sign-in that may be the one Kimi Code uses, whether or not it
    /// can still be renewed — for telling "signed out" from "never signed in".
    public static func kimiCodeSessions() -> [KimiCodeSession] {
        kimiCodeSessions(codeHome: kimiCodeHome, legacyHome: kimiLegacyHome)
    }

    /// When each file the sign-in is read from was last written, by name —
    /// never what it holds. A change means Kimi Code renewed its token, or
    /// signed in or out, and the quota can be read again.
    public static func kimiCodeFilesWritten() -> [String: Date] {
        kimiCodeFilesWritten(codeHome: kimiCodeHome, legacyHome: kimiLegacyHome)
    }

    static var kimiCodeHome: URL { home.appendingPathComponent(".kimi-code") }
    static var kimiLegacyHome: URL { home.appendingPathComponent(".kimi") }

    static func kimiCodeSession(codeHome: URL, legacyHome: URL, now: Date) -> KimiCodeSession? {
        let usable = kimiCodeSessions(codeHome: codeHome, legacyHome: legacyHome).filter { !$0.needsSignIn(now: now) }
        // The sign-in Kimi Code uses is the one it keeps renewed, and the one
        // QuotaBar may renew; a file left by an earlier region can outlast it.
        if let active = KimiCodeConfig.activeSlot(codeHome: codeHome),
           let session = usable.first(where: { $0.storageName == active.storageName })
        {
            return session
        }
        var best: KimiCodeSession?
        for candidate in usable
            where best == nil || (candidate.expiresAt ?? .distantPast) > (best?.expiresAt ?? .distantPast)
        {
            best = candidate
        }
        return best
    }

    /// The files that count, in a fixed order so a tie on expiry is settled
    /// the same way every time.
    ///
    /// - Kimi Code's own files, except any written before a signed-out
    ///   marker: after a refused renewal Kimi Code blanks the file it was
    ///   using, and a file from an earlier region is then no sign-in of its.
    ///   One written after the marker is a sign-in since.
    /// - The Python CLI's file only where Kimi Code has never been: once it
    ///   has, it keeps its own file, and its migration report lists the old
    ///   sign-in as one to redo — the old file is left over, not live.
    static func kimiCodeSessions(codeHome: URL, legacyHome: URL) -> [KimiCodeSession] {
        let fileManager = FileManager.default
        let directory = codeHome.appendingPathComponent("credentials")
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [(session: KimiCodeSession, written: Date)] = []
        var signedOutAt: Date?
        var hasOwnFile = false
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let base = kimiCodeStorageNames[stem] else { continue }
            hasOwnFile = true
            guard let root = kimiCodeFile(file) else { continue }
            let written = modificationDate(file) ?? .distantPast
            if let session = kimiCodeSession(in: root, baseURL: base, fileName: file.lastPathComponent, storageName: stem) {
                found.append((session, written))
            } else if (root["access_token"] as? String)?.isEmpty == true {
                signedOutAt = max(signedOutAt ?? .distantPast, written)
            }
        }
        var sessions = found
            .filter { entry in signedOutAt.map { entry.written > $0 } ?? true }
            .map(\.session)
        let migrated = fileManager.fileExists(atPath: codeHome.appendingPathComponent("migration-report.json").path)
        let legacy = legacyHome.appendingPathComponent("credentials/kimi-code.json")
        if !hasOwnFile, !migrated, let root = kimiCodeFile(legacy),
           let session = kimiCodeSession(in: root, baseURL: URL(string: kimiCodeBaseURLs[0])!, fileName: legacy.lastPathComponent)
        {
            sessions.append(session)
        }
        return sessions
    }

    static func kimiCodeFilesWritten(codeHome: URL, legacyHome: URL) -> [String: Date] {
        var written: [String: Date] = [:]
        let directory = codeHome.appendingPathComponent("credentials")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json"
            && kimiCodeStorageNames[file.deletingPathExtension().lastPathComponent] != nil
        {
            written[file.lastPathComponent] = modificationDate(file) ?? .distantPast
        }
        let legacy = legacyHome.appendingPathComponent("credentials/kimi-code.json")
        if let date = modificationDate(legacy) { written["~/.kimi/" + legacy.lastPathComponent] = date }
        return written
    }

    private static func kimiCodeFile(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Pure. `{"access_token", "refresh_token", "expires_at", "scope",
    /// "token_type", "expires_in"}`; `expires_at` is whole seconds from the
    /// current apps and fractional from the Python CLI. After a refused
    /// renewal Kimi Code blanks both tokens and zeroes the expiry — signed
    /// out, so no session. The refresh token is decoded here, on this Mac,
    /// for its `exp` alone, and not kept: a renewal reads the file again.
    static func kimiCodeSession(
        in root: [String: Any], baseURL: URL, fileName: String, storageName: String? = nil) -> KimiCodeSession?
    {
        guard let access = root["access_token"] as? String, !access.isEmpty else { return nil }
        let fromFile = QwenProvider.number(root["expires_at"]).flatMap(Dates.parseEpoch)
        let fromToken = jwtPayload(access).flatMap { QwenProvider.number($0["exp"]) }.flatMap(Dates.parseEpoch)
        let refresh = (root["refresh_token"] as? String) ?? ""
        return KimiCodeSession(
            accessToken: access,
            expiresAt: fromFile ?? fromToken,
            hasRefreshToken: !refresh.isEmpty,
            refreshExpiresAt: jwtPayload(refresh).flatMap { QwenProvider.number($0["exp"]) }.flatMap(Dates.parseEpoch),
            baseURL: baseURL,
            fileName: fileName,
            storageName: storageName)
    }

    // MARK: Grok (~/.grok/auth.json written by the grok CLI)

    // MARK: Antigravity

    /// Antigravity's standalone OAuth token, as the app leaves it on disk.
    public struct AntigravityToken: Sendable {
        public let accessToken: String
        public let expiry: Date?

        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiry else { return false }
            return expiry <= now
        }
    }

    /// Antigravity's sign-in token, from wherever it was saved last.
    ///
    /// Two copies of `{"token": {"access_token", "expiry", "refresh_token",
    /// ...}, "auth_method"}`: the login keychain's `gemini` / `antigravity`
    /// item, and `~/.gemini/jetski-standalone-oauth-token`. Antigravity 2.14
    /// writes the keychain at every sign-in and the file only sometimes, and
    /// refreshes neither while it runs (issue #4), so whichever runs out
    /// later is the one. Only read: refreshing it would need the app's own
    /// OAuth client, which is its to keep. While the app is open its
    /// language server is asked instead; see `AntigravityLocal`.
    public static func antigravityToken() -> AntigravityToken? {
        let url = home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let fromFile = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap(antigravityToken(in:))
        let fromKeychain = antigravityKeychainSecret().flatMap(antigravityToken(keychainSecret:))
        return [fromKeychain, fromFile].compactMap { $0 }
            .max { ($0.expiry ?? .distantPast) < ($1.expiry ?? .distantPast) }
    }

    /// The keychain item is written by go-keyring, which goes through
    /// `/usr/bin/security`; the item trusts that tool, so reading it the same
    /// way asks nothing of the owner — measured on Antigravity 2.14.0.
    static func antigravityKeychainSecret() -> String? {
        guard let result = ToolRunner.run(
            "/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], timeout: 5),
            result.status == 0
        else { return nil }
        let secret = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.isEmpty ? nil : secret
    }

    /// go-keyring stores `go-keyring-base64:` and the JSON in base64; an
    /// older value may be the JSON itself.
    static func antigravityToken(keychainSecret secret: String) -> AntigravityToken? {
        let prefix = "go-keyring-base64:"
        let data = secret.hasPrefix(prefix)
            ? Data(base64Encoded: String(secret.dropFirst(prefix.count)))
            : Data(secret.utf8)
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return antigravityToken(in: root)
    }

    static func antigravityToken(in root: [String: Any]) -> AntigravityToken? {
        let token = root["token"] as? [String: Any] ?? root
        guard let access = token["access_token"] as? String, !access.isEmpty else { return nil }
        return AntigravityToken(accessToken: access, expiry: parseFlexibleISO(token["expiry"] as? String))
    }

    /// ISO 8601 with any number of fractional digits and a numeric offset —
    /// Python's `isoformat()`, which is what wrote the file.
    static func parseFlexibleISO(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Dates.parseISO(raw) { return date }
        // Trim fractional seconds to three digits, which is what
        // ISO8601DateFormatter accepts.
        let trimmed = raw.replacingOccurrences(
            of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        if let date = Dates.parseISO(trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter.date(from: trimmed)
    }

    public struct GrokAuth: Sendable {
        public let accessToken: String
        /// The signed-in account, from the same entry as the token.
        public let email: String?
    }

    public static func grokAccessToken() -> String? {
        grokAuth()?.accessToken
    }

    public static func grokAuth() -> GrokAuth? {
        let candidates = [
            home.appendingPathComponent(".grok/auth.json"),
            home.appendingPathComponent(".config/grok/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let auth = grokAuth(in: root) { return auth }
        }
        return nil
    }

    /// Two shapes. Early grok CLIs wrote a flat file with the token at the
    /// top level. 1.0.x keys the file by issuer —
    /// `"https://auth.x.ai::<client-id>": { "key": …, "expires_at": …, … }`
    /// — and the bearer the billing endpoint wants is `key` (verified against
    /// `cli-chat-proxy.grok.com/v1/billing`: 200 with it). Entries whose
    /// `expires_at` has passed are ranked last rather than dropped: an expired
    /// token gets a 401 and the "sign in again" message, which is the truth,
    /// where "not configured" would send the user hunting for a file that is
    /// right there. The CLI refreshes the entry on its next run; the app does
    /// not touch `refresh_token` — that is the CLI's session to rotate.
    static func grokToken(in root: [String: Any], now: Date = Date()) -> String? {
        grokAuth(in: root, now: now)?.accessToken
    }

    static func grokAuth(in root: [String: Any], now: Date = Date()) -> GrokAuth? {
        for key in ["access_token", "accessToken", "token", "api_key"] {
            if let token = root[key] as? String, !token.isEmpty {
                return GrokAuth(accessToken: token, email: root["email"] as? String)
            }
        }
        var live: [(expires: Date, auth: GrokAuth)] = []
        var expired: [(expires: Date, auth: GrokAuth)] = []
        for value in root.values {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { continue }
            let auth = GrokAuth(accessToken: token, email: entry["email"] as? String)
            let expires = Dates.parseISO(entry["expires_at"] as? String) ?? .distantFuture
            if expires > now { live.append((expires, auth)) } else { expired.append((expires, auth)) }
        }
        // The one that lives longest, then the one that expired most recently.
        return live.max(by: { $0.expires < $1.expires })?.auth
            ?? expired.max(by: { $0.expires < $1.expires })?.auth
    }
}
