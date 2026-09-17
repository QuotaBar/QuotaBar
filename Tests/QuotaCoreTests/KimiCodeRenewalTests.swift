import Darwin
import XCTest
@testable import QuotaCore

// MARK: - Test doubles

/// A network that records every request and answers from a script. Tokens
/// in these tests are made up.
final class ScriptedNetwork: @unchecked Sendable {
    struct Request {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let answer: @Sendable (Request) async throws -> HTTPResponse

    init(_ answer: @escaping @Sendable (Request) async throws -> HTTPResponse) {
        self.answer = answer
    }

    var requests: [Request] { lock.withLock { recorded } }
    var posts: [Request] { requests.filter { $0.method == "POST" } }
    var gets: [Request] { requests.filter { $0.method == "GET" } }

    var send: HTTPSend {
        { [self] method, url, headers, body, _ in
            let request = Request(method: method, url: url, headers: headers, body: String(decoding: body ?? Data(), as: UTF8.self))
            lock.withLock { recorded.append(request) }
            return try await answer(request)
        }
    }

    static func json(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, data: Data(text.utf8))
    }
}

/// Starts at the real time — lock directories carry real mtimes — and moves
/// only when slept on, so waits cost nothing.
final class SteppedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []
    /// Runs on every sleep, after the clock has moved.
    var onSleep: (@Sendable () -> Void)?

    init(_ start: Date = Date()) {
        current = start
    }

    var sleeps: [TimeInterval] { lock.withLock { slept } }

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            lock.withLock {
                current = current.addingTimeInterval(seconds)
                slept.append(seconds)
            }
            onSleep?()
        }
    }
}

enum KimiFixtures {
    static let globalName = "kimi-code-env-0e4f99c69cc27850"

    static func jwt(exp: Int, type: String) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"type\":\"\(type)\",\"exp\":\(exp)}")).c2ln"
    }

    static let globalConfig = """
        default_model = "kimi-code/kimi-for-coding"

        [providers."managed:kimi-code"]
        base_url = "https://api.kimi.ai/coding/v1"
        type = "kimi"

        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code-env-0e4f99c69cc27850"
        oauth_host = "https://auth.kimi.ai"

        [models."kimi-code/kimi-for-coding"]
        provider = "managed:kimi-code"
        """

    static let usages = #"{"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2026-09-17T11:51:33Z"}},"user":{"membership":{"level":"LEVEL_INTERMEDIATE"}}}"#
}

// MARK: - Renewal

