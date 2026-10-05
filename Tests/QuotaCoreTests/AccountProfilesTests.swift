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
}
