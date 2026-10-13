import XCTest
@testable import QuotaCore

final class XSubscriptionLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(
        used: Double?, balance: Double? = nil, seconds: TimeInterval = 0,
        workspace: String? = "workspace", seat: String? = "seat", migrated: Bool = true) -> UsageSnapshot
    {
        UsageSnapshot(
            planName: migrated ? "premium" : "PRO_PLUS", account: "private@example.com",
            windows: [UsageWindow(title: "Weekly", usedPercent: used,
                resetsAt: now.addingTimeInterval(604_800), windowSeconds: 604_800)],
            fetchedAt: now.addingTimeInterval(seconds),
            balance: balance.map { BalanceSheet(balances: [AccountBalance(currency: "USD", total: $0)]) },
            xSubscription: migrated ? .init(tier: "premium", workspaceID: workspace, seatID: seat) : nil)
    }

    private func providers(
        _ entries: [(id: ProviderID, snapshot: UsageSnapshot?, error: String?)]) throws -> [[String: Any]]
    {
        let data = LimitsJSON.make(providers: entries, now: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["providers"] as? [[String: Any]])
    }

    func testOneVerifiedSharedAllowanceAndBalanceArePublishedOnce() throws {
        let result = try providers([
            (.cursor, snapshot(used: 10, balance: 80), nil),
            (.grok, snapshot(used: 20, balance: 70, seconds: 60), nil),
        ])
        XCTAssertEqual(result.count, 1)
        let shared = try XCTUnwrap(result.first)
        XCTAssertEqual(shared["id"] as? String, "grok")
        XCTAssertEqual(shared["name"] as? String, "X Subscription")
        XCTAssertEqual(shared["plan"] as? String, "Premium")
        XCTAssertEqual(shared["sharedWith"] as? [String], ["cursor", "grok"])
        XCTAssertEqual((shared["windows"] as? [[String: Any]])?.first?["usedPercent"] as? Double, 20)
        XCTAssertEqual((shared["balances"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((shared["balances"] as? [[String: Any]])?.first?["total"] as? Double, 70)
        XCTAssertNil(shared["account"])
        XCTAssertNil(shared["workspaceID"])
        XCTAssertNil(shared["seatID"])
    }

    func testLatestUnknownUsageAndBalanceDoNotFallbackToStaleNumbers() throws {
        let result = try providers([
            (.cursor, snapshot(used: nil, seconds: 60), "shared read unavailable"),
            (.grok, snapshot(used: 90, balance: 80), "old read error"),
        ])
        let shared = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        let window = try XCTUnwrap((shared["windows"] as? [[String: Any]])?.first)
        XCTAssertNil(window["usedPercent"])
        XCTAssertNil(window["leftPercent"])
        XCTAssertNil(shared["balances"])
        XCTAssertEqual(shared["error"] as? String, "shared read unavailable")
    }

    func testTrueZeroUsageAndBalanceArePublishedAsZero() throws {
        let result = try providers([
            (.cursor, snapshot(used: 90, balance: 80), nil),
            (.grok, snapshot(used: 0, balance: 0, seconds: 60), nil),
        ])
        let shared = try XCTUnwrap(result.first)
        let window = try XCTUnwrap((shared["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(window["usedPercent"] as? Double, 0)
        XCTAssertEqual(window["leftPercent"] as? Double, 100)
        XCTAssertEqual((shared["balances"] as? [[String: Any]])?.first?["total"] as? Double, 0)
    }

    func testTinyPositiveSharedCounterIsNotPublishedAsUnused() throws {
        let result = try providers([(.grok, snapshot(used: 0.04), nil)])
        let window = try XCTUnwrap((result.first?["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(try XCTUnwrap(window["usedPercent"] as? Double), 0.04, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(window["leftPercent"] as? Double), 99.96, accuracy: 0.000_001)
        XCTAssertEqual(QuotaFormat.percent(0.04), "<0.1%")
        XCTAssertEqual(QuotaFormat.percent(99.96), ">99.9%")
        XCTAssertEqual(QuotaFormat.percent(0), "0%")
        XCTAssertEqual(QuotaFormat.percent(100), "100%")
    }

    func testLatestSuccessfulSharedReadDoesNotInheritOtherServicesError() throws {
        let result = try providers([
            (.cursor, snapshot(used: 30, seconds: 60), nil),
            (.grok, snapshot(used: 20), "grok stale"),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?["error"])
        XCTAssertEqual((result.first?["windows"] as? [[String: Any]])?.first?["usedPercent"] as? Double, 30)
    }

    func testLegacyAndDifferentSeatRecordsRemainSeparate() throws {
        for cursor in [snapshot(used: 0, migrated: false), snapshot(used: 2, seat: "different"), snapshot(used: 2, workspace: nil)] {
            let result = try providers([(.cursor, cursor, nil), (.grok, snapshot(used: 15), nil)])
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.map { $0["id"] as? String }, ["cursor", "grok"])
        }
        let legacy = try providers([(.cursor, snapshot(used: 0, migrated: false), nil)]).first
        XCTAssertEqual(legacy?["name"] as? String, "Cursor")
        XCTAssertEqual(legacy?["plan"] as? String, "PRO_PLUS")
        XCTAssertNil(legacy?["sharedWith"])
        XCTAssertNil(legacy?["balances"])
    }

    func testDirectUnknownAccountIsNotHiddenByOldGroupMembership() throws {
        let projected = XSubscriptionGrouping.project([
            .cursor: snapshot(used: 20, balance: 30), .grok: snapshot(used: 20, balance: 30),
        ])
        let result = try providers([
            (.grok, projected.snapshots[.grok], nil), (.cursor, nil, "new sign-in missing"),
        ])
        XCTAssertEqual(result.count, 2)
        let cursor = try XCTUnwrap(result.first { $0["id"] as? String == "cursor" })
        XCTAssertEqual(cursor["error"] as? String, "new sign-in missing")
        XCTAssertNil(cursor["windows"])
        XCTAssertNil(cursor["balances"])
    }

    func testAlreadyProjectedSerializationKeepsOnlyOneSharedBalance() throws {
        let projected = XSubscriptionGrouping.project([
            .cursor: snapshot(used: 20, balance: 30), .grok: snapshot(used: 20, balance: 30),
        ])
        let cached = try JSONDecoder().decode(UsageSnapshot.self,
            from: JSONEncoder().encode(try XCTUnwrap(projected.snapshots[.grok])))
        let result = try providers([(.grok, cached, nil)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual((result.first?["balances"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result.first?["sharedWith"] as? [String], ["cursor", "grok"])
    }
}