/// Renewing the Kimi Code sign-in under Kimi Code's lock, in throwaway homes
/// laid out like `~/.kimi-code`, with a scripted network and clock.
final class KimiCodeRenewalTests: XCTestCase {
    private var root: URL!
    private var codeHome: URL { root.appendingPathComponent(".kimi-code") }
    private var legacyHome: URL { root.appendingPathComponent(".kimi") }
    private var credentials: URL { codeHome.appendingPathComponent("credentials/\(KimiFixtures.globalName).json") }
    private var lockDirectory: URL { codeHome.appendingPathComponent("oauth/\(KimiFixtures.globalName).lock") }
    private var clock: SteppedClock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KimiCodeRenewalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codeHome, withIntermediateDirectories: true)
        clock = SteppedClock()
        try KimiFixtures.globalConfig.write(to: codeHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "3f1c2e4a-0000-4000-8000-00000000abcd\n".write(to: codeHome.appendingPathComponent("device_id"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var nowSeconds: Int { Int(clock.now().timeIntervalSince1970) }
    private lazy var refreshToken = KimiFixtures.jwt(exp: Int(Date().timeIntervalSince1970) + 30 * 86_400, type: "refresh")
    private lazy var rotatedRefresh = KimiFixtures.jwt(exp: Int(Date().timeIntervalSince1970) + 30 * 86_400 + 1, type: "refresh")

    /// The file as Kimi Code writes it, expiring `expiresIn` seconds from now.
    @discardableResult
    private func writeCredentials(access: String = "old-access", refresh: String? = nil, expiresIn: Int) throws -> String {
        let text = KimiCodeTokenFile.render(
            accessToken: access, refreshToken: refresh ?? refreshToken,
            expiresAt: Double(nowSeconds + expiresIn), scope: "kimi-code", tokenType: "Bearer", expiresIn: 900)
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: credentials, atomically: false, encoding: .utf8)
        return text
    }

    private func environment(_ network: ScriptedNetwork, lockWait: TimeInterval = 3, renewal: KimiCodeRenewal = KimiCodeRenewal()) -> KimiCodeEnvironment {
        KimiCodeEnvironment(
            codeHome: codeHome, legacyHome: legacyHome, send: network.send,
            now: clock.now, sleep: clock.sleep, lockWait: lockWait, appVersion: "9.9.9", renewal: renewal)
    }

    private func fileText() throws -> String {
        try String(contentsOf: credentials, encoding: .utf8)
    }

    /// A renewal reply and the usage reply, whatever the order.
    private func renewingNetwork(access: String = "new-access", refresh: String? = nil) -> ScriptedNetwork {
        let refresh = refresh ?? rotatedRefresh
        return ScriptedNetwork { request in
            if request.method == "POST" {
                return ScriptedNetwork.json(200, #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":900,"scope":"kimi-code","token_type":"Bearer"}"#)
            }
            return ScriptedNetwork.json(200, KimiFixtures.usages)
        }
    }

    private func sessionExpiredMessage(_ error: Error) -> String? {
        if case let ProviderError.sessionExpired(message) = error { return message }
        return nil
    }

    // MARK: The happy path

    func testRenewsAnAlmostExpiredTokenThenReadsTheQuotaWithIt() async throws {
        try writeCredentials(expiresIn: 40)
        let network = renewingNetwork()
        let snapshot = try await KimiProvider.fetchLocal(environment(network))

        // One renewal, exactly as Kimi Code sends it but for the product name.
        let post = try XCTUnwrap(network.posts.first)
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertEqual(post.url.absoluteString, "https://auth.kimi.ai/api/oauth/token")
        XCTAssertEqual(post.body, "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=\(refreshToken)")
        XCTAssertEqual(post.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(post.headers["Accept"], "application/json")
        XCTAssertEqual(post.headers["User-Agent"], "QuotaBar/9.9.9")
        XCTAssertEqual(post.headers["X-Msh-Platform"], "kimi_code_cli")
        XCTAssertEqual(post.headers["X-Msh-Version"], "9.9.9")
        XCTAssertEqual(post.headers["X-Msh-Device-Id"], "3f1c2e4a-0000-4000-8000-00000000abcd")
        XCTAssertTrue(post.headers["X-Msh-Device-Model"]?.hasPrefix("macOS ") == true)
        XCTAssertNotNil(post.headers["X-Msh-Device-Name"])
        XCTAssertNotNil(post.headers["X-Msh-Os-Version"])

        // Then the quota, with the new token, from the global edition.
        let get = try XCTUnwrap(network.gets.first)
        XCTAssertEqual(get.url.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        XCTAssertEqual(get.headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(snapshot.edition, KimiEdition.global.label)
        XCTAssertEqual(snapshot.chipLabel, "Allegretto · \(KimiEdition.global.label)")
        XCTAssertEqual(snapshot.windows.first?.usedPercent ?? -1, 25, accuracy: 0.001)

        // Saved in Kimi Code's own format, byte for byte.
        XCTAssertEqual(try fileText(), """
            {
              "access_token": "new-access",
              "refresh_token": "\(rotatedRefresh)",
              "expires_at": \(nowSeconds + 900),
              "scope": "kimi-code",
              "token_type": "Bearer",
              "expires_in": 900
            }

            """)
        let attributes = try FileManager.default.attributesOfItem(atPath: credentials.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: credentials.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["\(KimiFixtures.globalName).json"])

        // The lock is given back; its sentinel stays, as Kimi Code leaves it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codeHome.appendingPathComponent("oauth/\(KimiFixtures.globalName)").path))
    }

    func testAFreshTokenIsUsedAsItIs() async throws {
        let before = try writeCredentials(expiresIn: 600)
        let network = renewingNetwork()
        _ = try await KimiProvider.fetchLocal(environment(network))
        XCTAssertTrue(network.posts.isEmpty)
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer old-access")
        XCTAssertEqual(try fileText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeHome.appendingPathComponent("oauth").path))
    }

    /// A 401 on a token that should still be good: renewed once, read once more.
    func testARejectedFreshTokenIsRenewedOnce() async throws {
        try writeCredentials(expiresIn: 600)
        let network = ScriptedNetwork { request in
            if request.method == "POST" {
                return ScriptedNetwork.json(200, #"{"access_token":"new-access","refresh_token":"r2","expires_in":900}"#)
            }
            return request.headers["Authorization"] == "Bearer new-access"
                ? ScriptedNetwork.json(200, KimiFixtures.usages)
                : ScriptedNetwork.json(401, "{}")
        }
        _ = try await KimiProvider.fetchLocal(environment(network))
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertEqual(network.gets.map { $0.headers["Authorization"] }, ["Bearer old-access", "Bearer new-access"])
    }

    // MARK: Keys Kimi Code does not know are kept

    func testRewritingKeepsKeysKimiCodeDoesNotKnow() async throws {
        let original = """
            {
              "access_token": "old-access",
              "refresh_token": "\(refreshToken)",
              "extra": {"b": [1, 2.5, true, null], "a": "x/y"},
              "expires_at": \(nowSeconds + 10),
              "scope": "kimi-code",
              "token_type": "Bearer",
              "expires_in": 900,
              "note": "caf\u{00E9} \\"quoted\\""
            }
            """
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: credentials, atomically: false, encoding: .utf8)
        _ = try await KimiProvider.fetchLocal(environment(renewingNetwork(refresh: "r/2")))
        XCTAssertEqual(try fileText(), """
            {
              "access_token": "new-access",
              "refresh_token": "r/2",
              "expires_at": \(nowSeconds + 900),
              "scope": "kimi-code",
              "token_type": "Bearer",
              "expires_in": 900,
              "extra": {
                "a": "x/y",
                "b": [
                  1,
                  2.5,
                  true,
                  null
                ]
              },
              "note": "caf\u{00E9} \\"quoted\\""
            }

            """)
    }

    // MARK: Someone else renewed first

    /// Kimi Code renews while QuotaBar waits for its lock: the wait ends, the
    /// new token is used, nothing is sent and the lock is left alone.
    func testARenewalLandingDuringTheWaitEndsIt() async throws {
        try writeCredentials(expiresIn: 30)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let heldMtime = try mtime(lockDirectory)
        let renewedAccess = "kimi-renewed-access"
        let rotated = rotatedRefresh
        let target = credentials
        let clock = self.clock!
        clock.onSleep = {
            let text = KimiCodeTokenFile.render(
                accessToken: renewedAccess, refreshToken: rotated,
                expiresAt: Double(Int(clock.now().timeIntervalSince1970) + 900), scope: "kimi-code", tokenType: "Bearer", expiresIn: 900)
            try? text.write(to: target, atomically: true, encoding: .utf8)
        }
        let network = renewingNetwork()
        _ = try await KimiProvider.fetchLocal(environment(network))
        XCTAssertTrue(network.posts.isEmpty)
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer \(renewedAccess)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockDirectory.path))
        XCTAssertEqual(try mtime(lockDirectory), heldMtime)
    }

    /// Kimi Code renewed between QuotaBar's first look and taking the lock:
    /// the look under the lock finds it done.
    func testTheReadUnderTheLockSkipsARenewalAlreadyDone() async throws {
        try writeCredentials(expiresIn: 30)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let rotated = rotatedRefresh
        let target = credentials
        let lock = lockDirectory
        let clock = self.clock!
        clock.onSleep = {
            // Kimi Code finishes: saves, then gives the lock back.
            let text = KimiCodeTokenFile.render(
                accessToken: "kimi-renewed-access", refreshToken: rotated,
                expiresAt: Double(Int(clock.now().timeIntervalSince1970) + 900), scope: "kimi-code", tokenType: "Bearer", expiresIn: 900)
            try? text.write(to: target, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: lock)
        }
        let renewal = KimiCodeRenewal()
        let network = renewingNetwork()
        let session = try XCTUnwrap(LocalCredentials.kimiCodeSession(codeHome: codeHome, legacyHome: legacyHome, now: clock.now()))
        guard case let .renewable(context) = KimiCodeRenewal.renewability(of: session, codeHome: codeHome, now: clock.now()) else {
            return XCTFail("expected a renewable sign-in")
        }
        // The file is renewed before the next attempt at the lock, which
        // then succeeds: the answer comes from the look under the lock.
        let outcome = try await renewal.accessToken(context, environment: environment(network, renewal: renewal))
        XCTAssertEqual(outcome, KimiCodeRenewal.Outcome(accessToken: "kimi-renewed-access", renewedHere: false))
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
    }

    /// A fresh lock held the whole wait: no renewal, no write, the lock
    /// untouched, and a message that it will be tried again.
    func testALockHeldThroughoutMeansNoRenewalAndNoWrite() async throws {
        let before = try writeCredentials(expiresIn: -120)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let heldMtime = try mtime(lockDirectory)
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network, lockWait: 3))
            XCTFail("expected an error")
        } catch ProviderError.unavailable(let message) {
            XCTAssertEqual(message, KimiProvider.renewalBusyHint)
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(try fileText(), before)
        XCTAssertEqual(try mtime(lockDirectory), heldMtime)
        // Waited in Kimi Code's steps, and gave up.
        XCTAssertEqual(clock.sleeps, Array(repeating: 0.5, count: 6))
    }

    /// A lock left by a Kimi Code that died is taken over once it has stayed
    /// stale, and the renewal goes ahead.
    func testAStaleLockIsTakenOver() async throws {
        try writeCredentials(expiresIn: -120)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        try setMtime(lockDirectory, secondsAgo: 30)
        let network = renewingNetwork()
        _ = try await KimiProvider.fetchLocal(environment(network, lockWait: 5))
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
        XCTAssertTrue(try fileText().contains("\"new-access\""))
    }

    // MARK: Refusals

    /// Refused, but Kimi Code had rotated the token meanwhile: its token is
    /// used and QuotaBar writes nothing.
    func testARefusalWithARotatedFileOnDiskUsesTheNewToken() async throws {
        try writeCredentials(expiresIn: -60)
        let rotated = rotatedRefresh
        let target = credentials
        let kimiWrote = KimiCodeTokenFile.render(
            accessToken: "kimi-renewed-access", refreshToken: rotated,
            expiresAt: Double(nowSeconds + 900), scope: "kimi-code", tokenType: "Bearer", expiresIn: 900)
        let network = ScriptedNetwork { request in
            if request.method == "POST" {
                try kimiWrote.write(to: target, atomically: true, encoding: .utf8)
                return ScriptedNetwork.json(400, #"{"error":"invalid_grant","error_description":"The provided authorization grant is invalid"}"#)
            }
            return ScriptedNetwork.json(200, KimiFixtures.usages)
        }
        _ = try await KimiProvider.fetchLocal(environment(network))
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer kimi-renewed-access")
        XCTAssertEqual(try fileText(), kimiWrote)
        XCTAssertEqual(clock.sleeps, [0.1])
    }

    /// Refused for good: nothing written — no signed-out marker either — the
    /// owner told to sign in again, and the same token not sent again.
    func testARefusalWithoutRotationWritesNothingAndSaysToSignInAgain() async throws {
        for status in [401, 403, 400] {
            // A fresh home and a fresh memory of refusals for each status.
            try tearDownWithError()
            try setUpWithError()
            let renewal = KimiCodeRenewal()
            let before = try writeCredentials(expiresIn: -60)
            let network = ScriptedNetwork { request in
                request.method == "POST"
                    ? ScriptedNetwork.json(status, status == 400 ? #"{"error":"invalid_grant"}"# : "{}")
                    : ScriptedNetwork.json(200, KimiFixtures.usages)
            }
            do {
                _ = try await KimiProvider.fetchLocal(environment(network, renewal: renewal))
                XCTFail("expected an error for \(status)")
            } catch {
                XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.signInAgainHint, "\(status)")
            }
            XCTAssertEqual(network.posts.count, 1, "\(status)")
            XCTAssertTrue(network.gets.isEmpty, "\(status)")
            XCTAssertEqual(try fileText(), before, "\(status)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path), "\(status)")

            // The refused token is remembered for a while: no second request.
            let again = renewingNetwork()
            do {
                _ = try await KimiProvider.fetchLocal(environment(again, renewal: renewal))
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.signInAgainHint)
            }
            XCTAssertTrue(again.requests.isEmpty)
        }
    }

    /// Past its 30 days, a refresh token is not sent.
    func testAnExpiredRefreshTokenSendsNothing() async throws {
        let dead = KimiFixtures.jwt(exp: nowSeconds - 3_600, type: "refresh")
        let before = try writeCredentials(refresh: dead, expiresIn: -60)
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.signInAgainHint)
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(try fileText(), before)
    }

    // MARK: Network and server failures

    /// Three tries a second and two apart, then an error that keeps the last
    /// reading; nothing written.
    func testServerFailuresAreRetriedThenReportedWithoutWriting() async throws {
        let before = try writeCredentials(expiresIn: -60)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(503, "busy") }
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch ProviderError.unavailable(let message) {
            XCTAssertEqual(message, KimiProvider.renewalFailedHint("HTTP 503"))
        }
        XCTAssertEqual(network.posts.count, 3)
        XCTAssertTrue(network.gets.isEmpty)
        XCTAssertEqual(clock.sleeps, [1, 2])
        XCTAssertEqual(try fileText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
    }

    func testNetworkErrorsAreRetriedToo() async throws {
        try writeCredentials(expiresIn: -60)
        let network = ScriptedNetwork { _ in throw ProviderError.network("offline") }
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch ProviderError.unavailable(_) {}
        XCTAssertEqual(network.posts.count, 3)
    }

    /// A renewal that cannot happen right now leaves a token with a little
    /// time left good for this read.
    func testATokenWithTimeLeftIsStillReadWhenRenewalFails() async throws {
        try writeCredentials(expiresIn: 50)
        let network = ScriptedNetwork { request in
            request.method == "POST" ? ScriptedNetwork.json(502, "") : ScriptedNetwork.json(200, KimiFixtures.usages)
        }
        let snapshot = try await KimiProvider.fetchLocal(environment(network))
        XCTAssertEqual(network.posts.count, 3)
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer old-access")
        XCTAssertFalse(snapshot.windows.isEmpty)
    }

    // MARK: What may be renewed at all

    func testOnlyTheSignInKimiCodeUsesIsRenewed() async throws {
        let before = try writeCredentials(expiresIn: -60)
        try "[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n"
            .write(to: codeHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.expiredHint(.readOnly(.notInUse)))
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(try fileText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeHome.appendingPathComponent("oauth").path))
    }

    func testNoDeviceIDMeansNoRenewalAndNoneIsCreated() async throws {
        try writeCredentials(expiresIn: -60)
        try FileManager.default.removeItem(at: codeHome.appendingPathComponent("device_id"))
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.expiredHint(.readOnly(.noDeviceID)))
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeHome.appendingPathComponent("device_id").path))
    }

    /// The older Python CLI's file is only ever read, even with Kimi Code's
    /// config and device id around it.
    func testTheOlderCLIsFileIsNeverRenewed() async throws {
        try FileManager.default.removeItem(at: codeHome.appendingPathComponent("config.toml"))
        try FileManager.default.createDirectory(at: legacyHome.appendingPathComponent("credentials"), withIntermediateDirectories: true)
        let legacy = legacyHome.appendingPathComponent("credentials/kimi-code.json")
        let text = #"{"access_token": "legacy", "refresh_token": "\#(refreshToken)", "expires_at": \#(nowSeconds - 60).5, "expires_in": 900.0}"#
        try text.write(to: legacy, atomically: false, encoding: .utf8)
        let session = try XCTUnwrap(LocalCredentials.kimiCodeSession(codeHome: codeHome, legacyHome: legacyHome, now: clock.now()))
        XCTAssertTrue(session.isLegacy)
        guard case .readOnly(.olderCLI) = KimiCodeRenewal.renewability(of: session, codeHome: codeHome, now: clock.now()) else {
            return XCTFail("the older CLI's sign-in must be read only")
        }
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.expiredHint(.readOnly(.olderCLI)))
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeHome.appendingPathComponent("oauth").path))
    }

    /// A sign-in removed while QuotaBar waited is not brought back.
    func testASignOutDuringTheWaitIsRespected() async throws {
        try writeCredentials(expiresIn: -60)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let target = credentials
        let lock = lockDirectory
        clock.onSleep = {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: lock)
        }
        let network = renewingNetwork()
        do {
            _ = try await KimiProvider.fetchLocal(environment(network))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(sessionExpiredMessage(error), KimiProvider.signInAgainHint)
        }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: One at a time

    func testConcurrentReadsRenewOnce() async throws {
        try writeCredentials(expiresIn: -60)
        let renewal = KimiCodeRenewal()
        let rotated = rotatedRefresh
        let network = ScriptedNetwork { request in
            if request.method == "POST" {
                try await Task.sleep(nanoseconds: 50_000_000)
                return ScriptedNetwork.json(200, #"{"access_token":"new-access","refresh_token":"\#(rotated)","expires_in":900}"#)
            }
            return ScriptedNetwork.json(200, KimiFixtures.usages)
        }
        let env = environment(network, renewal: renewal)
        async let first = KimiProvider.fetchLocal(env)
        async let second = KimiProvider.fetchLocal(env)
        async let third = KimiProvider.fetchLocal(env)
        _ = try await (first, second, third)
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertEqual(Set(network.gets.compactMap { $0.headers["Authorization"] }), ["Bearer new-access"])
    }

    // MARK: Helpers

    private func mtime(_ url: URL) throws -> Int64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return KimiCodeLock.milliseconds(info.st_mtimespec)
    }

    private func setMtime(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path)
    }
}

