import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Having the grok CLI renew its own sign-in: the expiry read from its
/// entry, the CLI found where its installer puts it, and what the card says
/// when the token has run out.
final class GrokCLIRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_200_000)

    func testTheEntrySaysWhenItsTokenRunsOut() throws {
        let root: [String: Any] = [
            "https://auth.x.ai::client": [
                "key": "tok", "email": "you@example.com", "expires_at": "2026-10-05T18:34:00Z",
                "refresh_token": "rt", "auth_mode": "oidc",
            ],
        ]
        let auth = try XCTUnwrap(LocalCredentials.grokAuth(in: root, now: now))
        XCTAssertEqual(auth.expiresAt, Dates.parseISO("2026-10-05T18:34:00Z"))
        // Run out, it is still the one read: renewed, or said to be run out.
        let later = try XCTUnwrap(LocalCredentials.grokAuth(in: root, now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(later.accessToken, "tok")
        XCTAssertNil(LocalCredentials.grokAuth(in: ["access_token": "flat"], now: now)?.expiresAt)
    }

    func testTheCLIIsFoundWhereItsInstallerPutsIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".grok/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: bin.appendingPathComponent("grok").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(GrokCLIRenewal.grokBinary(home: home)?.path, bin.appendingPathComponent("grok").path)
    }

    func testARunOutSignInSaysRunningGrokIsEnough() {
        XCTAssertTrue(GrokProvider.expiredMessage(nil).contains("grok"))
        XCTAssertNotEqual(GrokProvider.expiredMessage(.noCLI), GrokProvider.expiredMessage(nil))
        XCTAssertEqual(GrokProvider.expiredMessage(.coolingDown), GrokProvider.expiredMessage(.failed("x")))
    }
}
