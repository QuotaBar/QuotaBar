import CryptoKit
import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// The account under the MiniMax card: MiniMax Code's signed user-info
/// request, its settings, and which of them wins. Nothing reaches MiniMax.
final class MiniMaxAccountTests: XCTestCase {
    private let signing = MiniMaxSigning(salt: "test-salt", suffix: "sfx")

    func testEncodeURIComponentIsJavaScripts() {
        XCTAssertEqual(MiniMaxCode.encodeURIComponent("/v1/api/user/info?a=1&b=x y"), "%2Fv1%2Fapi%2Fuser%2Finfo%3Fa%3D1%26b%3Dx%20y")
        XCTAssertEqual(MiniMaxCode.encodeURIComponent("-_.!~*'()"), "-_.!~*'()")
        XCTAssertEqual(MiniMaxCode.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// The query and the two signatures, as MiniMax Code's transport makes them.
    func testTheRequestIsSignedAsMiniMaxCodeSignsIt() throws {
        let now = Date(timeIntervalSince1970: 1_793_307_020.123)
        let request = MiniMaxCode.userInfoRequest(region: .en, token: "tok", signing: signing, now: now)
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "agent.minimax.io")
        XCTAssertEqual(components.path, "/v1/api/user/info")
        XCTAssertEqual(components.queryItems?.map(\.name), [
            "device_platform", "biz_id", "app_id", "version_code", "unix", "timezone_offset",
            "sys_language", "lang", "device_id", "user_id", "client", "region", "is_desktop",
        ])
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["unix"], "1793307020123")
        XCTAssertEqual(query["lang"], "en")
        XCTAssertEqual(query["region"], "en")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(request.headers["x-timestamp"], "1793307020")
        func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(request.headers["x-signature"], md5("1793307020test-salt"), "an empty body adds nothing")
        let pathAndQuery = "/v1/api/user/info?" + (components.percentEncodedQuery ?? "")
        XCTAssertEqual(request.headers["yy"], md5(MiniMaxCode.encodeURIComponent(pathAndQuery) + "_{}" + md5("1793307020123") + "sfx"))

        let china = MiniMaxCode.userInfoRequest(region: .cn, token: "tok", signing: signing, now: now)
        XCTAssertEqual(china.url.host, "agent.minimax.cn")
        XCTAssertTrue(china.url.query?.contains("lang=zh") == true)
    }

    func testTheSigningIsReadFromTheAppsCode() {
        let code = """
            headers: { yy: md5(`${encodeURIComponent(`${url.pathname}${url.search}`)}_${body || '{}'}${md5(String(now))}abcd`),
                'x-timestamp': String(second), 'x-signature': md5(`${second}S@lt-Value#1${body}`), },
            """
        XCTAssertEqual(MiniMaxSigningReader.signing(in: Data(code.utf8)), MiniMaxSigning(salt: "S@lt-Value#1", suffix: "abcd"))
        XCTAssertNil(MiniMaxSigningReader.signing(in: Data("nothing here".utf8)))
    }

    func testWhatTheServerSays() {
        let phoneAccount = #"{"data":{"userInfo":{"email":"","name":"","phone":"x","subUserName":"小明","userID":"1"}},"statusInfo":{"code":0}}"#
        XCTAssertEqual(MiniMaxCode.userInfo(Data(phoneAccount.utf8)), MiniMaxCode.Identity(email: nil, name: "小明"))
        let withMail = #"{"data":{"userInfo":{"email":"me@example.com","name":"Me"}},"statusInfo":{"code":0}}"#
        XCTAssertEqual(MiniMaxCode.userInfo(Data(withMail.utf8)), MiniMaxCode.Identity(email: "me@example.com", name: "Me"))
        XCTAssertNil(MiniMaxCode.userInfo(Data(#"{"statusInfo":{"code":1004,"message":"login"}}"#.utf8)))
    }

    // MARK: Which one goes under the card's name

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func environment(server: String?, settings: [String: Any]?) throws -> (MiniMaxCodeEnvironment, ScriptedNetwork) {
        let config = folder.appendingPathComponent("config.json")
        if let settings { try JSONSerialization.data(withJSONObject: ["sharedUser": settings]).write(to: config) }
        let network = ScriptedNetwork { _ in
            server.map { ScriptedNetwork.json(200, $0) } ?? ScriptedNetwork.json(500, "{}")
        }
        let env = MiniMaxCodeEnvironment(
            authHome: folder, appConfig: config, signing: { [signing] in signing }, accounts: MiniMaxAccountCache(),
            send: network.send, mayRenew: false, renewal: MiniMaxCodeRenewal())
        return (env, network)
    }

    func testAnAddressWinsAndTheNameStandsInForNone() async throws {
        let phone = #"{"data":{"userInfo":{"email":"","name":"","subUserName":"小明"}},"statusInfo":{"code":0}}"#
        let mail = #"{"data":{"userInfo":{"email":"server@example.com","subUserName":"小明"}},"statusInfo":{"code":0}}"#

        var (env, _) = try environment(server: mail, settings: ["userMail": "settings@example.com"])
        var account = await MiniMaxCode.account(region: .en, token: "t", env: env)
        XCTAssertEqual(account, "server@example.com")

        (env, _) = try environment(server: phone, settings: ["userMail": "settings@example.com"])
        account = await MiniMaxCode.account(region: .en, token: "t", env: env)
        XCTAssertEqual(account, "settings@example.com", "an address MiniMax Code keeps beats a name")

        (env, _) = try environment(server: phone, settings: ["userID": "1"])
        account = await MiniMaxCode.account(region: .en, token: "t", env: env)
        XCTAssertEqual(account, "小明", "an account made with a phone number goes by its name")

        (env, _) = try environment(server: nil, settings: ["subUserName": "阿明"])
        account = await MiniMaxCode.account(region: .en, token: "t", env: env)
        XCTAssertEqual(account, "阿明")
    }

    func testTheAccountIsNotAskedForAtEveryRefresh() async throws {
        let (env, network) = try environment(server: #"{"data":{"userInfo":{"subUserName":"小明"}},"statusInfo":{"code":0}}"#, settings: nil)
        _ = await MiniMaxCode.account(region: .en, token: "t", env: env)
        _ = await MiniMaxCode.account(region: .en, token: "t", env: env)
        XCTAssertEqual(network.gets.count, 1)
    }
}