// MARK: - The lock on its own

final class KimiCodeLockTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("kimi-code.lock") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KimiCodeLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        KimiCodeLock.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }

    private func attempt(now: Date = Date(), sighting: inout KimiCodeLock.StaleSighting?, touch: TimeInterval = 2.5) -> KimiCodeLock.Attempt {
        KimiCodeLock.attempt(directory: directory, now: now, sighting: &sighting, touchInterval: touch)
    }

    private func mtime() -> Int64? {
        var info = stat()
        guard stat(directory.path, &info) == 0 else { return nil }
        return KimiCodeLock.milliseconds(info.st_mtimespec)
    }

    func testAcquireHoldAndRelease() throws {
        var sighting: KimiCodeLock.StaleSighting?
        guard case let .acquired(lock) = attempt(sighting: &sighting) else { return XCTFail("expected the lock") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        // Held: anyone else is turned away.
        guard case .locked = attempt(sighting: &sighting) else { return XCTFail("expected locked") }
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        lock.release()
        guard case let .acquired(again) = attempt(sighting: &sighting) else { return XCTFail("expected the lock again") }
        again.release()
    }

    /// Someone else's fresh lock is never touched, however often it is tried.
    func testAFreshLockIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let before = mtime()
        var sighting: KimiCodeLock.StaleSighting?
        for step in 0..<10 {
            guard case .locked = attempt(now: Date().addingTimeInterval(Double(step) * 0.4), sighting: &sighting) else {
                return XCTFail("expected locked at step \(step)")
            }
        }
        XCTAssertEqual(mtime(), before)
    }

    /// Stale means untouched for over five seconds, and QuotaBar takes it
    /// only once it has stayed so, unchanged, for a second.
    func testAStaleLockIsTakenOverAfterASecondLook() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: directory.path)
        let now = Date()
        var sighting: KimiCodeLock.StaleSighting?
        guard case .locked = attempt(now: now, sighting: &sighting) else { return XCTFail("first look only notes it") }
        guard case .locked = attempt(now: now.addingTimeInterval(0.5), sighting: &sighting) else { return XCTFail("too soon") }
        guard case let .acquired(lock) = attempt(now: now.addingTimeInterval(1.1), sighting: &sighting) else {
            return XCTFail("expected a takeover")
        }
        XCTAssertGreaterThan(mtime() ?? 0, KimiCodeLock.milliseconds(now) - 1_000)
        lock.release()
    }

    /// A lock that comes back to life between two looks is not taken.
    func testALockTouchedBetweenLooksIsNotTaken() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: directory.path)
        let now = Date()
        var sighting: KimiCodeLock.StaleSighting?
        _ = attempt(now: now, sighting: &sighting)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        guard case .locked = attempt(now: now.addingTimeInterval(1.5), sighting: &sighting) else { return XCTFail("expected locked") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Held, the directory's mtime keeps moving, so Kimi Code never takes it for stale.
    func testTheHolderTouchesTheLock() throws {
        var sighting: KimiCodeLock.StaleSighting?
        guard case let .acquired(lock) = attempt(sighting: &sighting, touch: 0.05) else { return XCTFail("expected the lock") }
        let first = mtime()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(mtime() ?? 0, first ?? .max)
        XCTAssertFalse(lock.isCompromised)
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Someone else touched it: compromised, and not removed on release.
    func testALockSomeoneElseTouchedIsCompromisedAndLeftInPlace() throws {
        var sighting: KimiCodeLock.StaleSighting?
        guard case let .acquired(lock) = attempt(sighting: &sighting, touch: 0.05) else { return XCTFail("expected the lock") }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3)], ofItemAtPath: directory.path)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(lock.isCompromised)
        lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Released only while still its own: a lock since taken by someone else stays.
    func testReleaseLeavesALockThatPassedToSomeoneElse() throws {
        var sighting: KimiCodeLock.StaleSighting?
        guard case let .acquired(lock) = attempt(sighting: &sighting) else { return XCTFail("expected the lock") }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: directory.path)
        lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}

