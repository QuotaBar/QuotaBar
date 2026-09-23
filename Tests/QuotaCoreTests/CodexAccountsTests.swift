import XCTest
@testable import QuotaCore

/// Saved Codex accounts and switching between them (issue #6). The file is
/// shaped as the CLI writes it; the tokens are unsigned JWTs carrying the
/// claims that matter.
final class CodexAccountsTests: XCTestCase {
    private var directory: URL!
    private var live: URL { directory.appendingPathComponent("auth.json") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-accounts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func jwt(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none"])).\(part(claims)).sig"
    }

    /// An auth.json for `account`, its access token running out `expiresIn` from `now`.
    private func authFile(_ account: String, email: String, plan: String = "plus",
                          expiresIn: TimeInterval = 9 * 86_400, refresh: String = "rt-1") -> Data {
        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": jwt(["email": email, "https://api.openai.com/auth": ["chatgpt_plan_type": plan, "chatgpt_account_id": account]]),
                "access_token": jwt(["exp": now.addingTimeInterval(expiresIn).timeIntervalSince1970]),
                "refresh_token": refresh,
                "account_id": account,
            ],
            "last_refresh": "2027-01-14T00:00:00Z",
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func vault(storage: MemoryCredentialStorage = MemoryCredentialStorage(),
                       refresher: @escaping @Sendable (String) async throws -> CodexTokenRefresh.Tokens = { _ in
                           XCTFail("no refresh expected"); return .init()
                       }) -> CodexAccountVault {
        CodexAccountVault(liveURL: live, storage: storage, refresher: refresher)
    }

    // MARK: The file

    func testTheFileSaysWhoItIs() throws {
        let file = try XCTUnwrap(CodexAuthFile(authFile("acct-a", email: "a@example.com", plan: "pro")))
        XCTAssertEqual(file.accountID, "acct-a")
        XCTAssertEqual(file.email, "a@example.com")
        XCTAssertEqual(file.plan, "pro")
        XCTAssertEqual(file.refreshToken, "rt-1")
        XCTAssertEqual(file.accessExpiry, now.addingTimeInterval(9 * 86_400))
        XCTAssertNil(CodexAuthFile(Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8)), "an API-key sign-in has no account to keep")
    }

    func testRefreshedAShortWhileBeforeItRunsOut() throws {
        XCTAssertFalse(try XCTUnwrap(CodexAuthFile(authFile("a", email: "a", expiresIn: 3 * 86_400))).needsRefresh(now: now))
        XCTAssertTrue(try XCTUnwrap(CodexAuthFile(authFile("a", email: "a", expiresIn: 20 * 3600))).needsRefresh(now: now))
    }

