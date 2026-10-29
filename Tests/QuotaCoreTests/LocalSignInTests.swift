import XCTest
@testable import QuotaCore
@testable import QuotaModel

// MARK: - ZCode (z.ai)

final class ZCodeSignInTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ entries: [String: String]) throws -> URL {
        let file = root.appendingPathComponent("credentials.json")
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        return file
    }

    func testTheSecretIsTheOneZCodeDerives() {
        XCTAssertEqual(
            ZCode.secret(environment: [:], home: "/Users/someone", user: "someone"),
            "zcode-credential-fallback:darwin:/Users/someone:someone")
        XCTAssertEqual(ZCode.secret(environment: ["ZCODE_CREDENTIAL_SECRET": "given"], home: "/x", user: "y"), "given")
        XCTAssertEqual(ZCode.secret(environment: ["ZCODE_CREDENTIAL_SECRET": ""], home: "/x", user: "y"),
                       "zcode-credential-fallback:darwin:/x:y", "an empty override is no override, as in Node")
    }

    func testSealedValuesOpenWithTheSameSecretOnly() throws {
        let sealed = try XCTUnwrap(ZCode.seal("token-value", secret: "s"))
        XCTAssertTrue(sealed.hasPrefix("enc:v1:"))
        XCTAssertEqual(sealed.dropFirst(7).split(separator: ".").count, 3)
        XCTAssertEqual(ZCode.open(sealed, secret: "s"), "token-value")
        XCTAssertNil(ZCode.open(sealed, secret: "other"))
        XCTAssertEqual(ZCode.open("plain", secret: "s"), "plain", "a value without the prefix is stored plain")
        XCTAssertNil(ZCode.open("enc:v1:broken", secret: "s"))
    }

    func testTheSignInIsReadFromItsEntry() throws {
        let file = try write([
            "oauth:active_provider": try XCTUnwrap(ZCode.seal("zai", secret: "s")),
            "oauth:zai:access_token": try XCTUnwrap(ZCode.seal("abc.def", secret: "s")),
            "zcodejwttoken": try XCTUnwrap(ZCode.seal("other", secret: "s")),
        ])
        let signIn = try XCTUnwrap(ZCode.signIn(file: file, family: .zai, secret: "s"))
        XCTAssertEqual(signIn.token, "abc.def")
        XCTAssertEqual(signIn.family, .zai)
        XCTAssertNil(signIn.expiresAt)
        XCTAssertFalse(signIn.isExpired())
        XCTAssertNil(ZCode.signIn(file: file, family: .bigmodel, secret: "s"), "no bigmodel sign-in in this file")
        XCTAssertNil(ZCode.signIn(file: file, family: .zai, secret: "wrong"))
        XCTAssertNil(ZCode.signIn(file: root.appendingPathComponent("missing.json"), family: .zai, secret: "s"))
    }

    func testAJWTsExpiryIsRead() throws {
        let payload = ZCode.base64URLString(Data(#"{"exp":1000}"#.utf8))
        let file = try write(["oauth:zai:access_token": "Bearer eyJhbGciOiJIUzI1NiJ9.\(payload).sig"])
        let signIn = try XCTUnwrap(ZCode.signIn(file: file, family: .zai, secret: "s"))
        XCTAssertEqual(signIn.token, "eyJhbGciOiJIUzI1NiJ9.\(payload).sig", "a stored Bearer prefix is dropped")
        XCTAssertEqual(signIn.expiresAt, Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(signIn.isExpired())
    }

    func testTheProviderTakesZCodesSignInWhenNothingIsPasted() throws {
        let root = self.root!
        let config = ConfigStore(fileURL: root.appendingPathComponent("config.json"), credentials: MemoryCredentialStorage())
        let signedIn = ZaiProvider(localSignIn: { ZCodeSignIn(family: .zai, token: "t", expiresAt: nil) })
        let signedOut = ZaiProvider(localSignIn: { nil })
        XCTAssertTrue(signedIn.isConfigured(config: config))
        XCTAssertFalse(signedOut.isConfigured(config: config))
        XCTAssertEqual(signedIn.sourceInfo(config: config)?.summary, L10n.t("ZCode sign-in on this Mac", "ZCode 本机登录"))
        XCTAssertNil(signedOut.sourceInfo(config: config))

        config.setCredential("pasted-key", for: .zai)
        XCTAssertTrue(signedOut.isConfigured(config: config))
        XCTAssertEqual(signedIn.sourceInfo(config: config)?.summary, L10n.t("Pasted API key", "粘贴的 API Key"))
        XCTAssertNotNil(signedIn.sourceInfo(config: config)?.note, "says the sign-in on this Mac is there to go back to")
    }

    /// The reply as z.ai gives it for a Lite plan read with ZCode's sign-in.
    func testCreditLimitsAndThePlan() throws {
        let body = #"{"code":200,"data":{"level":"lite","limits":[{"currentValue":50,"number":5,"percentage":2,"remaining":1950,"type":"CREDIT_LIMIT","unit":3,"usage":2000},{"currentValue":0,"nextResetTime":1793398599998,"number":1,"percentage":0,"remaining":10000,"type":"CREDIT_LIMIT","unit":6,"usage":10000}]},"msg":"操作成功","success":true}"#
        let snapshot = try ZaiProvider.parseQuota(Data(body.utf8), host: "https://api.z.ai")
        XCTAssertEqual(snapshot.planName, "Lite")
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? -1, 2.5, accuracy: 0.001, "the counts say it more finely than the whole percentage")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 0)
        XCTAssertEqual(snapshot.windows[0].detail, L10n.t("1950 left of 2000", "剩余 1950 / 共 2000"))
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
    }
}