// MARK: - Files, config and requests

final class KimiCodeFormatTests: XCTestCase {
    func testRenderMatchesJSONStringify() {
        XCTAssertEqual(
            KimiCodeTokenFile.render(
                accessToken: "a/b\"c\\d\ne\u{01}", refreshToken: "r", expiresAt: 1_800_000_900,
                scope: "kimi-code", tokenType: "Bearer", expiresIn: 900),
            "{\n  \"access_token\": \"a/b\\\"c\\\\d\\ne\\u0001\",\n  \"refresh_token\": \"r\",\n  \"expires_at\": 1800000900,\n"
                + "  \"scope\": \"kimi-code\",\n  \"token_type\": \"Bearer\",\n  \"expires_in\": 900\n}\n")
        XCTAssertEqual(KimiCodeTokenFile.jsNumber(900), "900")
        XCTAssertEqual(KimiCodeTokenFile.jsNumber(1_800_000_900.5), "1800000900.5")
        XCTAssertEqual(KimiCodeTokenFile.jsNumber(-0.0), "0")
        XCTAssertEqual(KimiCodeTokenFile.jsNumber(1e-7), "1e-7")
        XCTAssertEqual(KimiCodeTokenFile.jsNumber(.nan), "null")
    }

    func testTopLevelKeyOrder() {
        XCTAssertEqual(
            KimiCodeTokenFile.topLevelKeys(#"{"b": {"x": 1, "y": "{,}"}, "a\"q": [1, {"z": 2}], "c": "d"}"#),
            ["b", "a\"q", "c"])
    }

    /// Written through a temporary file and a rename: a new file, 0600, in a
    /// 0700 directory, with nothing left beside it.
    func testWriteIsAtomicAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KimiCodeFormatTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("credentials/kimi-code.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: file, atomically: false, encoding: .utf8)
        chmod(file.deletingLastPathComponent().path, 0o755)
        let inodeBefore = (try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.intValue

        try KimiCodeTokenFile.write("new\n", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual((attributes[.systemFileNumber] as? NSNumber)?.intValue, inodeBefore)
        let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["kimi-code.json"])
    }

    func testConfigTomlNamesTheSignInInUse() {
        func signIn(_ toml: String) -> KimiCodeConfig.ManagedSignIn? { KimiCodeConfig.managedSignIn(toml: toml) }

        XCTAssertEqual(signIn(KimiFixtures.globalConfig), KimiCodeConfig.ManagedSignIn(
            storageName: "kimi-code-env-0e4f99c69cc27850", oauthHost: "https://auth.kimi.ai", baseURL: "https://api.kimi.ai/coding/v1"))
        // A China sign-in writes no oauth_host.
        XCTAssertEqual(signIn("""
            [providers."managed:kimi-code"]
            base_url = "https://api.kimi.com/coding/v1" # comment
            [providers."managed:kimi-code".oauth]
            storage = "file"
            key = 'oauth/kimi-code'
            """), KimiCodeConfig.ManagedSignIn(storageName: "kimi-code", oauthHost: nil, baseURL: "https://api.kimi.com/coding/v1"))
        // Inline and dotted forms.
        XCTAssertEqual(signIn("""
            [providers.'managed:kimi-code']
            oauth = { storage = "file", key = "oauth/kimi-code-env-0e4f99c69cc27850", oauth_host = "https://auth.kimi.ai" }
            """)?.oauthHost, "https://auth.kimi.ai")
        XCTAssertEqual(signIn("""
            [providers]
            "managed:kimi-code".oauth.key = "oauth/kimi-code"
            """)?.storageName, "kimi-code")
        // Signed out, or another provider's table.
        XCTAssertNil(signIn(""))
        XCTAssertNil(signIn("""
            [providers."other".oauth]
            key = "oauth/kimi-code"
            """))
    }

    func testOnlyKnownHostsMakeAnActiveSlot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KimiCodeFormatTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func slot(_ toml: String) throws -> KimiCodeSlot? {
            try toml.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            return KimiCodeConfig.activeSlot(codeHome: root)
        }
        XCTAssertEqual(try slot(KimiFixtures.globalConfig)?.edition, .global)
        XCTAssertEqual(try slot("[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n")?.edition, .china)
        XCTAssertNil(try slot("[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\noauth_host = \"https://auth.example.com\"\n"))
        XCTAssertNil(try slot("[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code-env-deadbeefdeadbeef\"\n"))
        XCTAssertNil(try slot("[providers.\"managed:kimi-code\"]\nbase_url = \"https://api.example.com/v1\"\n[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n"))
    }

    func testFormBodyEncodesLikeURLSearchParams() {
        XCTAssertEqual(KimiCodeRenewal.formBody([("a b", "x/y+z*-._~é")]), "a+b=x%2Fy%2Bz*-._%7E%C3%A9")
    }

    func testTokenReplyIsCheckedLikeKimiCode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000.7)
        let good = KimiCodeRenewal.token(from: ["access_token": "a", "refresh_token": "r", "expires_in": "900"], now: now)
        XCTAssertEqual(good?.expiresAt, 1_800_000_900)
        XCTAssertEqual(good?.scope, "")
        XCTAssertEqual(good?.tokenType, "Bearer")
        XCTAssertNil(KimiCodeRenewal.token(from: ["access_token": "a", "expires_in": 900], now: now))
        XCTAssertNil(KimiCodeRenewal.token(from: ["access_token": "a", "refresh_token": "", "expires_in": 900], now: now))
        XCTAssertNil(KimiCodeRenewal.token(from: ["access_token": "a", "refresh_token": "r", "expires_in": 0], now: now))
        XCTAssertNil(KimiCodeRenewal.token(from: ["access_token": "", "refresh_token": "r", "expires_in": 900], now: now))
    }

    func testEditions() {
        XCTAssertEqual(KimiEdition.global.usagesURL.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        XCTAssertEqual(KimiEdition.china.consoleURL.absoluteString, "https://www.kimi.com/code/console")
        XCTAssertEqual(KimiEdition.global.consoleURL.absoluteString, "https://www.kimi.ai/code/console")
        XCTAssertEqual(LocalCredentials.kimiCodeSlots["kimi-code-env-0e4f99c69cc27850"]?.oauthHost, "https://auth.kimi.ai")
        XCTAssertEqual(LocalCredentials.kimiCodeSlots["kimi-code"]?.edition, .china)
    }
}