    func testARefreshKeepsWhatItDidNotReplace() throws {
        let file = try XCTUnwrap(CodexAuthFile(authFile("a", email: "a@example.com", refresh: "old")))
        let fresh = try XCTUnwrap(file.refreshed(with: .init(idToken: nil, accessToken: jwt(["exp": 1]), refreshToken: nil), now: now))
        XCTAssertEqual(fresh.refreshToken, "old", "no new refresh token: the old one stands")
        XCTAssertEqual(fresh.email, "a@example.com")
        XCTAssertEqual(fresh.accountID, "a")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fresh.data) as? [String: Any])
        XCTAssertEqual(root["auth_mode"] as? String, "chatgpt", "the rest of the file is the CLI's, kept as it was")
        XCTAssertNotEqual(root["last_refresh"] as? String, "2027-01-14T00:00:00Z")
    }

    // MARK: Keeping accounts

    func testSavingNeedsASignedInCLI() async {
        do {
            try await vault().saveCurrent(now: now)
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? CodexAccountError, .notSignedIn)
        }
    }

    func testSavingKeepsTheAccountAndItsFile() async throws {
        try authFile("acct-a", email: "a@example.com").write(to: live)
        let storage = MemoryCredentialStorage()
        let v = vault(storage: storage)
        let saved = try await v.saveCurrent(now: now)
        XCTAssertEqual(saved.email, "a@example.com")
        let list = await v.accounts()
        XCTAssertEqual(list.map(\.id), ["acct-a"])
        XCTAssertNotNil(storage.read(account: CodexAccountVault.blobKey("acct-a")))
        await v.remove("acct-a")
        let after = await v.accounts()
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(storage.read(account: CodexAccountVault.blobKey("acct-a")))
    }

    // MARK: Switching

    func testSwitchingWritesTheOtherAccountAndKeepsTheOneLeft() async throws {
        let v = vault()
        try authFile("acct-b", email: "b@example.com").write(to: live)
        try await v.saveCurrent(now: now)
        try authFile("acct-a", email: "a@example.com", refresh: "a-old").write(to: live)
        try await v.saveCurrent(now: now)
        // The CLI refreshes A before the switch: that is the copy to keep.
        try authFile("acct-a", email: "a@example.com", refresh: "a-new").write(to: live)

        try await v.switchTo("acct-b", now: now)

        XCTAssertEqual(CodexAuthFile(try Data(contentsOf: live))?.accountID, "acct-b")
        let keptA = await v.stored("acct-a")
        XCTAssertEqual(keptA?.refreshToken, "a-new", "the account left keeps the CLI's latest tokens")
        let backup = directory.appendingPathComponent("auth.json.quotabar-backup")
        XCTAssertEqual(CodexAuthFile(try Data(contentsOf: backup))?.accountID, "acct-a")
        let mode = try FileManager.default.attributesOfItem(atPath: live.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("quotabar-") && !$0.hasSuffix("backup") }
        XCTAssertTrue(leftovers.isEmpty, "no temporary file left behind")
    }

    /// Switching away from an account that was never saved keeps it anyway:
    /// the CLI's file is the only copy, and the switch overwrites it.
    func testSwitchingNeverLosesTheAccountBeingLeft() async throws {
        let v = vault()
        try authFile("acct-b", email: "b@example.com").write(to: live)
        try await v.saveCurrent(now: now)
        try authFile("acct-c", email: "c@example.com").write(to: live)
        try await v.switchTo("acct-b", now: now)
        let ids = await v.accounts().map(\.id)
        XCTAssertEqual(Set(ids), ["acct-b", "acct-c"])
    }

    func testSwitchingToTheActiveOneOrAnUnknownOne() async throws {
        let v = vault()
        try authFile("acct-a", email: "a@example.com").write(to: live)
        try await v.saveCurrent(now: now)
        try await v.switchTo("acct-a", now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json.quotabar-backup").path))
        do {
            try await v.switchTo("nobody", now: now)
            XCTFail("expected notSaved")
        } catch {
            XCTAssertEqual(error as? CodexAccountError, .notSaved)
        }
    }

    // MARK: Reading a kept account

    func testTheActiveAccountIsNeverRefreshedHere() async throws {
        try authFile("acct-a", email: "a@example.com", expiresIn: 60).write(to: live)
        let v = vault()
        try await v.saveCurrent(now: now)
        let file = try await v.credentials(for: "acct-a", now: now)
        XCTAssertEqual(file.accountID, "acct-a", "read from the CLI's file, left for the CLI to refresh")
    }

    func testAKeptAccountNearItsEndIsRefreshedOnceAndKept() async throws {
        let counter = Counter()
        let v = vault(refresher: { token in
            await counter.bump()
            XCTAssertEqual(token, "b-old")
            return .init(idToken: nil, accessToken: self.jwt(["exp": self.now.addingTimeInterval(10 * 86_400).timeIntervalSince1970]), refreshToken: "b-new")
        })
        try authFile("acct-b", email: "b@example.com", expiresIn: 3600, refresh: "b-old").write(to: live)
        try await v.saveCurrent(now: now)
        try authFile("acct-a", email: "a@example.com").write(to: live)

        let first = try await v.credentials(for: "acct-b", now: now)
        XCTAssertEqual(first.refreshToken, "b-new")
        let second = try await v.credentials(for: "acct-b", now: now)
        XCTAssertEqual(second.refreshToken, "b-new")
        let count = await counter.value
        XCTAssertEqual(count, 1, "a fresh copy is not refreshed again")
    }

    func testARefreshTokenThatNoLongerWorksAsksForASignIn() async throws {
        let v = vault(refresher: { _ in throw CodexAccountError.signInAgain(email: nil) })
        try authFile("acct-b", email: "b@example.com", expiresIn: 60).write(to: live)
        try await v.saveCurrent(now: now)
        try authFile("acct-a", email: "a@example.com").write(to: live)
        do {
            _ = try await v.credentials(for: "acct-b", now: now)
            XCTFail("expected signInAgain")
        } catch {
            XCTAssertEqual(error as? CodexAccountError, .signInAgain(email: "b@example.com"))
        }
    }

    /// Two reads of the same account while its refresh is out spend the
    /// refresh token once; a switch to it waits and hands the CLI the tokens
    /// that came back.
    func testAnOverlappingReadAndSwitchWaitForTheRefresh() async throws {
        let counter = Counter()
        let v = vault(refresher: { token in
            await counter.bump()
            XCTAssertEqual(token, "b-old")
            try await Task.sleep(for: .milliseconds(150))
            return .init(idToken: nil, accessToken: self.jwt(["exp": self.now.addingTimeInterval(10 * 86_400).timeIntervalSince1970]), refreshToken: "b-new")
        })
        try authFile("acct-b", email: "b@example.com", expiresIn: 3600, refresh: "b-old").write(to: live)
        try await v.saveCurrent(now: now)
        try authFile("acct-a", email: "a@example.com").write(to: live)

        async let first = v.credentials(for: "acct-b", now: now)
        async let second = v.credentials(for: "acct-b", now: now)
        try await Task.sleep(for: .milliseconds(20))
        try await v.switchTo("acct-b", now: now)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.refreshToken, "b-new")
        XCTAssertEqual(b.refreshToken, "b-new")
        let count = await counter.value
        XCTAssertEqual(count, 1, "one refresh token, spent once")
        XCTAssertEqual(CodexAuthFile(try Data(contentsOf: live))?.refreshToken, "b-new",
                       "the CLI is handed the token that came back, not the one just spent")
    }

    // MARK: The refresh reply

    func testRefreshReplies() throws {
        let ok = try CodexTokenRefresh.parse(status: 200, data: Data(#"{"access_token":"at","refresh_token":"rt","id_token":"it"}"#.utf8))
        XCTAssertEqual(ok, .init(idToken: "it", accessToken: "at", refreshToken: "rt"))
        XCTAssertThrowsError(try CodexTokenRefresh.parse(status: 400, data: Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8))) {
            XCTAssertEqual($0 as? CodexAccountError, .signInAgain(email: nil))
        }
        XCTAssertThrowsError(try CodexTokenRefresh.parse(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))) {
            XCTAssertEqual($0 as? CodexAccountError, .signInAgain(email: nil))
        }
        XCTAssertThrowsError(try CodexTokenRefresh.parse(status: 503, data: Data("busy".utf8))) {
            guard case ProviderError.http(503) = $0 else { return XCTFail("\($0)") }
        }
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