// MARK: - MiniMax's quota reply

final class MiniMaxRemainsTests: XCTestCase {
    /// As platform.minimax.io answers MiniMax Code's sign-in on a Token Plan:
    /// percentages, no counts, at the top level.
    func testTheTokenPlanReply() throws {
        let body = #"{"base_resp":{"status_code":0,"status_msg":"success"},"model_remains":[{"current_interval_remaining_percent":82,"current_interval_status":1,"current_interval_total_count":0,"current_interval_usage_count":0,"current_weekly_remaining_percent":95,"current_weekly_status":1,"current_weekly_total_count":0,"current_weekly_usage_count":0,"end_time":1793320178377,"model_name":"general","remains_time":17999990,"start_time":1793302178377,"weekly_end_time":1793906978377,"weekly_remains_time":604799990,"weekly_start_time":1793302178377}]}"#
        let snapshot = try MiniMaxCode.parseRemains(Data(body.utf8))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [18, 5])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.windows[0].title, WindowTitle.forSeconds(18_000))
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_320_178.377))
        XCTAssertNil(snapshot.windows[0].scope)
        XCTAssertNil(snapshot.windows[0].detail, "no counts to show")
    }

    /// Counts: `usage_count` is what is left, as MiniMax Code reads it.
    func testCountsAreWhatIsLeft() throws {
        let body = #"{"data":{"model_remains":[{"model_name":"speech-hd","current_interval_total_count":100,"current_interval_usage_count":75,"start_time":0,"end_time":3600000},{"model_name":"general","current_interval_status":3,"current_weekly_remaining_percent":40}]},"base_resp":{"status_code":0}}"#
        let snapshot = try MiniMaxCode.parseRemains(Data(body.utf8))
        // general first, with no limit on its interval.
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
        XCTAssertEqual(snapshot.windows[0].detail, L10n.t("Unlimited", "不限量"))
        XCTAssertEqual(snapshot.windows[1].usedPercent, 60)
        let speech = try XCTUnwrap(snapshot.windows.first { $0.scope == "speech-hd" })
        XCTAssertEqual(speech.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(speech.detail, L10n.t("75 left of 100", "剩余 75 / 共 100"))
        XCTAssertEqual(speech.windowSeconds, 3600)
    }

    /// The subscription endpoint as it answers a Go subscriber.
    static let combo = #"{"base_resp":{"status_code":0,"status_msg":"success"},"current_combo_card":{"combo_type":106001,"title":"Go"},"current_subscribe":{"current_subscribe_combo_type":106001,"current_subscribe_title":"Monthly M Plan Go","renewal_trigger_time_ts":1795737600000},"cycle_resource_packages":[{"combo_type":106001,"title":"Go"},{"combo_type":106002,"title":"Explore"}]}"#

    func testThePlanIsTheCurrentCardsTitle() {
        XCTAssertEqual(MiniMaxCode.planName(Data(Self.combo.utf8)), "Go")
        // No card: the offered plan of the subscribed type.
        let offered = #"{"current_subscribe":{"current_subscribe_combo_type":106002,"current_subscribe_title":"Monthly M Plan Explore"},"cycle_resource_packages":[{"combo_type":106001,"title":"Go"},{"combo_type":106002,"title":"Explore"}]}"#
        XCTAssertEqual(MiniMaxCode.planName(Data(offered.utf8)), "Explore")
        // A card for another type is an offer, not the plan.
        let other = #"{"current_combo_card":{"combo_type":106001,"title":"Go"},"current_subscribe":{"current_subscribe_combo_type":101003,"current_subscribe_title":"Yearly Max"}}"#
        XCTAssertEqual(MiniMaxCode.planName(Data(other.utf8)), "Yearly Max")
        XCTAssertNil(MiniMaxCode.planName(Data(#"{"current_combo_card":{"title":"Go"},"cycle_resource_packages":[]}"#.utf8)), "no subscription, no plan")
        XCTAssertNil(MiniMaxCode.planName(Data("<html>".utf8)))
    }

    func testRefusalsAndEmptyReplies() {
        XCTAssertThrowsError(try MiniMaxCode.parseRemains(Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#.utf8))) {
            guard case ProviderError.unauthorized = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try MiniMaxCode.parseRemains(Data(#"{"base_resp":{"status_code":0},"model_remains":[]}"#.utf8))) {
            guard case ProviderError.noPlan = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try MiniMaxCode.parseRemains(Data("<html>".utf8)))
    }
}

// MARK: - MiniMax Code's sign-in and its renewal

final class MiniMaxCodeRenewalTests: XCTestCase {
    private var authHome: URL!
    private let region = MiniMaxRegion.en
    private var namespace: URL { MiniMaxCode.namespace(region, authHome: authHome) }
    private var recordKey: String { MiniMaxCode.service(region) + "\u{0}account-hash" }
    private let start = Date()

    override func setUpWithError() throws {
        authHome = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-\(UUID().uuidString)/auth")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: authHome.deletingLastPathComponent())
    }

    /// A signed-in namespace as MiniMax Code leaves it.
    private func signIn(expiresIn: TimeInterval, generation: Int = 3, status: String = "authenticated", stateGeneration: Int? = nil, refresh: [String: Any]? = nil) throws {
        let expiresAtMs = Int64((start.timeIntervalSince1970 + expiresIn) * 1000)
        var state: [String: Any] = [
            "schemaVersion": 2, "status": status, "storeKind": "file", "clientId": "mcode-public",
            "scopes": ["agent.default"], "audience": "agent-backend", "buildEnv": "prod", "region": "en",
            "generation": stateGeneration ?? generation, "expiresAtMs": expiresAtMs,
        ]
        if let refresh { state["refresh"] = refresh }
        try MiniMaxCode.writePrivate(state, to: namespace.appendingPathComponent("auth-state.json"))
        let record: [String: Any] = [
            "schemaVersion": 1, "accessToken": "old-access", "refreshToken": "old-refresh", "tokenType": "Bearer",
            "clientId": "mcode-public", "scopes": ["agent.default"], "audience": "agent-backend",
            "expiresAtMs": expiresAtMs, "generation": generation, "loginEpoch": "epoch-1",
        ]
        try MiniMaxCode.writePrivate(["schemaVersion": 1, "records": [recordKey: record]], to: namespace.appendingPathComponent("auth.json"))
    }

    private func state() throws -> [String: Any] {
        try XCTUnwrap(MiniMaxCode.readObject(namespace.appendingPathComponent("auth-state.json")))
    }

    private func record() throws -> [String: Any] {
        let payload = try XCTUnwrap(MiniMaxCode.readObject(namespace.appendingPathComponent("auth.json")))
        return try XCTUnwrap((payload["records"] as? [String: Any])?[recordKey] as? [String: Any])
    }

    private func environment(_ network: ScriptedNetwork, mayRenew: Bool = true, lockWait: TimeInterval = 0.5) -> MiniMaxCodeEnvironment {
        MiniMaxCodeEnvironment(
            authHome: authHome, appConfig: authHome.deletingLastPathComponent().appendingPathComponent("minimax-agent-config.json"),
            signing: { nil }, accounts: MiniMaxAccountCache(),
            send: network.send, now: { Date() },
            sleep: { _ in try? await Task.sleep(nanoseconds: 20_000_000) },
            lockWait: lockWait, lockRetry: 0.05, touchInterval: 15, mayRenew: mayRenew, renewal: MiniMaxCodeRenewal())
    }

    private static let grant = #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"agent.default"}"#
    private static let remains = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_remaining_percent":70,"start_time":0,"end_time":18000000}]}"#

    func testTheSignInIsRead() throws {
        try signIn(expiresIn: 1800)
        let read = try XCTUnwrap(MiniMaxCode.signIn(authHome: authHome))
        XCTAssertEqual(read.accessToken, "old-access")
        XCTAssertEqual(read.region, .en)
        XCTAssertEqual(read.generation, 3)
        XCTAssertTrue(read.hasRefreshToken)
        XCTAssertFalse(read.isDue(now: start))
        XCTAssertTrue(read.isDue(now: start.addingTimeInterval(1700)))
    }

    func testASignedOutOrMismatchedStateIsNoSignIn() throws {
        try signIn(expiresIn: 1800, status: "anonymous")
        XCTAssertNil(MiniMaxCode.signIn(authHome: authHome))
        try signIn(expiresIn: 1800, stateGeneration: 4)
        XCTAssertNil(MiniMaxCode.signIn(authHome: authHome), "a state a generation ahead without a renewal open")
        try signIn(expiresIn: 1800, status: "refreshing", stateGeneration: 4, refresh: ["id": "tx"])
        XCTAssertEqual(MiniMaxCode.signIn(authHome: authHome)?.status, "refreshing", "the old token still serves while a renewal is out")
    }

    func testAnExpiredSignInIsRenewedAndSavedAsMiniMaxCodeSavesIt() async throws {
        try signIn(expiresIn: -60)
        let network = ScriptedNetwork { request in
            if request.url.path == "/oauth2/token" { return ScriptedNetwork.json(200, Self.grant) }
            XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
            return ScriptedNetwork.json(200, Self.remains)
        }
        let snapshot = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)

        let post = try XCTUnwrap(network.posts.first)
        XCTAssertEqual(post.url.absoluteString, "https://account.minimax.io/oauth2/token")
        XCTAssertEqual(post.headers["Content-Type"], "application/x-www-form-urlencoded")
        let form = Dictionary(uniqueKeysWithValues: post.body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        })
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "old-refresh")
        XCTAssertEqual(form["client_id"], "mcode-public")
        XCTAssertEqual(form["scope"], "agent.default")
        XCTAssertEqual(form["audience"], "agent-backend")
        XCTAssertTrue(network.gets.contains { $0.url.absoluteString == "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains" })

        let saved = try record()
        XCTAssertEqual(saved["accessToken"] as? String, "new-access")
        XCTAssertEqual(saved["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual((saved["generation"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual(saved["loginEpoch"] as? String, "epoch-1", "the same sign-in, renewed")
        let expiresAtMs = try XCTUnwrap((saved["expiresAtMs"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThanOrEqual(expiresAtMs, Int64(start.timeIntervalSince1970 * 1000) + 3_600_000, "an hour from the renewal")
        XCTAssertLessThanOrEqual(expiresAtMs, Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000)
        let current = try state()
        XCTAssertEqual(current["status"] as? String, "authenticated")
        XCTAssertEqual((current["generation"] as? NSNumber)?.intValue, 4)
        XCTAssertNil(current["refresh"])
        XCTAssertEqual((current["expiresAtMs"] as? NSNumber)?.int64Value, (saved["expiresAtMs"] as? NSNumber)?.int64Value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("refresh/auth.json").path), "the journal is gone once committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("auth.lock.lock").path), "the lock is given back")
        for file in ["auth.json", "auth-state.json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: namespace.appendingPathComponent(file).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, "MiniMax Code refuses a credential file others can read")
        }
    }

    func testThePlanComesWithTheReading() async throws {
        try signIn(expiresIn: 1800)
        let network = ScriptedNetwork { request in
            request.url.path.hasSuffix("cycle_audio_resource_package")
                ? ScriptedNetwork.json(200, MiniMaxRemainsTests.combo) : ScriptedNetwork.json(200, Self.remains)
        }
        let snapshot = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
        XCTAssertEqual(snapshot.planName, "Go")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
    }

    func testAPlanThatCannotBeReadDoesNotStopTheReading() async throws {
        try signIn(expiresIn: 1800)
        let network = ScriptedNetwork { request in
            if request.url.path.hasSuffix("cycle_audio_resource_package") { throw ProviderError.network("offline") }
            return ScriptedNetwork.json(200, Self.remains)
        }
        let snapshot = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
        XCTAssertNil(snapshot.planName)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
    }

    func testTheAccountComesFromMiniMaxCodesSettings() async throws {
        try signIn(expiresIn: 1800)
        let config = authHome.deletingLastPathComponent().appendingPathComponent("minimax-agent-config.json")
        try JSONSerialization.data(withJSONObject: ["sharedUser": ["userMail": "me@example.com", "userName": "me"]]).write(to: config)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.remains) }
        let provider = MiniMaxProvider(environment: environment(network))
        let snapshot = try await provider.fetch(config: memoryConfig())
        XCTAssertEqual(snapshot.account, "me@example.com")

        // A pasted credential may be another account's: no address is guessed.
        let pasted = memoryConfig()
        pasted.setCredential("sk-pasted", for: .minimax)
        let fromPasted = try await provider.fetch(config: pasted)
        XCTAssertNil(fromPasted.account)
    }

    func testAGoodTokenIsUsedAsItIs() async throws {
        try signIn(expiresIn: 1800)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.remains) }
        _ = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
        XCTAssertTrue(network.posts.isEmpty)
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer old-access")
    }

    func testATokenTurnedDownIsRenewedAndTriedOnce() async throws {
        try signIn(expiresIn: 1800)
        let network = ScriptedNetwork { request in
            if request.url.path == "/oauth2/token" { return ScriptedNetwork.json(200, Self.grant) }
            return request.headers["Authorization"] == "Bearer old-access"
                ? ScriptedNetwork.json(401, "{}") : ScriptedNetwork.json(200, Self.remains)
        }
        let snapshot = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 30)
        XCTAssertEqual(network.posts.count, 1)
        XCTAssertEqual(try record()["accessToken"] as? String, "new-access")
    }

    func testARefusedRefreshTokenPutsTheStateBackAndIsNotSentAgain() async throws {
        try signIn(expiresIn: -60)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(400, #"{"error":"invalid_grant"}"#) }
        let env = environment(network)
        let provider = MiniMaxProvider(environment: env)
        do {
            _ = try await provider.fetch(config: memoryConfig())
            XCTFail("a refused sign-in reads nothing")
        } catch ProviderError.sessionExpired {}
        let current = try state()
        XCTAssertEqual(current["status"] as? String, "expired", "left for MiniMax Code to sign out")
        XCTAssertEqual((current["generation"] as? NSNumber)?.intValue, 3)
        XCTAssertNil(current["refresh"])
        XCTAssertEqual(try record()["refreshToken"] as? String, "old-refresh", "nothing of MiniMax Code's is removed")

        do {
            _ = try await provider.fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.sessionExpired {}
        XCTAssertEqual(network.posts.count, 1, "the same refused token is not sent twice")
    }

    func testAFailedRequestKeepsAGoodSessionAndWaitsBeforeTryingAgain() async throws {
        try signIn(expiresIn: 60)
        let network = ScriptedNetwork { _ in throw ProviderError.network("offline") }
        let provider = MiniMaxProvider(environment: environment(network))
        do {
            _ = try await provider.fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.unavailable {}
        XCTAssertEqual(try state()["status"] as? String, "authenticated", "the old token is still good for a minute")
        XCTAssertEqual((try state()["generation"] as? NSNumber)?.intValue, 3)
        do {
            _ = try await provider.fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.unavailable {}
        XCTAssertEqual(network.posts.count, 1, "not tried again within the cooldown")
    }

    func testARenewalSomeoneElseHasOpenIsLeftToThem() async throws {
        try signIn(expiresIn: -60, status: "refreshing", stateGeneration: 4, refresh: ["id": "theirs", "owner": ["pid": 1, "startedAtMs": 1]])
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.grant) }
        do {
            _ = try await MiniMaxProvider(environment: environment(network)).fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.unavailable {}
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual((try state()["refresh"] as? [String: Any])?["id"] as? String, "theirs")
    }

    func testALockHeldByMiniMaxCodeIsWaitedForThenLeft() async throws {
        try signIn(expiresIn: -60)
        try FileManager.default.createDirectory(at: namespace.appendingPathComponent("auth.lock.lock"), withIntermediateDirectories: false)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.grant) }
        do {
            _ = try await MiniMaxProvider(environment: environment(network, lockWait: 0.2)).fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.unavailable {}
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("auth.lock.lock").path), "someone else's lock is never removed")
    }

    func testAOneOffCommandOnlyReads() async throws {
        try signIn(expiresIn: -60)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.grant) }
        do {
            _ = try await MiniMaxProvider(environment: environment(network, mayRenew: false)).fetch(config: memoryConfig())
            XCTFail()
        } catch ProviderError.sessionExpired {}
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testAPastedCredentialComesFirst() async throws {
        try signIn(expiresIn: 1800)
        let config = memoryConfig()
        config.setCredential("sk-pasted", for: .minimax)
        let network = ScriptedNetwork { _ in ScriptedNetwork.json(200, Self.remains) }
        _ = try await MiniMaxProvider(environment: environment(network)).fetch(config: config)
        XCTAssertEqual(network.gets.first?.url.host, "api.minimax.io")
        XCTAssertEqual(network.gets.first?.headers["Authorization"], "Bearer sk-pasted")
    }

    private func memoryConfig() -> ConfigStore {
        ConfigStore(fileURL: authHome.deletingLastPathComponent().appendingPathComponent("config.json"), credentials: MemoryCredentialStorage())
    }
}
