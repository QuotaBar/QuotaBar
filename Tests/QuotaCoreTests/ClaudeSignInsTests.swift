import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Claude Code's other config dirs' sign-ins (issue #8): found by the name
/// Claude Code gives their keychain items, told apart by organization, and
/// read without the card's caches pushing each other out.
final class ClaudeSignInsTests: XCTestCase {
    func testOrphanedSignInClearsOldQuotaButTemporaryFailureKeepsIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let error = ClaudeSignIns.renewalError(service: "Claude Code-credentials-b5e21659", outcome: .failed("missing directory"), home: home)
        XCTAssertTrue(ProviderPhase.failure(error, previous: nil).discardsCachedReading)
        let old = ClaudeSignIns.Reading(id: "old", snapshot: UsageSnapshot(windows: [UsageWindow(title: "5h", usedPercent: 12)]))
        var missing = ClaudeSignIns.Reading(id: "old", error: error.localizedDescription)
        missing.discardsCachedReading = true
        XCTAssertNil(missing.preserving(old).snapshot)
        let temporary = ClaudeSignIns.Reading(id: "old", error: "offline")
        XCTAssertEqual(temporary.preserving(old).snapshot?.windows.first?.usedPercent, 12)
        let defaultError = ClaudeSignIns.renewalError(service: LocalCredentials.claudeService, outcome: .failed("offline"), home: home)
        XCTAssertFalse(ProviderPhase.failure(defaultError, previous: nil).discardsCachedReading)
    }

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

/// Switching profiles (#8) moves sign-ins between the card and the list
/// under its arrow without reading either again.
final class ClaudeProfileSwitchTests: XCTestCase {
    private func identity(_ org: String, _ name: String) -> ClaudeProvider.Identity {
        ClaudeProvider.Identity(email: "you@example.com", organization: name, accountID: "you", organizationID: org)
    }

    func testTheCardAndTheListTradePlaces() {
        let personal = identity("org-personal", "Personal")
        let work = identity("org-work", "Acme Studio")
        let workReading = ClaudeSignIns.Reading(
            id: "Claude Code-credentials-1a2b3c4d", identity: work,
            snapshot: UsageSnapshot(windows: [UsageWindow(title: "5h", usedPercent: 40)]))
        let outgoing = ClaudeSignIns.Reading(
            id: LocalCredentials.claudeService, identity: personal,
            snapshot: UsageSnapshot(windows: [UsageWindow(title: "5h", usedPercent: 10)]))
        let list = ClaudeSignIns.afterSwitch([workReading], to: workReading.id, from: outgoing, card: work)
        XCTAssertEqual(list.map(\.id), [LocalCredentials.claudeService])
        // What the default sign-in last read goes with it, so the list is not empty-handed.
        XCTAssertEqual(list.first?.snapshot?.windows.first?.usedPercent, 10)
        // And back again.
        let back = ClaudeSignIns.afterSwitch(list, to: LocalCredentials.claudeService, from: workReading, card: personal)
        XCTAssertEqual(back.map(\.id), [workReading.id])
    }
}

/// What a picker says about each sign-in before anyone switches to it, and
/// what it folds away or offers to fix.
final class ClaudeSignInChoiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let me = ClaudeProvider.Identity(email: "me@example.com", organization: "Me", accountID: "me", organizationID: "org-me")
    private let other = ClaudeProvider.Identity(email: "side@example.com", organization: "Side", accountID: "side", organizationID: "org-side")
    private let team = ClaudeProvider.Identity(email: "me@example.com", organization: "Acme", accountID: "me", organizationID: "org-team")
    private let dirA = "Claude Code-credentials-1a2b3c4d"
    private let dirB = "Claude Code-credentials-5e6f7a8b"
    private let dirC = "Claude Code-credentials-9c0d1e2f"
    private let fallback = LocalCredentials.claudeService

    private func choice(_ id: String, _ identity: ClaudeProvider.Identity?, _ state: ClaudeSignIns.State?) -> ClaudeSignIns.Choice {
        ClaudeSignIns.Choice(id: id, identity: identity, state: state)
    }

    // MARK: State

    func testALookupIsTold() {
        func state(_ lookup: LocalCredentials.ClaudeLookup, missingDir: Bool = false) -> ClaudeSignIns.State {
            ClaudeSignIns.state(of: lookup, directoryMissing: missingDir, now: now)
        }
        XCTAssertEqual(state(.init(state: .available, token: "t", expiresAt: now.addingTimeInterval(3_600))), .ready)
        // No expiry recorded is not "expired".
        XCTAssertEqual(state(.init(state: .available, token: "t")), .ready)
        XCTAssertEqual(state(.init(state: .available, token: "t", expiresAt: now.addingTimeInterval(-1))), .expired)
        XCTAssertEqual(state(.init(state: .signedOut, token: nil)), .signedOut)
        XCTAssertEqual(state(.init(state: .needsAuthorization, token: nil)), .needsAuthorization)
        XCTAssertEqual(state(.init(state: .missing, token: nil)), .missing)
        // The folder being gone says more than whatever the item still holds.
        XCTAssertEqual(state(.init(state: .available, token: "t"), missingDir: true), .directoryMissing)
    }

    func testOnlyWhatAPressCanFixIsOfferedAFix() {
        XCTAssertEqual(ClaudeSignIns.repair(for: .signedOut, failing: false), .signIn)
        XCTAssertEqual(ClaudeSignIns.repair(for: .missing, failing: false), .signIn)
        XCTAssertEqual(ClaudeSignIns.repair(for: .needsAuthorization, failing: false), .authorize)
        // Claude Code renews an expired one; a login is offered once that has failed.
        XCTAssertNil(ClaudeSignIns.repair(for: .expired, failing: false))
        XCTAssertEqual(ClaudeSignIns.repair(for: .expired, failing: true), .signIn)
        XCTAssertNil(ClaudeSignIns.repair(for: .ready, failing: true))
        XCTAssertNil(ClaudeSignIns.repair(for: nil, failing: true))
        // Its folder is gone: "Add again" in Settings, not a login here.
        XCTAssertNil(ClaudeSignIns.repair(for: .directoryMissing, failing: true))
    }

    // MARK: What a picker lists

    func testThoseThatReadComeFirstAndNothingElseMoves() {
        let list = [
            choice(fallback, me, .signedOut),
            choice(dirA, other, .ready),
            choice(dirB, team, .expired),
            choice(dirC, nil, .needsAuthorization),
        ]
        XCTAssertEqual(ClaudeSignIns.pickable(list, selected: dirA).map(\.id), [dirA, dirB, dirC, fallback])
        // Not read yet counts as the best it could be, so the list holds still while it finds out.
        let unread = [choice(fallback, me, nil), choice(dirA, other, nil)]
        XCTAssertEqual(ClaudeSignIns.pickable(unread, selected: fallback).map(\.id), [fallback, dirA])
    }

    func testACopyOfTheSameAccountIsFoldedIntoTheOneThatReadsBest() {
        // The browser logged in as the account already there, three times over.
        let copies = [choice(fallback, me, .ready), choice(dirA, me, .ready), choice(dirB, me, .ready), choice(dirC, other, .ready)]
        XCTAssertEqual(ClaudeSignIns.pickable(copies, selected: fallback).map(\.id), [fallback, dirC])
        // The default no longer reads: the copy that does stands for the account.
        let better = [choice(fallback, me, .signedOut), choice(dirA, me, .ready)]
        XCTAssertEqual(ClaudeSignIns.pickable(better, selected: dirA).map(\.id), [dirA])
        // Another organization of the same email is another account.
        let teams = [choice(fallback, me, .ready), choice(dirA, team, .ready)]
        XCTAssertEqual(ClaudeSignIns.pickable(teams, selected: fallback).count, 2)
        // One whose account is not known yet is never folded into another.
        let unknown = [choice(fallback, me, .ready), choice(dirA, nil, .ready), choice(dirB, nil, .ready)]
        XCTAssertEqual(ClaudeSignIns.pickable(unknown, selected: fallback).count, 3)
    }

    func testTheOneInUseIsNeverFoldedAwayAndNeitherIsABetterOneBesideIt() {
        // In use and as good as its copy: it stands for the account.
        let same = [choice(fallback, me, .ready), choice(dirA, me, .ready)]
        XCTAssertEqual(ClaudeSignIns.pickable(same, selected: dirA).map(\.id), [dirA])
        // In use and worse than a copy that reads: both stay, the way out included.
        let worse = [choice(fallback, me, .signedOut), choice(dirA, me, .ready)]
        XCTAssertEqual(Set(ClaudeSignIns.pickable(worse, selected: fallback).map(\.id)), [fallback, dirA])
    }

    // MARK: A login that added nothing

    func testALoginThatSignedInAsAnAccountAlreadyThereIsADuplicate() {
        let list = [choice(fallback, me, .ready), choice(dirA, me, .ready), choice(dirB, other, .ready)]
        XCTAssertEqual(ClaudeSignIns.duplicate(of: dirA, among: list)?.id, fallback)
        XCTAssertNil(ClaudeSignIns.duplicate(of: dirB, among: list))
        // The same email in another organization is another account.
        XCTAssertNil(ClaudeSignIns.duplicate(of: dirA, among: [choice(fallback, team, .ready), choice(dirA, me, .ready)]))
        // Beside one that does not read, the new login is the way back in, not a copy.
        XCTAssertNil(ClaudeSignIns.duplicate(of: dirA, among: [choice(fallback, me, .signedOut), choice(dirA, me, .ready)]))
        XCTAssertNil(ClaudeSignIns.duplicate(of: dirA, among: [choice(fallback, me, .expired), choice(dirA, me, .ready)]))
        // An account that could not be told is never merged.
        XCTAssertNil(ClaudeSignIns.duplicate(of: dirA, among: [choice(fallback, me, .ready), choice(dirA, nil, .ready)]))
        XCTAssertNil(ClaudeSignIns.duplicate(of: "Claude Code-credentials-00000000", among: list))
    }
}
