import CryptoKit
import Darwin
import Foundation

// MARK: - Antigravity's sign-in, renewed for QuotaBar's own reading

/// One of the Google OAuth clients the installed Antigravity carries.
public struct AntigravityClient: Sendable, Equatable {
    public let id: String
    public let secret: String
}

/// The network, clock and clients a renewal runs on; tests pass their own.
public struct AntigravityRenewalEnvironment: Sendable {
    public var send: HTTPSend
    public var now: @Sendable () -> Date
    /// The OAuth clients the installed app carries (`AntigravityClients`).
    public var clients: @Sendable () -> [AntigravityClient]
    public var renewal: AntigravityRenewal

    public init(
        send: @escaping HTTPSend = HTTP.live,
        now: @escaping @Sendable () -> Date = { Date() },
        clients: @escaping @Sendable () -> [AntigravityClient] = { AntigravityClients.installed() },
        renewal: AntigravityRenewal = .shared)
    {
        self.send = send
        self.now = now
        self.clients = clients
        self.renewal = renewal
    }

    public static var live: AntigravityRenewalEnvironment { AntigravityRenewalEnvironment() }
}

/// Antigravity saves its sign-in with an access token that lasts an hour and
/// renews it only while it runs, so with the app closed the card went dark
/// an hour after it was last open. The saved sign-in also holds a refresh
/// token: QuotaBar renews an access token of its own from it, at Google's
/// token endpoint, as the app's own OAuth client — read from the installed
/// app, never kept in this source — and holds it in memory only. Nothing of
/// Antigravity's is written: Google does not replace a refresh token when it
/// is used, so the app's sign-in carries on as it was.
public final class AntigravityRenewal: @unchecked Sendable {
    public static let shared = AntigravityRenewal()

    static let endpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// A renewed token is renewed again this long before it runs out.
    static let margin: TimeInterval = 120
    /// A renewal that failed is not tried again for this long.
    static let failureCooldown: TimeInterval = 120

    public enum Failure: Error, Equatable {
        /// Google turned the refresh token down: signed out, or revoked.
        case signInAgain
        /// None of the installed app's clients was accepted, or none found.
        case noClient
        /// The renewal did not go through (network, Google); retried later.
        case unavailable(String)
    }

    private struct Minted {
        let token: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var minted: [String: Minted] = [:]
    private var lastFailure: [String: Date] = [:]
    private var refused: Set<String> = []
    /// The client that renewed last, tried first next time.
    private var working: AntigravityClient?
    private let gate = Gate()

    public init() {}

