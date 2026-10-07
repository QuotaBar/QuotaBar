import CryptoKit
import XCTest
@testable import QuotaCore
import QuotaModel

final class ClaudeWebSessionTests: XCTestCase {
    /// A one-page Safari file with two cookies, laid out by hand: big-endian
    /// page table, little-endian records.
    private func binaryCookies(_ cookies: [(domain: String, name: String, value: String)]) -> Data {
        func le(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xff) } }
        func be(_ v: Int) -> [UInt8] { le(v).reversed() }
        var records: [[UInt8]] = []
        for c in cookies {
            let strings = [c.domain, c.name, "/", c.value].map { Array($0.utf8) + [0] }
            var offsets: [Int] = []
            var at = 56
            for s in strings { offsets.append(at); at += s.count }
            var rec = le(at) + le(0) + le(0) + le(0)
            for o in offsets { rec += le(o) }
            rec += [UInt8](repeating: 0, count: 8 + 16)
            for s in strings { rec += s }
            records.append(rec)
        }
        var page = [UInt8]([0, 0, 1, 0]) + le(records.count)
        var offset = 8 + records.count * 4 + 4
        for r in records { page += le(offset); offset += r.count }
        page += le(0)
        for r in records { page += r }
        return Data(Array("cook".utf8) + be(1) + be(page.count) + page)
    }

    func testReadsClaudeCookiesFromSafarisBinaryFile() {
        let file = binaryCookies([(".claude.ai", "sessionKey", "sk-ant-abc"), (".example.com", "sessionKey", "other"), ("claude.ai", "lastActiveOrg", "org-1")])
        let found = ClaudeWebSession.parseBinaryCookies(file)
        XCTAssertEqual(found["sessionKey"], "sk-ant-abc")
        XCTAssertEqual(found["lastActiveOrg"], "org-1")
        XCTAssertEqual(found.count, 2)
    }

    func testBinaryCookiesThatAreNotOneAreEmpty() {
        XCTAssertTrue(ClaudeWebSession.parseBinaryCookies(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(ClaudeWebSession.parseBinaryCookies(Data()).isEmpty)
    }

    private let key = Data("kkkkkkkkkkkkkkkk".utf8)

    /// Sealed with openssl under the same key and the sixteen-space IV.
    func testOpensChromiumSealedCookie() throws {
        let plain = try XCTUnwrap(ClaudeWebSession.data(fromHex: "76313" + "0" + "2a0666cac905ad183720978254e53945acf659dd5653f9c9d86ec8d70f7e3fcb"))
        XCTAssertEqual(ClaudeWebSession.decrypt(plain, key: key, hashPrefixed: false), "abc-session-value")
    }

    func testDropsTheHostHashFromDatabaseVersion24() throws {
        let sealed = try XCTUnwrap(ClaudeWebSession.data(fromHex: "763130ca162044f5047c105e21ee0f0004b393137b5dfd31c1223ebc3dc8b2c36da7c9b535ecb515dc5362e084896ade4a18aa0918789f9f612d23c02ff3ff6b3a5256"))
        XCTAssertEqual(ClaudeWebSession.decrypt(sealed, key: key, hashPrefixed: true), "abc-session-value")
    }

    func testRefusesWhatIsNotSealed() {
        XCTAssertNil(ClaudeWebSession.decrypt(Data("plain".utf8), key: key, hashPrefixed: false))
        XCTAssertNil(ClaudeWebSession.data(fromHex: "zz"))
    }

    /// The real thing: this Mac's Claude app. Skipped unless
    /// `QB_CLAUDE_DESKTOP_LIVE=1`; the keychain may ask once.
    func testLiveReadOfTheDesktopSession() async throws {
        guard ProcessInfo.processInfo.environment["QB_CLAUDE_DESKTOP_LIVE"] == "1" else {
            throw XCTSkip("QB_CLAUDE_DESKTOP_LIVE is not set")
        }
        XCTAssertTrue(ClaudeWebSession.exists)
        print("LIVE sources=\(ClaudeWebSession.detectedNames)")
        let snapshot = try await ClaudeWebSession.fetch()
        print("LIVE account=\(snapshot.account ?? "-") plan=\(snapshot.planName ?? "-") windows=\(snapshot.windows.map { "\($0.title) \($0.usedPercent ?? -1)" })")
        XCTAssertFalse(snapshot.windows.isEmpty)
    }

    /// A config dir is found from its keychain item's name, and its address
    /// read from the `.claude.json` inside.
    func testConfigDirIdentityFromItsHash() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("qb-home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude-second")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = #"{"oauthAccount":{"emailAddress":"second@example.com","organizationName":"Second Org","accountUuid":"a1","organizationUuid":"o1"}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(".claude.json"))
        let hash = SHA256.hash(data: Data(dir.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let identity = LocalCredentials.claudeConfigIdentity(service: "Claude Code-credentials-\(hash)", home: home)
        XCTAssertEqual(identity?.email, "second@example.com")
        XCTAssertEqual(identity?.organization, "Second Org")
        XCTAssertNil(LocalCredentials.claudeConfigIdentity(service: "Claude Code-credentials-00000000", home: home))
    }
}
