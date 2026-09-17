import XCTest
@testable import QuotaCore

/// The Kimi Code sign-in, read from throwaway directories laid out like
/// `~/.kimi-code` and `~/.kimi` — never the real ones.
final class KimiCodeSessionTests: XCTestCase {
    private var root: URL!
    private var codeHome: URL { root.appendingPathComponent(".kimi-code") }
    private var legacyHome: URL { root.appendingPathComponent(".kimi") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The file name the global Kimi Code app signs in under.
    private let globalFile = "kimi-code-env-0e4f99c69cc27850.json"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiCodeSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: String, _ path: String, in home: URL) throws {
        let url = home.appendingPathComponent("credentials/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func session() -> LocalCredentials.KimiCodeSession? {
        LocalCredentials.kimiCodeSession(codeHome: codeHome, legacyHome: legacyHome)
    }

    /// A token whose payload carries only `exp`; the signature is a placeholder.
    private func jwt(exp: Int) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"type\":\"access\",\"exp\":\(exp)}")).c2ln"
    }

    // MARK: File names

    /// Kimi Code hashes the hosts into the name; a mismatch here would mean
    /// the global sign-in is never found.
    func testStorageNamesFollowKimiCodesScheme() {
        XCTAssertEqual(
            LocalCredentials.kimiCodeStorageName(oauthHost: "https://auth.kimi.com", baseURL: "https://api.kimi.com/coding/v1"),
            "kimi-code")
        XCTAssertEqual(
            LocalCredentials.kimiCodeStorageName(oauthHost: "https://auth.kimi.ai", baseURL: "https://api.kimi.ai/coding/v1"),
            "kimi-code-env-0e4f99c69cc27850")
        XCTAssertEqual(
            LocalCredentials.kimiCodeStorageNames["kimi-code-env-0e4f99c69cc27850"]?.absoluteString,
            "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(LocalCredentials.kimiCodeStorageNames["kimi-code"]?.absoluteString, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(LocalCredentials.kimiCodeStorageNames.count, 4)
    }

    // MARK: Choosing a file

    func testReadsTheCurrentAppsFile() throws {
        try write(#"""
        {
          "access_token": "new-access",
          "refresh_token": "never-read",
          "expires_at": 1800000900,
          "scope": "kimi-code",
          "token_type": "Bearer",
          "expires_in": 900
        }
        """#, globalFile, in: codeHome)
        let found = try XCTUnwrap(session())
        XCTAssertEqual(found.accessToken, "new-access")
        XCTAssertEqual(found.expiresAt, Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertEqual(found.baseURL.absoluteString, "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(found.usageURL.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        XCTAssertEqual(found.fileName, globalFile)
    }

    /// An upgrade from the Python CLI leaves its file behind; the one that
    /// runs out last is the live one.
    func testPicksTheSessionThatRunsOutLast() throws {
        try write(#"{"access_token":"current","expires_at":1800000900,"expires_in":900}"#, globalFile, in: codeHome)
        try write(#"{"access_token":"legacy","expires_at":1794754572.25,"expires_in":900.0}"#, "kimi-code.json", in: legacyHome)
        XCTAssertEqual(session()?.accessToken, "current")

        try write(#"{"access_token":"legacy","expires_at":1800001800.5,"expires_in":900.0}"#, "kimi-code.json", in: legacyHome)
        let legacy = try XCTUnwrap(session())
        XCTAssertEqual(legacy.accessToken, "legacy")
        XCTAssertEqual(legacy.expiresAt?.timeIntervalSince1970 ?? 0, 1_800_001_800.5, accuracy: 0.001)
        XCTAssertEqual(legacy.baseURL.absoluteString, "https://api.kimi.com/coding/v1")
    }

    /// A region switch leaves the mainland file next to the global one.
    func testPicksAmongTheNewAppsOwnFiles() throws {
        try write(#"{"access_token":"mainland","expires_at":1800000100}"#, "kimi-code.json", in: codeHome)
        try write(#"{"access_token":"global","expires_at":1800000900}"#, globalFile, in: codeHome)
        XCTAssertEqual(session()?.accessToken, "global")
        XCTAssertEqual(session()?.baseURL.host, "api.kimi.ai")
    }

    func testExpiryAsIntFloatOrString() {
        let base = URL(string: "https://api.kimi.com/coding/v1")!
        func expiry(_ value: Any) -> TimeInterval? {
            LocalCredentials.kimiCodeSession(in: ["access_token": "t", "expires_at": value], baseURL: base, fileName: "f")?
                .expiresAt?.timeIntervalSince1970
        }
        XCTAssertEqual(expiry(1_800_000_900), 1_800_000_900)
        XCTAssertEqual(expiry(1_800_000_900.75), 1_800_000_900.75)
        XCTAssertEqual(expiry("1800000900"), 1_800_000_900)
        XCTAssertEqual(expiry(NSNumber(value: Int64(1_800_000_900))), 1_800_000_900)
    }

    /// Without `expires_at`, the token's own `exp` says when it runs out.
    func testFallsBackToTheTokensOwnExpiry() throws {
        try write("{\"access_token\":\"\(jwt(exp: 1_800_000_600))\"}", globalFile, in: codeHome)
        XCTAssertEqual(session()?.expiresAt, Date(timeIntervalSince1970: 1_800_000_600))
    }

    func testNoFilesMeansNoSession() throws {
        XCTAssertNil(session())
        try FileManager.default.createDirectory(
            at: codeHome.appendingPathComponent("credentials"), withIntermediateDirectories: true)
        XCTAssertNil(session())
    }

    /// What Kimi Code writes after a refused renewal: signed out.
    func testTheRevokedMarkerIsNoSession() throws {
        try write(#"{"access_token":"","refresh_token":"","expires_at":0,"expires_in":0,"scope":"kimi-code","token_type":"Bearer"}"#,
                  globalFile, in: codeHome)
        XCTAssertNil(session())
    }

    func testUnreadableFilesAreSkipped() throws {
        try write("not json", globalFile, in: codeHome)
        try write(#"{"access_token":"legacy","expires_at":1800000000}"#, "kimi-code.json", in: legacyHome)
        XCTAssertEqual(session()?.accessToken, "legacy")
    }

    /// A file for hosts set through Kimi Code's environment overrides has no
    /// known destination, and other names in the folder are not Kimi Code's.
    func testIgnoresFilesForOtherHostsAndOtherNames() throws {
        try write(#"{"access_token":"custom-host","expires_at":1900000000}"#, "kimi-code-env-deadbeefdeadbeef.json", in: codeHome)
        try write(#"{"access_token":"something-else","expires_at":1900000000}"#, "other.json", in: codeHome)
        try write(#"{"access_token":"not-json-extension","expires_at":1900000000}"#, "kimi-code.lock", in: codeHome)
        XCTAssertNil(session())
    }

    // MARK: Expiry

    func testExpiryDetection() {
        let base = URL(string: "https://api.kimi.ai/coding/v1")!
        func session(expiresAt: Date?) -> LocalCredentials.KimiCodeSession {
            LocalCredentials.KimiCodeSession(accessToken: "t", expiresAt: expiresAt, baseURL: base, fileName: "f")
        }
        XCTAssertTrue(session(expiresAt: now.addingTimeInterval(-448)).isExpired(now: now))
        XCTAssertTrue(session(expiresAt: now).isExpired(now: now))
        // Inside the margin: it would run out on the way.
        XCTAssertTrue(session(expiresAt: now.addingTimeInterval(20)).isExpired(now: now))
        XCTAssertFalse(session(expiresAt: now.addingTimeInterval(600)).isExpired(now: now))
        // Nothing says when: the server decides.
        XCTAssertFalse(session(expiresAt: nil).isExpired(now: now))
    }

    func testDescribingASessionLeavesTheTokenOut() {
        let session = LocalCredentials.KimiCodeSession(
            accessToken: "secret-access-token", expiresAt: now,
            baseURL: URL(string: "https://api.kimi.ai/coding/v1")!, fileName: globalFile)
        XCTAssertFalse(String(describing: session).contains("secret-access-token"))
        XCTAssertFalse("\(session)".contains("secret-access-token"))
        XCTAssertTrue(String(describing: session).contains(globalFile))
    }

    /// Known without asking, and said with what brings it back — no request goes out.
    func testAnExpiredSessionIsNotSent() async {
        let expired = LocalCredentials.KimiCodeSession(
            accessToken: "t", expiresAt: now.addingTimeInterval(-60),
            baseURL: URL(string: "https://api.kimi.ai/coding/v1")!, fileName: "f")
        do {
            _ = try await KimiProvider.fetchCode(session: expired, now: now)
            XCTFail("expected an error")
        } catch {
            guard case let ProviderError.sessionExpired(message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, KimiProvider.expiredSessionHint)
            XCTAssertEqual(error.localizedDescription, KimiProvider.expiredSessionHint)
        }
    }
}

/// `GET /coding/v1/usages`, from a fixture shaped like the live reply with the
/// figures made up.
final class KimiCodeUsageTests: XCTestCase {
    private func parse(_ json: String) throws -> UsageSnapshot {
        try KimiProvider.parseCodeUsage(Data(json.utf8))
    }

    private func iso(_ text: String) -> Date {
        LocalCredentials.parseFlexibleISO(text)!
    }

    func testDecodesTheLiveShape() throws {
        let snapshot = try parse(#"""
        {"usage":{"limit":"100","remaining":"74","resetTime":"2026-09-20T17:51:33.809775Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","remaining":"88","resetTime":"2026-09-17T11:51:33.809775Z"}}],
         "usages":{"limit_5h":{"used_ratio":0.12,"reset_time":"2026-09-17T11:51:33Z"},
                   "limit_7d":{"used_ratio":0.26,"reset_time":"2026-09-20T17:51:33Z"}}}
        """#)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertNil(snapshot.planName)
        XCTAssertNil(snapshot.account)

        let session = snapshot.windows[0]
        XCTAssertEqual(session.title, WindowTitle.forSeconds(18_000))
        XCTAssertEqual(session.windowSeconds, 18_000)
        XCTAssertEqual(session.usedPercent ?? -1, 12, accuracy: 0.0001)
        XCTAssertEqual(session.resetsAt, iso("2026-09-17T11:51:33Z"))
        // Pools carry no counts.
        XCTAssertNil(session.detail)

        let weekly = snapshot.windows[1]
        XCTAssertEqual(weekly.title, WindowTitle.forSeconds(604_800))
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.usedPercent ?? -1, 26, accuracy: 0.0001)
        XCTAssertEqual(weekly.resetsAt, iso("2026-09-20T17:51:33Z"))
        XCTAssertEqual(weekly.horizon, .long)
        XCTAssertEqual(session.horizon, .short)
    }

    /// Before the pools, only the counts: weekly from `usage`, the rest from
    /// `limits`, `used` worked out from `remaining`.
    func testFallsBackToTheCountsWithoutPools() throws {
        let snapshot = try parse(#"""
        {"usage":{"limit":"2048","remaining":"1673","resetTime":"2026-09-20T17:51:33.809775235Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":200,"remaining":181,"reset_at":"2026-09-17T11:51:33Z"}}]}
        """#)
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.windows[0].detail, "19 / 200")
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? -1, 9.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[0].resetsAt, iso("2026-09-17T11:51:33Z"))
        XCTAssertEqual(snapshot.windows[1].detail, "375 / 2048")
        // Nanosecond timestamps parse.
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
    }

    func testReportedUsedWinsAndMayPassTheLimit() throws {
        let snapshot = try parse(#"{"usage":{"limit":"100","used":"120","remaining":"0"}}"#)
        XCTAssertEqual(snapshot.windows.first?.detail, "120 / 100")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 100)
    }

    /// A pool with a nonsense ratio gives way to the counts; one past 1 is full.
    func testBadRatiosFallBackAndHighOnesClamp() throws {
        let snapshot = try parse(#"""
        {"usage":{"limit":"100","remaining":"40"},
         "usages":{"limit_5h":{"used_ratio":1.7,"reset_time":"2026-09-17T11:51:33Z"},
                   "limit_7d":{"used_ratio":-1}}}
        """#)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 100)
        XCTAssertEqual(snapshot.windows[1].detail, "60 / 100")
        XCTAssertEqual(snapshot.windows[1].usedPercent ?? -1, 60, accuracy: 0.0001)
    }

    func testMonthlyPoolAndLongerLegacyWindows() throws {
        let snapshot = try parse(#"""
        {"usages":{"limit_5h":{"used_ratio":"0.5"},
                   "limit_month_total":{"used_ratio":0.3,"reset_time":"2026-10-01T00:00:00Z"},
                   "limit_month_code":{"used_ratio":0.1}},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"1"}},
                   {"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"10","used":"4"}}]}
        """#)
        // The legacy 5-hour row is covered by its pool; the daily one is not.
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 86_400, 2_592_000])
        XCTAssertEqual(snapshot.windows[0].usedPercent ?? -1, 50, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[1].title, WindowTitle.forSeconds(86_400))
        XCTAssertEqual(snapshot.windows[1].detail, "4 / 10")
        XCTAssertEqual(snapshot.windows[2].title, WindowTitle.forSeconds(2_592_000))
        XCTAssertEqual(snapshot.windows[2].usedPercent ?? -1, 30, accuracy: 0.0001)
    }

    func testPlanNames() throws {
        func plan(_ user: String, version: String? = nil) throws -> String? {
            let versionJSON = version.map { #","version":"\#($0)""# } ?? ""
            return try parse(#"{"usages":{"limit_5h":{"used_ratio":0}},"user":\#(user)\#(versionJSON)}"#).planName
        }
        XCTAssertEqual(try plan(#"{"membership":{"level":"LEVEL_INTERMEDIATE"}}"#), "Allegretto")
        XCTAssertEqual(try plan(#"{"membership":{"level":"LEVEL_ADVANCED"}}"#, version: "GOODS_VERSION_V1"), "Allegro")
        XCTAssertEqual(try plan(#"{"membership":{"level":"LEVEL_ADVANCED"}}"#, version: "GOODS_VERSION_V2"), "Advanced")
        XCTAssertNil(try plan(#"{"membership":{"level":"LEVEL_UNSPECIFIED"}}"#))
        XCTAssertNil(try plan(#"{"membership":"odd"}"#))
    }

    func testNothingToShowIsABadResponse() {
        for json in ["{}", #"{"usages":{}}"#, #"{"usages":{"limit_5h":{}}}"#, #"{"usage":{"limit":"0"}}"#, "[]", "nope"] {
            XCTAssertThrowsError(try parse(json), json) { error in
                guard case ProviderError.badResponse = error else { return XCTFail("\(json): \(error)") }
            }
        }
    }
}
