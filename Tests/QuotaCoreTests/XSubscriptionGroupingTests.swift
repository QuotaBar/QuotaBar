import XCTest
@testable import QuotaModel
@testable import QuotaCore

final class XSubscriptionGroupingTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(
        used: Double? = 20, balance: Double? = 8, seconds: TimeInterval = 0,
        workspace: String? = "workspace-a", seat: String? = "seat-a", tier: String = "premium",
        migrated: Bool = true, account: String = "same@example.com") -> UsageSnapshot
    {
        UsageSnapshot(
            planName: migrated ? tier : "PRO_PLUS", account: account,
            windows: [UsageWindow(
                title: "Weekly quota", usedPercent: used,
                resetsAt: time.addingTimeInterval(604_800), windowSeconds: 604_800)],
            fetchedAt: time.addingTimeInterval(seconds),
            balance: balance.map { BalanceSheet(balances: [AccountBalance(currency: "USD", total: $0)]) },
            xSubscription: migrated ? XSubscriptionInfo(tier: tier, workspaceID: workspace, seatID: seat) : nil)
    }

    private func cloud(_ entries: [CloudReadings.Entry], device: String = "mac", seconds: TimeInterval = 0) -> CloudReadings {
        CloudReadings(
            deviceID: device, deviceName: device, appVersion: "0.5.31", language: "en",
            updatedAt: time.addingTimeInterval(seconds), providers: entries)
    }

    func testMatchingVerifiedWorkspaceAndSeatProduceOneGrokOwner() {
        let cursor = snapshot(used: 32, balance: 5)
        let grok = snapshot(used: 35, balance: 4, seconds: 60)
        let projected = XSubscriptionGrouping.project([.cursor: cursor, .grok: grok])
        XCTAssertEqual(Set(projected.snapshots.keys), [.grok])
        XCTAssertEqual(projected.owner(for: .cursor), .grok)
        XCTAssertEqual(projected.authoritativeProviders[.grok], .grok)
        XCTAssertEqual(projected.snapshots[.grok]?.windows.first?.usedPercent, 35)
        XCTAssertEqual(projected.snapshots[.grok]?.balance?.balances.first?.total, 4)
        XCTAssertEqual(projected.snapshots[.grok]?.xSubscription?.memberProviders, [.cursor, .grok])
    }

    func testFreshestUnknownRemainsUnknownRatherThanCopyingStaleNumbers() {
        let cursor = snapshot(used: nil, balance: nil, seconds: 60)
        let grok = snapshot(used: 90, balance: 100)
        let projected = XSubscriptionGrouping.project([.cursor: cursor, .grok: grok])
        XCTAssertEqual(projected.authoritativeProviders[.grok], .cursor)
        XCTAssertNil(projected.snapshots[.grok]?.windows.first?.usedPercent)
        XCTAssertNil(projected.snapshots[.grok]?.balance)
        XCTAssertEqual(projected.snapshots[.grok]?.fetchedAt, time.addingTimeInterval(60))
    }

    func testConfirmedZeroRemainsZero() {
        let projected = XSubscriptionGrouping.project([
            .cursor: snapshot(used: 40), .grok: snapshot(used: 0, balance: 0, seconds: 60),
        ])
        XCTAssertEqual(projected.snapshots[.grok]?.windows.first?.usedPercent, 0)
        XCTAssertEqual(projected.snapshots[.grok]?.balance?.balances.first?.total, 0)
    }

    func testNoEmailOnlyMergeOrIncompleteIdentityMerge() {
        let cases: [(String?, String?)] = [(nil, "seat-a"), ("workspace-a", nil), (" ", "seat-a"), (nil, nil)]
        for (workspace, seat) in cases {
            let projected = XSubscriptionGrouping.project([
                .cursor: snapshot(workspace: workspace, seat: seat), .grok: snapshot(),
            ])
            XCTAssertEqual(Set(projected.snapshots.keys), [.cursor, .grok])
            XCTAssertTrue(projected.aliases.isEmpty)
        }
    }

    func testDistinctSeatWorkspaceAndChangedAccountKeepSeparateAllowances() {
        for cursor in [snapshot(seat: "other-seat"), snapshot(workspace: "other-workspace")] {
            let projected = XSubscriptionGrouping.project([.cursor: cursor, .grok: snapshot()])
            XCTAssertEqual(Set(projected.snapshots.keys), [.cursor, .grok])
            XCTAssertEqual(projected.owner(for: .cursor), .cursor)
        }
    }

    func testLegacyPlansStayUnchangedEvenWithTheSameEmailAndUsage() {
        let legacy = snapshot(migrated: false)
        let projected = XSubscriptionGrouping.project([.cursor: legacy, .grok: snapshot()])
        XCTAssertEqual(Set(projected.snapshots.keys), [.cursor, .grok])
        XCTAssertEqual(projected.snapshots[.cursor]?.displayName(for: .cursor), "Cursor")
        XCTAssertEqual(projected.snapshots[.cursor]?.chipLabel, "PRO_PLUS")
        XCTAssertEqual(projected.snapshots[.grok]?.displayName(for: .grok), "X Subscription")
    }

    func testSnapshotMetadataRoundTripIsOptionalAndNormalizesTier() throws {
        let migrated = snapshot(tier: " PREMIUM ")
        let migratedBack = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(migratedBack.xSubscription?.tier, "premium")
        XCTAssertEqual(migratedBack.chipLabel, "Premium")
        let legacyBack = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot(migrated: false)))
        XCTAssertNil(legacyBack.xSubscription)
        XCTAssertEqual(legacyBack.planName, "PRO_PLUS")
    }

    func testProjectionIsIdempotentAndSerializedReloadCannotDuplicateQuotaOrBalance() throws {
        let first = XSubscriptionGrouping.project([.cursor: snapshot(), .grok: snapshot(seconds: 60)])
        let second = XSubscriptionGrouping.project(first.snapshots)
        XCTAssertEqual(Set(second.snapshots.keys), [.grok])
        XCTAssertEqual(second.aliases, first.aliases)
        XCTAssertEqual(second.snapshots[.grok]?.windows.count, 1)
        XCTAssertEqual(second.snapshots[.grok]?.balance?.balances.count, 1)
        let written = cloud(second.snapshots.map { .init(id: $0.key.rawValue, snapshot: $0.value) })
        let reloaded = MergedReadings([try CloudReadings.decode(written.encoded())])
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.item(for: .cursor)?.provider, .grok)
        XCTAssertEqual(reloaded.item(for: .grok)?.snapshot?.windows.count, 1)
        XCTAssertEqual(reloaded.item(for: .grok)?.snapshot?.balance?.balances.first?.total, 8)
        XCTAssertEqual(reloaded.items.first?.displayName, "X Subscription")
    }

    func testDirectChangedAccountWinsOverOldProjectedMembership() {
        let shared = XSubscriptionGrouping.project([.cursor: snapshot(), .grok: snapshot()]).snapshots[.grok]!
        let changed = snapshot(used: 2, workspace: "workspace-b", account: "other@example.com")
        let merged = MergedReadings([cloud([
            .init(id: "grok", snapshot: shared), .init(id: "cursor", snapshot: changed),
        ])])
        XCTAssertEqual(merged.items.count, 2)
        XCTAssertEqual(merged.item(for: .cursor)?.provider, .cursor)
        XCTAssertEqual(merged.item(for: .cursor)?.snapshot?.account, "other@example.com")
    }

    func testDirectMissingCurrentAccountIsNotHiddenByOldProjectedMembership() {
        let shared = XSubscriptionGrouping.project([.cursor: snapshot(), .grok: snapshot()]).snapshots[.grok]!
        let merged = MergedReadings([cloud([
            .init(id: "grok", snapshot: shared), .init(id: "cursor", snapshot: nil, error: "sign in again"),
        ])])
        XCTAssertEqual(merged.items.count, 2)
        XCTAssertEqual(merged.item(for: .cursor)?.provider, .cursor)
        XCTAssertNil(merged.item(for: .cursor)?.snapshot)
        XCTAssertEqual(merged.item(for: .cursor)?.error, "sign in again")
    }

    func testSharedCardUsesFirstMembersPositionAndSavedCursorOrder() {
        let merged = MergedReadings([cloud([
            .init(id: "cursor", snapshot: snapshot()),
            .init(id: "claude", snapshot: snapshot(migrated: false)),
            .init(id: "grok", snapshot: snapshot(seconds: 60)),
        ])])
        XCTAssertEqual(merged.items.map(\.provider), [.grok, .claude])
        XCTAssertEqual(merged.ordered(by: ["cursor", "claude"]).items.map(\.provider), [.grok, .claude])
        XCTAssertEqual(merged.ordered(by: ["claude", "cursor"]).items.map(\.provider), [.claude, .grok])
    }

    func testMergedSourceErrorAndDeviceFollowAuthoritativeSnapshot() {
        let older = cloud([.init(id: "grok", snapshot: snapshot())], device: "old", seconds: 0)
        let newer = cloud([
            .init(id: "cursor", snapshot: snapshot(used: nil, balance: nil, seconds: 60), error: "temporarily unavailable"),
        ], device: "new", seconds: 60)
        let merged = MergedReadings([older, newer])
        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.items.first?.provider, .grok)
        XCTAssertEqual(merged.items.first?.deviceName, "new")
        XCTAssertEqual(merged.items.first?.error, "temporarily unavailable")
        XCTAssertNil(merged.items.first?.snapshot?.windows.first?.usedPercent)
        XCTAssertEqual(merged.items.first?.links?.console?.absoluteString, "https://grok.com/dashboard")
    }

    func testMixedOldAndNewMacsPreserveLegacyCardWithoutProofOfSharedIdentity() {
        let old = cloud([.init(id: "cursor", snapshot: snapshot(migrated: false))], device: "old")
        let new = cloud([.init(id: "grok", snapshot: snapshot(seconds: 60))], device: "new", seconds: 60)
        let merged = MergedReadings([old, new])
        XCTAssertEqual(merged.items.count, 2)
        XCTAssertEqual(merged.item(for: .cursor)?.displayName, "Cursor")
        XCTAssertEqual(merged.item(for: .grok)?.displayName, "X Subscription")
    }

    func testMetadataChangeTriggersSyncEvenWhenQuotaAndBalanceAreUnchanged() {
        let original = cloud([.init(id: "grok", snapshot: snapshot())]).signature
        let moved = cloud([.init(id: "grok", snapshot: snapshot(workspace: "other"))]).signature
        let tier = cloud([.init(id: "grok", snapshot: snapshot(tier: "super"))]).signature
        let legacy = cloud([.init(id: "grok", snapshot: snapshot(migrated: false))]).signature
        XCTAssertNotEqual(original, moved)
        XCTAssertNotEqual(original, tier)
        XCTAssertNotEqual(original, legacy)
    }

    func testTinyConfirmedXUsageChangeTriggersSyncButLegacyWholePointNoiseDoesNot() {
        let zero = cloud([.init(id: "grok", snapshot: snapshot(used: 0))]).signature
        let tiny = cloud([.init(id: "grok", snapshot: snapshot(used: 0.04))]).signature
        let oneTenth = cloud([.init(id: "grok", snapshot: snapshot(used: 0.1))]).signature
        let twoTenths = cloud([.init(id: "grok", snapshot: snapshot(used: 0.2))]).signature
        XCTAssertNotEqual(zero, tiny, "The phone must replace a real zero when usage becomes positive.")
        XCTAssertNotEqual(oneTenth, twoTenths)
        let legacyA = cloud([.init(id: "cursor", snapshot: snapshot(used: 0.1, migrated: false))]).signature
        let legacyB = cloud([.init(id: "cursor", snapshot: snapshot(used: 0.2, migrated: false))]).signature
        XCTAssertEqual(legacyA, legacyB)
    }

    func testSameEmailWorkspaceOrSeatSwitchIsNotAResetInAnotherPool() {
        var previous = snapshot(used: 90)
        previous.windows[0].resetsAt = time.addingTimeInterval(-10)
        for current in [snapshot(used: 0, workspace: "new-workspace"), snapshot(used: 0, seat: "new-seat")] {
            XCTAssertTrue(ResetDetector.accountChanged(from: previous, to: current))
            XCTAssertTrue(ResetDetector.events(provider: .grok, previous: previous, current: current, now: time).isEmpty)
        }
        let samePool = snapshot(used: 0)
        XCTAssertFalse(ResetDetector.accountChanged(from: previous, to: samePool))
        XCTAssertEqual(ResetDetector.events(provider: .grok, previous: previous, current: samePool, now: time).count, 1)
    }
}
