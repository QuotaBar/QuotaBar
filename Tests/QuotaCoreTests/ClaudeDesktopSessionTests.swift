import XCTest
@testable import QuotaCore
import QuotaModel

final class ClaudeDesktopSessionTests: XCTestCase {
    private let key = Data("kkkkkkkkkkkkkkkk".utf8)

    /// Sealed with openssl under the same key and the sixteen-space IV.
    func testOpensChromiumSealedCookie() throws {
        let plain = try XCTUnwrap(ClaudeDesktopSession.data(fromHex: "76313" + "0" + "2a0666cac905ad183720978254e53945acf659dd5653f9c9d86ec8d70f7e3fcb"))
        XCTAssertEqual(ClaudeDesktopSession.decrypt(plain, key: key, hashPrefixed: false), "abc-session-value")
    }

    func testDropsTheHostHashFromDatabaseVersion24() throws {
        let sealed = try XCTUnwrap(ClaudeDesktopSession.data(fromHex: "763130ca162044f5047c105e21ee0f0004b393137b5dfd31c1223ebc3dc8b2c36da7c9b535ecb515dc5362e084896ade4a18aa0918789f9f612d23c02ff3ff6b3a5256"))
        XCTAssertEqual(ClaudeDesktopSession.decrypt(sealed, key: key, hashPrefixed: true), "abc-session-value")
    }

    func testRefusesWhatIsNotSealed() {
        XCTAssertNil(ClaudeDesktopSession.decrypt(Data("plain".utf8), key: key, hashPrefixed: false))
        XCTAssertNil(ClaudeDesktopSession.data(fromHex: "zz"))
    }

    /// The real thing: this Mac's Claude app. Skipped unless
    /// `QB_CLAUDE_DESKTOP_LIVE=1`; the keychain may ask once.
    func testLiveReadOfTheDesktopSession() async throws {
        guard ProcessInfo.processInfo.environment["QB_CLAUDE_DESKTOP_LIVE"] == "1" else {
            throw XCTSkip("QB_CLAUDE_DESKTOP_LIVE is not set")
        }
        XCTAssertTrue(ClaudeDesktopSession.exists)
        XCTAssertTrue(ClaudeDesktopSession.authorize())
        let snapshot = try await ClaudeDesktopSession.fetch()
        print("LIVE account=\(snapshot.account ?? "-") plan=\(snapshot.planName ?? "-") windows=\(snapshot.windows.map { "\($0.title) \($0.usedPercent ?? -1)" })")
        XCTAssertFalse(snapshot.windows.isEmpty)
    }
}
