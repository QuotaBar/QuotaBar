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

    /// Antigravity inside Gemini.app (issue #11, Gemini 1.147.5, hub 2.31.0):
    /// an `agy --hub` with no token on its command line, found by the record
    /// it writes instead.
    func testGeminiAppsHubIsFoundByItsRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qb-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ json: String, age: TimeInterval) throws {
            let url = folder.appendingPathComponent(name)
            try Data(json.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("hub_50000.json", #"{"pid": 3884, "httpsPort": 50003, "httpPort": 50000, "lsVersion": "2.31.0", "csrfToken": "tok-new"}"#, age: 10)
        try write("hub_49000.json", #"{"pid": 3001, "httpsPort": 49003, "httpPort": 49000, "csrfToken": "tok-old"}"#, age: 600)
        try write("hub_48000.json", #"{"pid": 2002, "httpPort": 48000, "csrfToken": "tok-gone"}"#, age: 5)
        try write("hub_bad.json", #"{"pid": 4000, "httpsPort": 1}"#, age: 1)
        try write("other.json", #"{"pid": 3884, "httpPort": 1, "csrfToken": "x"}"#, age: 1)

        let hubs = AntigravityLocal.hubs(in: folder, isAlive: { $0 != 2002 })
        // Newest first; the one whose process is gone, and the one with no token, left out.
        XCTAssertEqual(hubs.map(\.server), [
            AntigravityLocal.Server(pid: 3884, csrfToken: "tok-new"),
            AntigravityLocal.Server(pid: 3001, csrfToken: "tok-old"),
        ])
        XCTAssertEqual(hubs.first?.endpoints.map(\.scheme), ["https", "http"])
        XCTAssertEqual(hubs.first?.endpoints.map(\.port), [50003, 50000])
        XCTAssertTrue(AntigravityLocal.hubs(in: folder.appendingPathComponent("missing")).isEmpty)

        // The app itself, and that the old process probe finds no server in it.
        let list = """
          3880 /Applications/Gemini.app/Contents/MacOS/Gemini
          3884 /Applications/Gemini.app/Contents/Helpers/agy --hub --hub-port=50000 --read_host_bridge_token_from_stdin
        """
        XCTAssertTrue(AntigravityLocal.isAppRunning(inProcessList: list))
        XCTAssertTrue(AntigravityLocal.servers(inProcessList: list).isEmpty)
    }

    func testGeminiAppsBundledAgyIsTheCLIWhenNoneIsOnThePath() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("qb-gemini-\(UUID().uuidString)/Gemini.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertNil(AntigravityCLI.geminiBundled(paths: [app.path]))
        let agy = helpers.appendingPathComponent("agy")
        FileManager.default.createFile(atPath: agy.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(AntigravityCLI.geminiBundled(paths: ["/nowhere/Gemini.app", app.path]), agy.path)
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

    /// Google's answer as the cloud route gets it: no `response` around it.
    func testTheCloudSummaryReadsTheSameWithoutTheWrapper() throws {
        let cloud = """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.4998864,"resetTime":"2026-11-04T13:42:42Z"},
            {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-11-05T17:36:48Z"},
            {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2026-10-29T22:36:48Z"},
            {"bucketId":"3p-daily","window":"daily","disabled":true}]}],
         "description":"Within each group, models share a weekly limit and a 5-hour limit."}
        """
        let snapshot = try AntigravityLocal.parseSummary(Data(cloud.utf8))
        XCTAssertEqual(snapshot.windows.map(\.scope), ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800, 18_000, 604_800], "a disabled bucket is left out")
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 50.01, accuracy: 0.01)
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
