import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Claude Code's other config dirs' sign-ins (issue #8): found by the name
/// Claude Code gives their keychain items, told apart by organization, and
/// read without the card's caches pushing each other out.
final class ClaudeSignInsTests: XCTestCase {
    func testOnlyClaudeCodesPerDirItemsAreTakenUp() {
        XCTAssertTrue(LocalCredentials.isExtraClaudeService("Claude Code-credentials-1a2b3c4d"))
        // The default item is the card's own.
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-credentials"))
        // Claude Code writes the hash in lower case, eight characters.
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-credentials-1A2B3C4D"))
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-credentials-1a2b3c4"))
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-credentials-1a2b3c4d5"))
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-credentials-zzzzzzzz"))
        XCTAssertFalse(LocalCredentials.isExtraClaudeService("Claude Code-device-key"))
    }

    func testTheItemSaysWhenItsTokenRunsOut() {
        let item = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1790000000000,"subscriptionType":"team"}}"#
        let lookup = LocalCredentials.classify(status: errSecSuccess, data: Data(item.utf8))
        XCTAssertEqual(lookup.state, .available)
        XCTAssertEqual(lookup.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
        let noExpiry = LocalCredentials.classify(status: errSecSuccess, data: Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8))
        XCTAssertNil(noExpiry.expiresAt)
    }

    func testTheProfileNamesTheOrganization() throws {
        let body = """
        {"account":{"uuid":"acc-1","email":"you@example.com","full_name":"You"},
         "organization":{"uuid":"org-team","name":" Acme Studio ","organization_type":"claude_team"}}
        """
        let identity = try JSONDecoder().decode(ClaudeProvider.Profile.self, from: Data(body.utf8)).identity
        XCTAssertEqual(identity.email, "you@example.com")
        XCTAssertEqual(identity.organization, "Acme Studio")
        XCTAssertEqual(identity.accountID, "acc-1")
        XCTAssertEqual(identity.organizationID, "org-team")
    }

    private func reading(_ id: String, account: String?, org: String?, name: String?) -> ClaudeSignIns.Reading {
        ClaudeSignIns.Reading(
            id: id,
            identity: account.map { ClaudeProvider.Identity(email: "\($0)@example.com", organization: name, accountID: $0, organizationID: org) })
    }

    func testTheCardsOwnOrganizationAndRepeatsAreShownOnce() {
        let card = ClaudeProvider.Identity(email: "you@example.com", organization: "Personal", accountID: "you", organizationID: "org-personal")
        let arranged = ClaudeSignIns.arranged([
            reading("Claude Code-credentials-00000004", account: "you", org: "org-team", name: "Zeta Team"),
            // A config dir that is the default one under another path.
            reading("Claude Code-credentials-00000001", account: "you", org: "org-personal", name: "Personal"),
            reading("Claude Code-credentials-00000002", account: "you", org: "org-acme", name: "Acme Studio"),
            // The same organization signed in twice.
            reading("Claude Code-credentials-00000003", account: "you", org: "org-acme", name: "Acme Studio"),
            // Never read yet: kept, it may be anyone.
            reading("Claude Code-credentials-00000005", account: nil, org: nil, name: nil),
        ], card: card)
        XCTAssertEqual(arranged.map(\.id), [
            "Claude Code-credentials-00000002",
            "Claude Code-credentials-00000004",
            "Claude Code-credentials-00000005",
        ])
    }

    func testTheSameOrganizationUnderAnotherAccountIsItsOwnSignIn() {
        let card = ClaudeProvider.Identity(email: "you@example.com", accountID: "you", organizationID: "org-team")
        let arranged = ClaudeSignIns.arranged(
            [reading("Claude Code-credentials-0000000a", account: "colleague", org: "org-team", name: "Acme Studio")],
            card: card)
        XCTAssertEqual(arranged.count, 1)
    }

    func testResetCountsAreKeptPerSignIn() {
        let cache = ClaudeProvider.ResetGrantCache()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = ResetCredits(available: 1, totalEarned: 1)
        let second = ResetCredits(available: 2, totalEarned: 2)
        cache.store(first, token: "card", used: 10, now: now)
        cache.store(second, token: "team", used: 10, now: now)
        // Read in turn, neither pushes the other out.
        XCTAssertEqual(cache.reusable(token: "card", used: 10, now: now.addingTimeInterval(60)), .some(first))
        XCTAssertEqual(cache.reusable(token: "team", used: 10, now: now.addingTimeInterval(60)), .some(second))
        // A token a day old is gone once anything new is stored.
        cache.store(first, token: "renewed", used: 10, now: now.addingTimeInterval(90_000))
        XCTAssertNil(cache.last(token: "card"))
        XCTAssertEqual(cache.last(token: "renewed"), first)
    }

    func testProfilesAreKeptPerSignIn() {
        let memo = ClaudeProvider.ProfileMemo()
        let personal = ClaudeProvider.Identity(email: "you@example.com", organization: "Personal")
        let team = ClaudeProvider.Identity(email: "you@example.com", organization: "Acme Studio")
        memo.store(personal, for: "card")
        memo.store(team, for: "team")
        XCTAssertEqual(memo.profile(for: "card"), personal)
        XCTAssertEqual(memo.profile(for: "team"), team)
        XCTAssertNil(memo.profile(for: "other"))
    }
}
