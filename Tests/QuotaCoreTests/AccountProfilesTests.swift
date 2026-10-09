import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Work and personal (#8): profiles kept with the preferences, and the one in
/// use only once there are two to switch between.
final class AccountProfilesTests: XCTestCase {
    func testAnOlderConfigHasNoProfiles() throws {
        let prefs = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"currency":"EUR"}"#.utf8))
        XCTAssertEqual(prefs.currency, "EUR")
        XCTAssertTrue(prefs.accountProfiles.isEmpty)
        XCTAssertNil(prefs.activeProfile)
    }

    func testProfilesSurviveTheTrip() throws {
        var prefs = ExperiencePrefs()
        prefs.accountProfiles = [
            AccountProfile(id: "p", name: "Personal"),
            AccountProfile(id: "w", name: "Work", claudeService: "Claude Code-credentials-1a2b3c4d", codexAccountID: "acct-2"),
        ]
        prefs.activeProfileID = "w"
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.accountProfiles, prefs.accountProfiles)
        XCTAssertEqual(back.activeProfile?.name, "Work")
        XCTAssertEqual(back.activeProfile?.claudeItem, "Claude Code-credentials-1a2b3c4d")
        XCTAssertEqual(back.activeProfile?.codexAccountID, "acct-2")
    }

    func testOneProfileSwitchesNothing() {
        var prefs = ExperiencePrefs()
        prefs.accountProfiles = [AccountProfile(id: "w", name: "Work", claudeService: "Claude Code-credentials-1a2b3c4d")]
        prefs.activeProfileID = "w"
        // The CLIs' own sign-ins until there is a second to switch to.
        XCTAssertNil(prefs.activeProfile)
    }

    func testAMissingChoiceFallsBackToTheFirst() {
        var prefs = ExperiencePrefs()
        prefs.accountProfiles = [AccountProfile(id: "p", name: "Personal"), AccountProfile(id: "w", name: "Work")]
        prefs.activeProfileID = "gone"
        XCTAssertEqual(prefs.activeProfile?.id, "p")
        // The default sign-in, spelled out.
        XCTAssertEqual(prefs.activeProfile?.claudeItem, LocalCredentials.claudeService)
    }

    /// The arrows keep a choice for each card on its own, and a profile in
    /// use takes precedence over them.
    func testArrowChoicesAreEachCardsOwn() {
        var prefs = ExperiencePrefs()
        XCTAssertEqual(prefs.claudeItem, LocalCredentials.claudeService)
        XCTAssertNil(prefs.codexAccountPin)
        prefs.claudeSignInChoice = "Claude Code-credentials-1a2b3c4d"
        XCTAssertEqual(prefs.claudeItem, "Claude Code-credentials-1a2b3c4d")
        XCTAssertNil(prefs.codexAccountPin)
        prefs.codexAccountChoice = "acct-2"
        XCTAssertEqual(prefs.codexAccountPin, "acct-2")
        prefs.accountProfiles = [AccountProfile(id: "p", name: "Personal"), AccountProfile(id: "w", name: "Work", claudeService: "Claude Code-credentials-9f8e7d6c")]
        prefs.activeProfileID = "p"
        XCTAssertEqual(prefs.claudeItem, LocalCredentials.claudeService)
        XCTAssertNil(prefs.codexAccountPin)
        let data = try? JSONEncoder().encode(prefs)
        let back = data.flatMap { try? JSONDecoder().decode(ExperiencePrefs.self, from: $0) }
        XCTAssertEqual(back?.claudeSignInChoice, "Claude Code-credentials-1a2b3c4d")
        XCTAssertEqual(back?.codexAccountChoice, "acct-2")
    }

    /// Profiles the beta's arrow named after addresses go, the sign-in in use
    /// stays as the arrow's choice; a profile someone made is kept.
    func testArrowProfilesFromTheBetaAreMigrated() throws {
        var prefs = ExperiencePrefs()
        prefs.accountProfiles = [
            AccountProfile(id: "a", name: "one@example.com"),
            AccountProfile(id: "b", name: "two@example.com", claudeService: "Claude Code-credentials-b5e21659"),
        ]
        prefs.activeProfileID = "b"
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertTrue(back.accountProfiles.isEmpty)
        XCTAssertNil(back.activeProfileID)
        XCTAssertEqual(back.claudeSignInChoice, "Claude Code-credentials-b5e21659")

        prefs.accountProfiles = [AccountProfile(id: "p", name: "Personal"), AccountProfile(id: "w", name: "Work")]
        let kept = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(kept.accountProfiles.count, 2)
    }
}
