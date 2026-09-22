import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Antigravity's language server, as it answered on the owner's Mac running
/// Antigravity 2.14.0 on 2026-09-16 (issue #4); tokens and addresses replaced.
final class AntigravityLocalTests: XCTestCase {
    func testTheAppsLanguageServerIsFoundWithItsToken() {
        let list = """
          6407 /Applications/Antigravity.app/Contents/MacOS/Antigravity
          6475 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.14.0 --https_server_port 0 --csrf_token 1f2e3d4c-aaaa-bbbb-cccc-000000000000 --app_data_dir antigravity
          7001 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token ide-token --app_data_dir antigravity-ide
          7002 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone
          7003 /usr/bin/grep language_server
        """
        XCTAssertEqual(AntigravityLocal.servers(inProcessList: list), [
            AntigravityLocal.Server(pid: 6475, csrfToken: "1f2e3d4c-aaaa-bbbb-cccc-000000000000"),
        ], "the IDE's 404s the summary; a server with no token cannot be asked")
        XCTAssertTrue(AntigravityLocal.isAppRunning(inProcessList: list))
        XCTAssertFalse(AntigravityLocal.isAppRunning(inProcessList: "  7001 /Applications/Antigravity IDE.app/Contents/MacOS/Electron"))
        XCTAssertEqual(AntigravityLocal.flag("--csrf_token", in: "x --csrf_token=abc --y"), "abc")
    }

    func testItsPortsComeFromLsof() {
        let listing = """
        COMMAND    PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        language_ 6475 peter    7u  IPv4 0x41658acba70f12e7      0t0  TCP 127.0.0.1:54424 (LISTEN)
        language_ 6475 peter    8u  IPv4 0xebdb65e87b3a38fc      0t0  TCP 127.0.0.1:54425 (LISTEN)
        language_ 6475 peter    9u  IPv4 0xebdb65e87b3a38fd      0t0  TCP 192.168.1.2:6000 (LISTEN)
        """
        XCTAssertEqual(AntigravityLocal.ports(inListing: listing), [54424, 54425], "loopback only")
    }

    private let summary = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.75,"resetTime":"2026-09-23T09:42:11Z"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-09-16T14:42:11Z"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-09-23T09:42:11Z"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-09-16T14:42:11Z"},
        {"bucketId":"3p-mystery","displayName":"Something","window":"fortnightly","remainingFraction":0.5}]}],
     "description":"Within each group, models share a weekly limit and a 5-hour limit."}}
    """

    func testTheSummaryBecomesAWindowPerBucketScopedToItsGroup() throws {
        let snapshot = try AntigravityLocal.parseSummary(Data(summary.utf8), plan: "Pro", account: "dev@example.com")
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.windows.map(\.scope), ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800, 18_000, 604_800], "5-hour before the week; an unreadable window left out")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 25, 0, 100], "protobuf leaves out a fraction of zero: none left")
        XCTAssertEqual(snapshot.windows[1].resetsAt, Dates.parseISO("2026-09-23T09:42:11Z"))
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 4)
    }

    func testAnAnswerWithNoLimitsIsNotAQuota() {
        XCTAssertThrowsError(try AntigravityLocal.parseSummary(Data(#"{"response":{"groups":[]}}"#.utf8)))
        XCTAssertThrowsError(try AntigravityLocal.parseSummary(Data("404 page not found".utf8)))
    }

    func testThePlanAndAddressFromUserStatus() {
        let status = #"{"userStatus":{"name":"Dev","email":"dev@example.com","planStatus":{"planInfo":{"teamsTier":"TEAMS_TIER_PRO","planName":"Pro"}}}}"#
        let identity = AntigravityLocal.userStatus(Data(status.utf8))
        XCTAssertEqual(identity.plan, "Pro")
        XCTAssertEqual(identity.account, "dev@example.com")
        XCTAssertNil(AntigravityLocal.userStatus(Data("{}".utf8)).plan)
    }

    func testWindowLengths() {
        XCTAssertEqual(AntigravityLocal.windowSeconds("5h"), 18_000)
        XCTAssertEqual(AntigravityLocal.windowSeconds("weekly"), 604_800)
        XCTAssertEqual(AntigravityLocal.windowSeconds("gemini-weekly"), 604_800)
        XCTAssertEqual(AntigravityLocal.windowSeconds("daily"), 86_400)
        XCTAssertNil(AntigravityLocal.windowSeconds("fortnightly"))
        XCTAssertEqual(AntigravityLocal.groupName("Gemini Models"), "Gemini")
        XCTAssertEqual(AntigravityLocal.groupName(nil), "Antigravity")
    }

    /// The keychain copy, in go-keyring's wrapping — the one Antigravity
    /// 2.14 updates at every sign-in.
    func testTheKeychainCopyOfTheToken() throws {
        let json = #"{"token":{"access_token":"ya29.x","token_type":"Bearer","refresh_token":"1//r","expiry":"2026-09-16T15:41:15.894967+05:00"},"id_token":"e.y.j","auth_method":"consumer"}"#
        let wrapped = "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
        let token = try XCTUnwrap(LocalCredentials.antigravityToken(keychainSecret: wrapped))
        XCTAssertEqual(token.accessToken, "ya29.x")
        XCTAssertEqual(token.expiry, LocalCredentials.parseFlexibleISO("2026-09-16T15:41:15.894967+05:00"))
        XCTAssertEqual(LocalCredentials.antigravityToken(keychainSecret: json)?.accessToken, "ya29.x")
        XCTAssertNil(LocalCredentials.antigravityToken(keychainSecret: "go-keyring-base64:!!!"))
    }

    /// The hint that sent people to open an app already open is gone.
    func testAnExpiredTokenSaysWhatIsTrue() {
        L10n.override = .en
        defer { L10n.override = .system }
        XCTAssertTrue(AntigravityProvider.expiredTokenHint(.noAnswer).contains("is open"))
        XCTAssertTrue(AntigravityProvider.expiredTokenHint(.notRunning).contains("isn't running"))
    }
}