    actor Gate {
        private var running: [String: Task<Result<String, Error>, Never>] = [:]

        func run(_ key: String, _ body: @escaping @Sendable () async throws -> String) async throws -> String {
            if let task = running[key] { return try await task.value.get() }
            let task = Task { () -> Result<String, Error> in
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            running[key] = task
            let result = await task.value
            running[key] = nil
            return try result.get()
        }
    }

    /// The refresh token is kept by its hash, never as itself.
    static func key(_ refreshToken: String) -> String {
        SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The token renewed earlier, while it has more than `margin` left.
    func cached(_ key: String, now: Date) -> String? {
        lock.withLock {
            guard let minted = minted[key], minted.expiresAt.timeIntervalSince(now) > Self.margin else { return nil }
            return minted.token
        }
    }

    /// Forgets a renewed token the API turned down before its time.
    public func discard(refreshToken: String) {
        _ = lock.withLock { minted.removeValue(forKey: Self.key(refreshToken)) }
    }

    /// An access token for the Cloud Code API, renewed from `refreshToken`
    /// when the last one has run out or is about to.
    public func accessToken(refreshToken: String, env: AntigravityRenewalEnvironment) async throws -> String {
        let key = Self.key(refreshToken)
        if let token = cached(key, now: env.now()) { return token }
        if lock.withLock({ refused.contains(key) }) { throw Failure.signInAgain }
        if let last = lock.withLock({ lastFailure[key] }), env.now().timeIntervalSince(last) < Self.failureCooldown {
            throw Failure.unavailable(L10n.t(
                "Renewing Antigravity's sign-in failed a moment ago; trying again shortly.",
                "刚才续期 Antigravity 登录没有成功，稍后会再试。"))
        }
        return try await gate.run(key) { [self] in
            try await renew(refreshToken: refreshToken, key: key, env: env)
        }
    }

    private enum Attempt {
        case renewed(token: String, expiresIn: TimeInterval)
        case refused
        case wrongClient
        case transient(String)
    }

    private func renew(refreshToken: String, key: String, env: AntigravityRenewalEnvironment) async throws -> String {
        if let token = cached(key, now: env.now()) { return token }
        var clients = env.clients()
        if let working = lock.withLock({ working }), let index = clients.firstIndex(of: working) {
            clients.insert(clients.remove(at: index), at: 0)
        }
        guard !clients.isEmpty else {
            lock.withLock { lastFailure[key] = env.now() }
            throw Failure.noClient
        }
        var sawRefusal = false
        for client in clients {
            switch await Self.attempt(client, refreshToken: refreshToken, env: env) {
            case let .renewed(token, expiresIn):
                lock.withLock {
                    minted[key] = Minted(token: token, expiresAt: env.now().addingTimeInterval(expiresIn))
                    working = client
                    lastFailure[key] = nil
                }
                return token
            case .refused:
                // A client the token was not issued to may say this too;
                // only no client taking it means the sign-in is gone.
                sawRefusal = true
            case .wrongClient:
                continue
            case let .transient(detail):
                lock.withLock { lastFailure[key] = env.now() }
                throw Failure.unavailable(detail)
            }
        }
        lock.withLock {
            lastFailure[key] = env.now()
            if sawRefusal { refused.insert(key) }
        }
        throw sawRefusal ? Failure.signInAgain : Failure.noClient
    }

    private static func attempt(_ client: AntigravityClient, refreshToken: String, env: AntigravityRenewalEnvironment) async -> Attempt {
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", client.id),
            ("client_secret", client.secret),
        ].map { "\($0.0)=\(MiniMaxCodeRenewal.formEncode($0.1))" }.joined(separator: "&")
        let response: HTTPResponse
        do {
            response = try await env.send("POST", endpoint, [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ], Data(form.utf8), 20)
        } catch {
            return .transient(L10n.t(
                "Could not reach Google to renew Antigravity's sign-in.", "连不上 Google，暂时无法续期 Antigravity 的登录。"))
        }
        return parse(response)
    }

    private static func parse(_ response: HTTPResponse) -> Attempt {
        let body = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
        if (200...299).contains(response.status),
           let token = (body["access_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
           let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0
        {
            return .renewed(token: token, expiresIn: expiresIn)
        }
        if response.status == 429 || response.status >= 500 {
            return .transient(L10n.t(
                "Google did not renew Antigravity's sign-in just now (HTTP \(response.status)).",
                "Google 暂时没有续期 Antigravity 的登录（HTTP \(response.status)）。"))
        }
        return body["error"] as? String == "invalid_grant" ? .refused : .wrongClient
    }
}

// MARK: - The installed app's OAuth clients

/// The Google OAuth clients inside the installed Antigravity's language
/// server — the program that signs in and renews for the app. Read where
/// they are, so nothing of the app's is copied into QuotaBar, and an update
/// that changes them is followed. Kept while the file stays the same.
public enum AntigravityClients {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: String, clients: [AntigravityClient])?

    public static func installed() -> [AntigravityClient] {
        for path in AntigravityLocal.appPaths {
            let binary = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/bin/language_server")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path) else { continue }
            let stamp = "\(binary.path)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if let cached = lock.withLock({ cache }), cached.stamp == stamp { return cached.clients }
            guard let data = try? Data(contentsOf: binary, options: .alwaysMapped) else { continue }
            let clients = clients(in: data)
            lock.withLock { cache = (stamp, clients) }
            if !clients.isEmpty { return clients }
        }
        return []
    }

    /// Every pairing of the client ids and secrets the file holds, each id
    /// first with the secret of the same rank — the file keeps them apart,
    /// so which belongs to which is found by asking.
    static func clients(in data: Data) -> [AntigravityClient] {
        let ids = unique(occurrences(of: ".apps.googleusercontent.com", in: data).flatMap { clientIDs(endingAt: $0, in: data) })
        let secrets = unique(occurrences(of: "GOCSPX-", in: data).compactMap { secret(at: $0, in: data) })
        var pairs: [AntigravityClient] = []
        for (rank, id) in ids.enumerated() {
            if rank < secrets.count { pairs.append(AntigravityClient(id: id, secret: secrets[rank])) }
        }
        for id in ids {
            for secret in secrets where !pairs.contains(AntigravityClient(id: id, secret: secret)) {
                pairs.append(AntigravityClient(id: id, secret: secret))
            }
        }
        return pairs
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Where `needle` starts, everywhere in `data`.
    static func occurrences(of needle: String, in data: Data) -> [Int] {
        let pattern = Array(needle.utf8)
        return data.withUnsafeBytes { buffer -> [Int] in
            guard let base = buffer.baseAddress, buffer.count >= pattern.count else { return [] }
            var found: [Int] = []
            var offset = 0
            while offset <= buffer.count - pattern.count {
                guard let hit = pattern.withUnsafeBytes({ memmem(base + offset, buffer.count - offset, $0.baseAddress, pattern.count) }) else { break }
                let position = base.distance(to: UnsafeRawPointer(hit))
                found.append(position)
                offset = position + pattern.count
            }
            return found
        }
    }

    /// `<project number>-<32 lowercase letters and digits>.apps.googleusercontent.com`,
    /// read back from where the suffix starts. A Go binary keeps its strings
    /// end to end, so the digits before may run on into the string before:
    /// the whole run and its last 12 — a project number's usual length — are
    /// both offered, and asking tells them apart.
    static func clientIDs(endingAt suffix: Int, in data: Data) -> [String] {
        let suffixLength = ".apps.googleusercontent.com".utf8.count
        guard suffix >= 34 + 6 else { return [] }
        let bytes = [UInt8](data[max(0, suffix - 60) ..< min(data.count, suffix + suffixLength)])
        let end = bytes.count - suffixLength
        let dash = end - 33
        guard dash > 0, bytes[dash] == UInt8(ascii: "-"), bytes[(dash + 1) ..< end].allSatisfy(isLowerAlnum) else { return [] }
        var first = dash
        while first > 0, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[first - 1]) { first -= 1 }
        let digits = dash - first
        guard digits >= 6 else { return [] }
        let tail = String(decoding: bytes[dash ..< bytes.count], as: UTF8.self)
        let whole = String(decoding: bytes[first ..< dash], as: UTF8.self)
        var candidates = [whole + tail]
        if digits > 12 { candidates.insert(String(whole.suffix(12)) + tail, at: 0) }
        return candidates
    }

    /// `GOCSPX-` and the 28 characters after it — the length Google gives
    /// them; whatever follows is the next string.
    static func secret(at start: Int, in data: Data) -> String? {
        guard start + 35 <= data.count else { return nil }
        let bytes = [UInt8](data[start ..< start + 35])
        let allowed = { (byte: UInt8) in
            isLowerAlnum(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
        guard bytes[7...].allSatisfy(allowed) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }
}
