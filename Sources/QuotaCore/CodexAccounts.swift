import Foundation

// MARK: - Codex accounts QuotaBar keeps (issue #6)

/// A Codex account QuotaBar keeps, so it can be read while another is signed
/// in and switched to without signing in again. What is kept is the whole of
/// `~/.codex/auth.json` as the CLI wrote it for that account, in the keychain;
/// this is the part that is not secret.
public struct CodexAccount: Codable, Sendable, Equatable, Identifiable {
    /// `tokens.account_id`: ChatGPT's id for the account.
    public let id: String
    public var email: String?
    /// ChatGPT's plan id as the sign-in carries it: "plus", "pro".
    public var plan: String?
    public var savedAt: Date

    public init(id: String, email: String?, plan: String?, savedAt: Date) {
        self.id = id
        self.email = email
        self.plan = plan
        self.savedAt = savedAt
    }
}

/// `~/.codex/auth.json`, read for what keeping and switching accounts needs.
/// The bytes are kept as the CLI wrote them and written back unchanged, apart
/// from the tokens a refresh replaces.
public struct CodexAuthFile: Sendable, Equatable {
    public let data: Data
    public let accountID: String
    public let email: String?
    public let plan: String?
    public let accessToken: String
    public let refreshToken: String?
    /// When the access token runs out, from its own `exp`.
    public let accessExpiry: Date?

    public init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { return nil }
        let idClaims = (tokens["id_token"] as? String).flatMap(LocalCredentials.jwtPayload)
        let auth = idClaims?["https://api.openai.com/auth"] as? [String: Any]
        guard let account = (tokens["account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String),
              !account.isEmpty
        else { return nil }
        self.data = data
        self.accountID = account
        self.email = idClaims?["email"] as? String
        self.plan = auth?["chatgpt_plan_type"] as? String
        self.accessToken = access
        self.refreshToken = tokens["refresh_token"] as? String
        self.accessExpiry = (LocalCredentials.jwtPayload(access)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    var summary: CodexAccount {
        CodexAccount(id: accountID, email: email, plan: plan, savedAt: Date())
    }

    /// Refreshed a day and a half before it runs out; the CLI refreshes at
    /// eight of its ten days, so a stored copy is never older than one the
    /// CLI would still use.
    public func needsRefresh(now: Date = .now) -> Bool {
        guard let accessExpiry else { return true }
        return accessExpiry.timeIntervalSince(now) < 36 * 3600
    }

    /// The same file with the tokens a refresh handed back. A refresh that
    /// leaves one out keeps the old one, as the CLI does.
    public func refreshed(with tokens: CodexTokenRefresh.Tokens, now: Date = .now) -> CodexAuthFile? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var stored = root["tokens"] as? [String: Any]
        else { return nil }
        if let id = tokens.idToken { stored["id_token"] = id }
        if let access = tokens.accessToken { stored["access_token"] = access }
        if let refresh = tokens.refreshToken { stored["refresh_token"] = refresh }
        root["tokens"] = stored
        root["last_refresh"] = ISO8601DateFormatter().string(from: now)
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return CodexAuthFile(out)
    }
}

public enum CodexAccountError: LocalizedError, Equatable {
    /// No `~/.codex/auth.json`, or one without a signed-in account.
    case notSignedIn
    case notSaved
    case keychain
    case writeFailed(String)
    /// The account's refresh token no longer works: it can only be signed in again.
    case signInAgain(email: String?)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            L10n.t("Codex isn't signed in on this Mac. Run `codex login` first.", "这台 Mac 上的 Codex 没有登录。先运行 `codex login`。")
        case .notSaved:
            L10n.t("That account isn't saved in QuotaBar.", "QuotaBar 里没有保存这个账号。")
        case .keychain:
            L10n.t("The keychain refused to store the account.", "钥匙串拒绝保存这个账号。")
        case let .writeFailed(reason):
            L10n.t("Couldn't write ~/.codex/auth.json: \(reason)", "无法写入 ~/.codex/auth.json：\(reason)")
        case let .signInAgain(email):
            L10n.t(
                "\(email ?? "This account")'s saved sign-in no longer works. Sign in to it with `codex login` and save it again.",
                "\(email.map { "\($0) " } ?? "这个账号")保存的登录已失效。用 `codex login` 重新登录它，再保存一次。")
        }
    }
}

// MARK: - Refreshing a stored account's tokens

/// The Codex CLI's own refresh, for accounts only QuotaBar holds: the CLI
/// refreshes the account it is signed in as, and that one is never refreshed
/// here, so the two never spend the same refresh token — it works once.
/// The client is the CLI's public one; there is no secret.
public enum CodexTokenRefresh {
    static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public struct Tokens: Sendable, Equatable {
        public var idToken: String?
        public var accessToken: String?
        public var refreshToken: String?
    }

    public static func refresh(_ refreshToken: String) async throws -> Tokens {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])
        let response = try await HTTP.post(endpoint, headers: ["Accept": "application/json"],
                                           jsonBody: String(decoding: body, as: UTF8.self))
        return try parse(status: response.status, data: response.data)
    }

    /// `invalid_grant` and the three refresh-token codes are for good: the
    /// account has to be signed in again. Anything else may pass.
    static func parse(status: Int, data: Data) throws -> Tokens {
        let root = ProviderJSON.object(data) as? [String: Any]
        guard (200...299).contains(status) else {
            let code = ((root?["error"] as? [String: Any])?["code"] as? String)
                ?? (root?["error"] as? String) ?? (root?["code"] as? String) ?? ""
            let permanent = ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
            if status == 401 || permanent.contains(code.lowercased()) { throw CodexAccountError.signInAgain(email: nil) }
            throw ProviderError.http(status)
        }
        guard let root, root["access_token"] is String else { throw ProviderError.badResponse }
        return Tokens(
            idToken: root["id_token"] as? String,
            accessToken: root["access_token"] as? String,
            refreshToken: root["refresh_token"] as? String)
    }
}