// MARK: - Pasted credentials

final class KimiPastedCredentialTests: XCTestCase {
    private let cookieJWT = KimiFixtures.jwt(exp: 1_900_000_000, type: "access")

    func testTellsCookiesFromAPIKeys() {
        XCTAssertEqual(KimiPastedCredential.classify(" \(cookieJWT)\n"), .cookie(cookieJWT))
        XCTAssertEqual(KimiPastedCredential.classify("kimi-auth=\(cookieJWT)"), .cookie(cookieJWT))
        XCTAssertEqual(KimiPastedCredential.classify("Cookie: theme=dark; kimi-auth=\(cookieJWT); lang=zh"), .cookie(cookieJWT))
        XCTAssertEqual(KimiPastedCredential.classify("curl -H 'cookie: kimi-auth=\(cookieJWT)'"), .cookie(cookieJWT))
        XCTAssertEqual(KimiPastedCredential.classify("Cookie: theme=dark; lang=zh"), .cookieWithoutToken)
        XCTAssertEqual(KimiPastedCredential.classify("theme=dark; lang=zh"), .cookieWithoutToken)
        XCTAssertEqual(KimiPastedCredential.classify("sk-kimi-0123456789abcdef"), .apiKey("sk-kimi-0123456789abcdef"))
        XCTAssertEqual(KimiPastedCredential.classify("Bearer sk-kimi-0123456789abcdef"), .apiKey("sk-kimi-0123456789abcdef"))
        // Three dotted parts that are no JWT.
        XCTAssertEqual(KimiPastedCredential.classify("abc.def.ghi"), .apiKey("abc.def.ghi"))
        XCTAssertEqual(KimiPastedCredential.classify("key=="), .apiKey("key=="))
    }

