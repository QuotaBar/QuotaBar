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

    private func write(_ json: String, _ path: String, in home: URL, written: Date? = nil) throws {
        let url = home.appendingPathComponent("credentials/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        if let written {
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        }
    }

    private func session() -> LocalCredentials.KimiCodeSession? {
        LocalCredentials.kimiCodeSession(codeHome: codeHome, legacyHome: legacyHome, now: now)
    }

    private func sessions() -> [LocalCredentials.KimiCodeSession] {
        LocalCredentials.kimiCodeSessions(codeHome: codeHome, legacyHome: legacyHome)
    }

    /// What Kimi Code 0.3x leaves in `~/.kimi-code` after moving from the Python CLI.
    private func writeMigrationReport() throws {
        try FileManager.default.createDirectory(at: codeHome, withIntermediateDirectories: true)
        try Data(#"{"notices":{"oauthLoginsRequiringRelogin":["kimi-code.json"]}}"#.utf8)
            .write(to: codeHome.appendingPathComponent("migration-report.json"))
    }

    /// A token whose payload carries only its type and `exp`; the signature is a placeholder.
    private func jwt(exp: Int, type: String = "access") -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"type\":\"\(type)\",\"exp\":\(exp)}")).c2ln"
    }

    /// A credential file as Kimi Code writes it: the access token runs out at
    /// `expires`, the refresh token at `renewableUntil` (nil: no refresh token).
    private func file(access: String = "access", expires: Int, renewableUntil: Int?) -> String {
        let refresh = renewableUntil.map { jwt(exp: $0, type: "refresh") } ?? ""
        return "{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\",\"expires_at\":\(expires),\"expires_in\":900}"
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
          "refresh_token": "\#(jwt(exp: 1_802_592_000, type: "refresh"))",
          "expires_at": 1800000900,
          "scope": "kimi-code",
          "token_type": "Bearer",
          "expires_in": 900
        }
        """#, globalFile, in: codeHome)
        let found = try XCTUnwrap(session())
        XCTAssertEqual(found.accessToken, "new-access")
        XCTAssertEqual(found.expiresAt, Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertTrue(found.hasRefreshToken)
        XCTAssertEqual(found.refreshExpiresAt, Date(timeIntervalSince1970: 1_802_592_000))
        XCTAssertEqual(found.baseURL.absoluteString, "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(found.usageURL.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        XCTAssertEqual(found.fileName, globalFile)
    }

    /// The Python CLI's file, where Kimi Code itself has never been.
    func testReadsThePythonCLIsFile() throws {
        try write(#"{"access_token":"legacy","refresh_token":"opaque","expires_at":1800001800.5,"expires_in":900.0}"#,
                  "kimi-code.json", in: legacyHome)
        let legacy = try XCTUnwrap(session())
        XCTAssertEqual(legacy.accessToken, "legacy")
        XCTAssertEqual(legacy.expiresAt?.timeIntervalSince1970 ?? 0, 1_800_001_800.5, accuracy: 0.001)
        XCTAssertEqual(legacy.baseURL.absoluteString, "https://api.kimi.com/coding/v1")
        // Not a JWT: renewable as far as anyone here can tell.
        XCTAssertTrue(legacy.canRenew(now: now))
        XCTAssertNil(legacy.refreshExpiresAt)
    }

    /// Once Kimi Code has its own file, the Python CLI's is left over, even
    /// when it happens to run out later.
    func testThePythonCLIsFileIsLeftOverOnceKimiCodeHasItsOwn() throws {
        try write(#"{"access_token":"current","expires_at":1800000900,"expires_in":900}"#, globalFile, in: codeHome)
        try write(#"{"access_token":"legacy","expires_at":1800001800.5,"expires_in":900.0}"#, "kimi-code.json", in: legacyHome)
        XCTAssertEqual(session()?.accessToken, "current")
        XCTAssertEqual(sessions().map(\.accessToken), ["current"])
    }

    /// Kimi Code's migration lists the old sign-in as one to redo; signing
    /// out of Kimi Code afterwards deletes its file, and the old one must not
    /// stand in for it.
    func testAfterMigratingThePythonCLIsFileIsNotRead() throws {
        try writeMigrationReport()
        try write(#"{"access_token":"legacy","refresh_token":"opaque","expires_at":1800001800}"#, "kimi-code.json", in: legacyHome)
        XCTAssertNil(session())
        XCTAssertTrue(sessions().isEmpty)
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

    private let revokedMarker = #"{"access_token":"","refresh_token":"","expires_at":0,"expires_in":0,"scope":"kimi-code","token_type":"Bearer"}"#

    /// What Kimi Code writes after a refused renewal: signed out.
    func testTheRevokedMarkerIsNoSession() throws {
        try write(revokedMarker, globalFile, in: codeHome)
        XCTAssertNil(session())
        XCTAssertTrue(sessions().isEmpty)
    }

    /// The layout on a Mac moved from the Python CLI: its file long dead, and
    /// Kimi Code's own file revoked or deleted by signing out.
    func testASignedOutKimiCodeNeverFallsBackToTheDeadPythonCLIFile() throws {
        let dead = file(access: "legacy", expires: 1_794_816_000, renewableUntil: 1_797_408_000)
        try write(dead, "kimi-code.json", in: legacyHome)

        // Revoked, with and without the migration report.
        try write(revokedMarker, globalFile, in: codeHome)
        XCTAssertNil(session())
        try writeMigrationReport()
        XCTAssertNil(session())

        // Deleted by signing out.
        try FileManager.default.removeItem(at: codeHome.appendingPathComponent("credentials/\(globalFile)"))
        XCTAssertNil(session())
        XCTAssertTrue(sessions().isEmpty)
    }

    /// Where Kimi Code has never been, a Python CLI file nothing can renew
    /// is no session either, but is still there to tell "signed out" apart.
    func testADeadPythonCLIFileIsNoSession() throws {
        try write(file(access: "legacy", expires: 1_794_816_000, renewableUntil: 1_797_408_000), "kimi-code.json", in: legacyHome)
        XCTAssertNil(session())
        XCTAssertEqual(sessions().map(\.fileName), ["kimi-code.json"])
    }

    /// Kimi Code left unused past its refresh token's 30 days: the access
    /// token has run out and nothing can renew it.
    func testAnExpiredTokenIsASessionOnlyWhileKimiCodeCanRenewIt() throws {
        // Renewable for another day: waiting on Kimi Code.
        try write(file(expires: 1_799_999_000, renewableUntil: 1_800_086_400), globalFile, in: codeHome)
        let waiting = try XCTUnwrap(session())
        XCTAssertTrue(waiting.isExpired(now: now))
        XCTAssertTrue(waiting.canRenew(now: now))
        XCTAssertFalse(waiting.needsSignIn(now: now))

        // The refresh token ran out an hour ago.
        try write(file(expires: 1_799_999_000, renewableUntil: 1_799_996_400), globalFile, in: codeHome)
        XCTAssertNil(session())
        XCTAssertEqual(try XCTUnwrap(sessions().first).needsSignIn(now: now), true)

        // No refresh token at all.
        try write(file(expires: 1_799_999_000, renewableUntil: nil), globalFile, in: codeHome)
        XCTAssertNil(session())

        // Still good without one, until the access token runs out.
        try write(file(expires: 1_800_000_900, renewableUntil: nil), globalFile, in: codeHome)
        XCTAssertEqual(session()?.canRenew(now: now), false)
    }

    /// A refused renewal on the region Kimi Code uses blanks that file; the
    /// other region's file, written before, is no sign-in of its. Signing in
    /// on the other region afterwards is.
    func testTheRevokedMarkerOutranksFilesWrittenBeforeIt() throws {
        let earlier = Date(timeIntervalSince1970: 1_799_990_000)
        let later = Date(timeIntervalSince1970: 1_799_995_000)
        try write(file(access: "mainland", expires: 1_799_999_000, renewableUntil: 1_802_000_000),
                  "kimi-code.json", in: codeHome, written: earlier)
        try write(revokedMarker, globalFile, in: codeHome, written: later)
        XCTAssertNil(session())

        try write(file(access: "mainland", expires: 1_800_000_900, renewableUntil: 1_802_592_000),
                  "kimi-code.json", in: codeHome, written: Date(timeIntervalSince1970: 1_799_999_100))
        XCTAssertEqual(session()?.accessToken, "mainland")
    }

    func testUnreadableFilesAreSkipped() throws {
        try write("not json", globalFile, in: codeHome)
        try write(#"{"access_token":"mainland","expires_at":1800000900}"#, "kimi-code.json", in: codeHome)
        XCTAssertEqual(session()?.accessToken, "mainland")
    }

    /// Only when each file was written, never what it holds, and a change on
    /// every renewal or sign-out.
    func testFilesWrittenFollowRenewalsAndSignOuts() throws {
        func written() -> [String: Date] {
            LocalCredentials.kimiCodeFilesWritten(codeHome: codeHome, legacyHome: legacyHome)
        }
        XCTAssertEqual(written(), [:])
        try write(file(expires: 1_800_000_900, renewableUntil: 1_802_592_000), globalFile, in: codeHome,
                  written: Date(timeIntervalSince1970: 1_800_000_000))
        try write("{}", "other.json", in: codeHome)
        let first = written()
        XCTAssertEqual(first, [globalFile: Date(timeIntervalSince1970: 1_800_000_000)])

        try write(file(expires: 1_800_001_800, renewableUntil: 1_802_593_000), globalFile, in: codeHome,
                  written: Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertNotEqual(written(), first)

        try FileManager.default.removeItem(at: codeHome.appendingPathComponent("credentials/\(globalFile)"))
        XCTAssertEqual(written(), [:])
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

    /// An environment on the throwaway homes whose network fails the test.
    private func offline() -> KimiCodeEnvironment {
        let fixed = now
        return KimiCodeEnvironment(
            codeHome: codeHome, legacyHome: legacyHome,
            send: { _, url, _, _, _ in
                XCTFail("no request expected, sent one to \(url.host ?? "?")")
                throw ProviderError.network("offline")
            },
            now: { fixed }, sleep: { _ in }, appVersion: "test", renewal: KimiCodeRenewal())
    }

    /// The older CLI's sign-in is only read: once expired, said with what
    /// brings it back, and no request goes out.
    func testAnExpiredOlderCLISessionIsNotSent() async throws {
        let legacy = file(access: "legacy", expires: 1_799_999_000, renewableUntil: 1_802_000_000)
        try write(legacy, "kimi-code.json", in: legacyHome)
        let expected = KimiProvider.expiredHint(.readOnly(.olderCLI))
        do {
            _ = try await KimiProvider.fetchLocal(offline())
            XCTFail("expected an error")
        } catch {
            guard case let ProviderError.sessionExpired(message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, expected)
            XCTAssertEqual(error.localizedDescription, expected)
        }
        XCTAssertEqual(try String(contentsOf: legacyHome.appendingPathComponent("credentials/kimi-code.json"), encoding: .utf8), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyHome.appendingPathComponent("oauth").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeHome.path))
    }

    /// Nothing left to renew with: sign in again, and no request goes out.
    func testAnExpiredSessionNothingCanRenewSaysToSignInAgain() async throws {
        for renewableUntil in [1_799_996_400, nil] as [Int?] {
            try write(file(expires: 1_799_999_000, renewableUntil: renewableUntil), globalFile, in: codeHome)
            do {
                _ = try await KimiProvider.fetchLocal(offline())
                XCTFail("expected an error")
            } catch {
                guard case let ProviderError.sessionExpired(message) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(message, KimiProvider.signInAgainHint)
            }
        }
    }

    /// Where config.toml names the sign-in Kimi Code uses, that one is read
    /// even when a file from an earlier region runs out later.
    func testTheSignInConfigTomlNamesComesFirst() throws {
        try write(file(access: "mainland", expires: 1_800_000_300, renewableUntil: 1_802_000_000), "kimi-code.json", in: codeHome)
        try write(file(access: "global", expires: 1_800_000_900, renewableUntil: 1_802_000_000), globalFile, in: codeHome)
        XCTAssertEqual(session()?.accessToken, "global")
        try Data("[providers.\"managed:kimi-code\"]\n[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n".utf8)
            .write(to: codeHome.appendingPathComponent("config.toml"))
        XCTAssertEqual(session()?.accessToken, "mainland")
        XCTAssertEqual(session()?.edition, .china)
        XCTAssertEqual(session()?.storageName, "kimi-code")
    }

    func testARejectedCookieSaysToClearIt() {
        XCTAssertNotEqual(
            KimiProvider.rejectedCookieHint(signedInLocally: true),
            KimiProvider.rejectedCookieHint(signedInLocally: false))
        XCTAssertNotEqual(KimiProvider.rejectedCookieHint(signedInLocally: true), ProviderError.unauthorized.errorDescription)
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

    /// Protobuf-JSON int64 strings: an uncapped plan may send int64's largest,
    /// which rounds past `Int.max` as a `Double`. No detail line, no crash.
    func testHugeAndInfiniteFiguresDoNotCrash() throws {
        let uncapped = try parse(#"""
        {"usage":{"limit":"9223372036854775807","used":"5"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"9223372036854775807","remaining":"9223372036854775807"}}]}
        """#)
        XCTAssertEqual(uncapped.windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertNil(uncapped.windows[0].detail)
        XCTAssertNil(uncapped.windows[1].detail)
        XCTAssertEqual(uncapped.windows[1].usedPercent ?? -1, 0, accuracy: 0.0001)

        // An infinite limit or count is no window; an endless one no length.
        let odd = try parse(#"""
        {"usage":{"limit":"inf","used":"5"},
         "limits":[{"window":{"duration":"1e300","timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":"10","used":"1e400","remaining":"4"}},
                   {"window":{"duration":"inf","timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"10","used":"2","resetTime":"inf"}},
                   {"detail":{"limit":"1e400","used":"1"}}]}
        """#)
        XCTAssertEqual(odd.windows.count, 2)
        XCTAssertTrue(odd.windows.allSatisfy { $0.windowSeconds == nil })
        XCTAssertEqual(odd.windows.map(\.detail), ["6 / 10", "2 / 10"])
        XCTAssertNil(odd.windows[1].resetsAt)

        XCTAssertNil(KimiProvider.countDetail(used: 1, limit: .infinity))
        XCTAssertNil(KimiProvider.countDetail(used: .nan, limit: 10))
        XCTAssertEqual(KimiProvider.countDetail(used: 12.7, limit: 100), "12 / 100")
        XCTAssertNil(KimiProvider.windowSeconds(["duration": 1e300, "timeUnit": "TIME_UNIT_DAY"]))
        XCTAssertNil(Dates.parseEpoch(.infinity))
        XCTAssertNil(Dates.parseEpoch(1e300))
        XCTAssertNotNil(Dates.parseEpoch(1_800_000_000_000))
    }

    func testNothingToShowIsABadResponse() {
        for json in ["{}", #"{"usages":{}}"#, #"{"usages":{"limit_5h":{}}}"#, #"{"usage":{"limit":"0"}}"#, "[]", "nope"] {
            XCTAssertThrowsError(try parse(json), json) { error in
                guard case ProviderError.badResponse = error else { return XCTFail("\(json): \(error)") }
            }
        }
    }
}