// MARK: - The vault

/// The saved accounts and the file the CLI reads. An actor, because a
/// refresh token is spent the moment it is used: a refresh and a switch of
/// the same account must never overlap, or the CLI is left holding a token
/// that has already gone.
public actor CodexAccountVault {
    public static let shared = CodexAccountVault()

    let liveURL: URL
    let storage: CredentialStorage
    private let refresher: @Sendable (String) async throws -> CodexTokenRefresh.Tokens

    static let indexKey = "codex-accounts"
    static func blobKey(_ id: String) -> String { "codex-account.\(id)" }

    /// Refreshes under way, by account. An actor is re-entrant at every
    /// `await`: while one refresh waits on the network, a second read of the
    /// same account, or a switch to it, would otherwise get in — the one
    /// spending the refresh token a second time, the other writing the CLI a
    /// token that has just been spent. Both wait on this instead.
    private var refreshing: [String: Task<CodexAuthFile, Error>] = [:]

    public init(
        liveURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
        storage: CredentialStorage = KeychainStorage(),
        refresher: @escaping @Sendable (String) async throws -> CodexTokenRefresh.Tokens = CodexTokenRefresh.refresh)
    {
        self.liveURL = liveURL
        self.storage = storage
        self.refresher = refresher
    }

    /// The account the CLI is signed in as.
    public func live() -> CodexAuthFile? {
        (try? Data(contentsOf: liveURL)).flatMap(CodexAuthFile.init)
    }

    public func accounts() -> [CodexAccount] {
        guard let raw = storage.read(account: Self.indexKey),
              let list = try? JSONDecoder().decode([CodexAccount].self, from: Data(raw.utf8))
        else { return [] }
        return list
    }

    func stored(_ id: String) -> CodexAuthFile? {
        storage.read(account: Self.blobKey(id)).flatMap { CodexAuthFile(Data($0.utf8)) }
    }

    /// Keeps the account the CLI is signed in as, or updates the copy kept.
    @discardableResult
    public func saveCurrent(now: Date = .now) throws -> CodexAccount {
        guard let live = live() else { throw CodexAccountError.notSignedIn }
        return try keep(live, now: now)
    }

    public func remove(_ id: String) {
        storage.delete(account: Self.blobKey(id))
        writeIndex(accounts().filter { $0.id != id })
    }

    /// Makes `id` the account the CLI is signed in as. The account being left
    /// is kept first, with whatever tokens the CLI last refreshed into the
    /// file, so switching never loses one. The file it replaces is left
    /// beside it as `auth.json.quotabar-backup`.
    public func switchTo(_ id: String, now: Date = .now) async throws {
        // Its refresh first, so the CLI gets the tokens that came back.
        if let running = refreshing[id] { _ = try? await running.value }
        guard let target = stored(id) else { throw CodexAccountError.notSaved }
        let current = live()
        if current?.accountID == id { return }
        if let current { try keep(current, now: now) }
        let directory = liveURL.deletingLastPathComponent()
        if let current {
            try write(current.data, to: directory.appendingPathComponent("auth.json.quotabar-backup"))
        }
        try write(target.data, to: liveURL)
    }

    /// The tokens to read `id` with. The account the CLI is signed in as is
    /// read from its file and left to the CLI to refresh; a kept one is
    /// refreshed here when it is near its end, and the new tokens kept.
    public func credentials(for id: String, now: Date = .now) async throws -> CodexAuthFile {
        if let live = live(), live.accountID == id { return live }
        if let running = refreshing[id] { return try await running.value }
        guard let file = stored(id) else { throw CodexAccountError.notSaved }
        guard file.needsRefresh(now: now) else { return file }
        let job = Task { try await self.refresh(file, now: now) }
        refreshing[id] = job
        defer { refreshing[id] = nil }
        return try await job.value
    }

    private func refresh(_ file: CodexAuthFile, now: Date) async throws -> CodexAuthFile {
        guard let refreshToken = file.refreshToken else { throw CodexAccountError.signInAgain(email: file.email) }
        let tokens: CodexTokenRefresh.Tokens
        do {
            tokens = try await refresher(refreshToken)
        } catch CodexAccountError.signInAgain {
            throw CodexAccountError.signInAgain(email: file.email)
        }
        guard let fresh = file.refreshed(with: tokens, now: now) else { throw ProviderError.badResponse }
        try keep(fresh, now: now)
        return fresh
    }

    // MARK: Storage

    @discardableResult
    private func keep(_ file: CodexAuthFile, now: Date) throws -> CodexAccount {
        guard storage.write(String(decoding: file.data, as: UTF8.self), account: Self.blobKey(file.accountID)) else {
            throw CodexAccountError.keychain
        }
        var list = accounts()
        var summary = file.summary
        if let index = list.firstIndex(where: { $0.id == file.accountID }) {
            summary.savedAt = list[index].savedAt
            list[index] = summary
        } else {
            summary.savedAt = now
            list.append(summary)
        }
        writeIndex(list)
        return summary
    }

    private func writeIndex(_ list: [CodexAccount]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        storage.write(String(decoding: data, as: UTF8.self), account: Self.indexKey)
    }

    /// Owner-only from the first byte, then moved into place in one step, so
    /// the CLI never reads half a file or one another user could read.
    private func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CodexAccountError.writeFailed(error.localizedDescription)
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).quotabar-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CodexAccountError.writeFailed(L10n.t("the folder is not writable", "文件夹不可写"))
        }
        if rename(temporary.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw CodexAccountError.writeFailed(reason)
        }
    }
}