    func testFingerprintsDoNotRevealTheSecret() {
        let fingerprint = KimiPastedCredential.fingerprint("sk-kimi-secret")
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertFalse(fingerprint.contains("secret"))
        XCTAssertEqual(fingerprint, KimiPastedCredential.fingerprint("sk-kimi-secret"))
    }
}

/// A Kimi Code API key, through the provider as Settings uses it.
final class KimiAPIKeyTests: XCTestCase {
    private var root: URL!
    private var config: ConfigStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KimiAPIKeyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config = ConfigStore(fileURL: root.appendingPathComponent("config.json"), credentials: MemoryCredentialStorage())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func provider(_ network: ScriptedNetwork) -> KimiProvider {
        KimiProvider(environment: KimiCodeEnvironment(
            codeHome: root.appendingPathComponent(".kimi-code"), legacyHome: root.appendingPathComponent(".kimi"),
            send: network.send, sleep: { _ in }, appVersion: "test", renewal: KimiCodeRenewal()))
    }

    /// A global key: refused by kimi.com, read from kimi.ai — and next time
    /// kimi.ai is asked straight away.
    func testAGlobalKeyIsFoundOnKimiAIAndRemembered() async throws {
        let key = "sk-kimi-\(UUID().uuidString)"
        config.setCredential(key, for: .kimi)
        let network = ScriptedNetwork { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(key)")
            return request.url.host == "api.kimi.ai"
                ? ScriptedNetwork.json(200, KimiFixtures.usages)
                : ScriptedNetwork.json(401, #"{"error":{"type":"invalid_authentication_error"}}"#)
        }
        let kimi = provider(network)
        XCTAssertEqual(kimi.sourceInfo(config: config)?.consoleURL, nil)
        let snapshot = try await kimi.fetch(config: config)
        XCTAssertEqual(network.gets.map { $0.url.absoluteString }, [
            "https://api.kimi.com/coding/v1/usages", "https://api.kimi.ai/coding/v1/usages",
        ])
        XCTAssertEqual(snapshot.edition, KimiEdition.global.label)
        XCTAssertEqual(snapshot.source, L10n.t("API key", "API Key"))

        _ = try await kimi.fetch(config: config)
        XCTAssertEqual(network.gets.count, 3)
        XCTAssertEqual(network.gets.last?.url.host, "api.kimi.ai")

        let info = try XCTUnwrap(kimi.sourceInfo(config: config))
        XCTAssertEqual(info.consoleURL, KimiEdition.global.consoleURL)
        XCTAssertTrue(info.summary.contains("kimi.ai"))
    }

    func testAChinaKeyIsReadFromKimiCom() async throws {
        let key = "sk-kimi-\(UUID().uuidString)"
        config.setCredential(key, for: .kimi)
        let network = ScriptedNetwork { request in
            request.url.host == "api.kimi.com" ? ScriptedNetwork.json(200, KimiFixtures.usages) : ScriptedNetwork.json(401, "{}")
        }
        let snapshot = try await provider(network).fetch(config: config)
        XCTAssertEqual(network.gets.count, 1)
        XCTAssertEqual(snapshot.edition, KimiEdition.china.label)
    }

    func testAKeyBothEditionsRefuseSaysSo() async throws {
        config.setCredential("sk-kimi-\(UUID().uuidString)", for: .kimi)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(401, "{}") }
        do {
            _ = try await provider(network).fetch(config: config)
            XCTFail("expected an error")
        } catch ProviderError.sessionExpired(let message) {
            XCTAssertEqual(message, KimiProvider.rejectedAPIKeyHint(signedInLocally: false))
        }
        XCTAssertEqual(Set(network.gets.compactMap { $0.url.host }), ["api.kimi.com", "api.kimi.ai"])
    }

