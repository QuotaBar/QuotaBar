import XCTest
@testable import QuotaCore

final class ClaudeAccountSetupTests: XCTestCase {
    func testLoginUsesItsOwnDirectoryAndDoesNotInheritAnotherAccount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("qb-login-'$-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("fake-'claude")
        let fake = """
        #!/bin/sh
        printf '%s\\n' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-unset}" "${CLAUDECODE-unset}" "$@"

        """
        try Data(fake.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let first = try ClaudeAccountSetup.prepare(home: home, binary: binary)
        let second = try ClaudeAccountSetup.prepare(home: home, binary: binary)
        XCTAssertNotEqual(first.service, second.service)
        XCTAssertEqual(LocalCredentials.claudeConfigDir(service: first.service, home: home), first.directory)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: first.command.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [first.command.path]
        process.environment = ["CLAUDE_CONFIG_DIR": "other-account", "ANTHROPIC_API_KEY": "test-inherited-key", "CLAUDECODE": "parent-session", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "\(first.directory.path)\nunset\nunset\nauth\nlogin\n--claudeai\n")
    }

    func testRemovingAnAccountPersistsAndClearsEveryProfileReference() throws {
        let service = "Claude Code-credentials-abcdef12"
        var prefs = ExperiencePrefs()
        prefs.claudeAccountNames[service] = "Work"
        prefs.claudeSignInChoice = service
        prefs.accountProfiles = [AccountProfile(name: "A", claudeService: service), AccountProfile(name: "B", claudeService: service, codexAccountID: "codex-b")]
        prefs.forgetClaudeSignIn(service)
        prefs.forgetClaudeSignIn(service)
        let restored = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.hiddenClaudeSignIns, [service])
        XCTAssertNil(restored.claudeAccountNames[service])
        XCTAssertNil(restored.claudeSignInChoice)
        XCTAssertTrue(restored.accountProfiles.allSatisfy { $0.claudeService == nil })
        XCTAssertEqual(restored.accountProfiles[1].codexAccountID, "codex-b")
        XCTAssertEqual(restored.claudeItem, LocalCredentials.claudeService)
        prefs.claudeSignInChoice = service
        prefs.accountProfiles = []
        XCTAssertEqual(prefs.claudeItem, LocalCredentials.claudeService)
        prefs.forgetClaudeSignIn(LocalCredentials.claudeService)
        XCTAssertFalse(prefs.hiddenClaudeSignIns.contains(LocalCredentials.claudeService))
    }

    func testDefaultIdentityIsRecognizedWithoutASecondDirectoryOrLiveToken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(#"{"oauthAccount":{"emailAddress":"current@example.com","accountUuid":"current","organizationUuid":"personal"}}"#.utf8)
        try data.write(to: home.appendingPathComponent(".claude.json"))
        let identity = LocalCredentials.claudeConfigIdentity(service: LocalCredentials.claudeService, home: home)
        XCTAssertEqual(identity?.email, "current@example.com")
        XCTAssertEqual(identity?.accountID, "current")
        XCTAssertTrue(ClaudeSignIns.sameAccount(identity, identity))
        XCTAssertFalse(ClaudeSignIns.sameAccount(identity, ClaudeProvider.Identity(email: "current@example.com", accountID: "another", organizationID: "personal")))
        XCTAssertFalse(ClaudeSignIns.sameAccount(identity, ClaudeProvider.Identity(email: "current@example.com", accountID: "current", organizationID: "team")))
        XCTAssertFalse(ClaudeSignIns.sameAccount(identity, ClaudeProvider.Identity(email: "current@example.com")))
    }

    func testLoginCompletionWaitsForChangedCredentialOrUnreadableNewIdentity() {
        let first = ClaudeProvider.Identity(email: "first@example.com", accountID: "first", organizationID: "personal")
        let second = ClaudeProvider.Identity(email: "second@example.com", accountID: "second", organizationID: "personal")
        let before = ClaudeAccountSetup.LoginStamp(tokenDigest: "old-token-digest", identity: first)
        XCTAssertFalse(before.completed(since: before))
        XCTAssertFalse(ClaudeAccountSetup.LoginStamp(tokenDigest: "old-token-digest", identity: second).completed(since: before))
        XCTAssertTrue(ClaudeAccountSetup.LoginStamp(tokenDigest: "new-token-digest", identity: second).completed(since: before))
        XCTAssertTrue(ClaudeAccountSetup.LoginStamp(identity: second).completed(since: before))
        XCTAssertFalse(ClaudeAccountSetup.LoginStamp().completed(since: before))
    }

    func testChangingIdentityCannotKeepThePreviousAccountsQuota() {
        let first = ClaudeProvider.Identity(email: "first@example.com", accountID: "first", organizationID: "personal")
        let second = ClaudeProvider.Identity(email: "second@example.com", accountID: "second", organizationID: "personal")
        let previous = ClaudeSignIns.Reading(id: "same-directory", identity: first, snapshot: UsageSnapshot(windows: [UsageWindow(title: "5h", usedPercent: 70)]))
        let next = ClaudeSignIns.Reading(id: "same-directory", identity: second, error: "offline")
        XCTAssertNil(next.preserving(previous).snapshot)
        XCTAssertEqual(next.preserving(previous).identity?.email, "second@example.com")
    }

    func testOlderSettingsNeedNoAccountMigration() throws {
        let prefs = try JSONDecoder().decode(ExperiencePrefs.self, from: Data("{}".utf8))
        XCTAssertTrue(prefs.hiddenClaudeSignIns.isEmpty)
        XCTAssertTrue(prefs.claudeAccountNames.isEmpty)
    }

    func testRemovedAccountIsNotReadAgainEvenWhenRegistered() {
        let service = "Claude Code-credentials-abcdef12"
        let results = ClaudeSignIns.visibleServices(extras: [service, "keep"], registered: [service], excluding: [service])
        XCTAssertEqual(results, ["keep"])
    }
}