    /// Recognised with no plan on one edition, refused by the other: the
    /// more telling answer wins.
    func testNoPlanOutranksARefusal() async throws {
        config.setCredential("sk-kimi-\(UUID().uuidString)", for: .kimi)
        let network = ScriptedNetwork { request in
            request.url.host == "api.kimi.com" ? ScriptedNetwork.json(402, "{}") : ScriptedNetwork.json(401, "{}")
        }
        do {
            _ = try await provider(network).fetch(config: config)
            XCTFail("expected an error")
        } catch ProviderError.noPlan(let message) {
            XCTAssertEqual(message, KimiProvider.apiKeyNoPlanHint(.china))
        }
    }

    /// A pasted cookie reads kimi.com's gateway and is labelled China.
    func testACookieReadsTheKimiComGateway() async throws {
        let cookie = KimiFixtures.jwt(exp: 1_900_000_000, type: "access")
        config.setCredential("kimi-auth=\(cookie)", for: .kimi)
        let network = ScriptedNetwork { request in
            XCTAssertEqual(request.url.host, "www.kimi.com")
            XCTAssertEqual(request.headers["Cookie"], "kimi-auth=\(cookie)")
            return request.url.path.hasSuffix("GetUsages")
                ? ScriptedNetwork.json(200, #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"10","resetTime":"2026-09-20T00:00:00Z"}}]}"#)
                : ScriptedNetwork.json(404, "{}")
        }
        let kimi = provider(network)
        let snapshot = try await kimi.fetch(config: config)
        XCTAssertEqual(snapshot.edition, KimiEdition.china.label)
        XCTAssertEqual(kimi.sourceInfo(config: config)?.consoleURL, KimiEdition.china.consoleURL)
    }
}
