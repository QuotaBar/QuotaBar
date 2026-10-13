import XCTest
@testable import QuotaCore

/// A reported cap is not evidence that nothing has been consumed. Exercise
/// missing fields separately from explicit zeros through the real parsers.
final class MissingUsageTests: XCTestCase {
    func testPhoneCachedUnknownUsageStaysUnknownAfterResetAndReload() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let windows = [
            UsageWindow(title: "unknown", usedPercent: nil, resetsAt: now.addingTimeInterval(-60)),
            UsageWindow(title: "zero", usedPercent: 0, resetsAt: now.addingTimeInterval(60)),
            UsageWindow(title: "known", usedPercent: 25, resetsAt: now.addingTimeInterval(60)),
        ]
        let reloaded = try JSONDecoder().decode([UsageWindow].self, from: JSONEncoder().encode(windows))
        XCTAssertNil(reloaded[0].usedNow(at: now))
        XCTAssertEqual(reloaded[1].usedNow(at: now), 0)
        XCTAssertEqual(reloaded[2].usedNow(at: now), 25)
        XCTAssertNil(reloaded[0].usedNow(at: now.addingTimeInterval(120)))
        XCTAssertNil(reloaded[1].usedNow(at: now.addingTimeInterval(120)))
        XCTAssertNil(reloaded[2].usedNow(at: now.addingTimeInterval(120)))
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }
    private func check(_ missing: UsageSnapshot, _ zero: UsageSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let unknown = try XCTUnwrap(missing.windows.first, file: file, line: line)
        XCTAssertNil(unknown.usedPercent, file: file, line: line)
        XCTAssertNil(unknown.detail, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(zero.windows.first, file: file, line: line).usedPercent, 0, file: file, line: line)
    }

    func testCursorPlanAndOnDemandRequireUsageOrRemaining() throws {
        for key in ["plan", "onDemand"] {
            let missing = try CursorProvider.parse(data("{\"individualUsage\":{\"\(key)\":{\"limit\":1000}}}"))
            let zero = try CursorProvider.parse(data("{\"individualUsage\":{\"\(key)\":{\"limit\":1000,\"used\":0}}}"))
            try check(missing, zero)
            let remaining = try CursorProvider.parse(data("{\"individualUsage\":{\"\(key)\":{\"limit\":1000,\"remaining\":750}}}"))
            XCTAssertEqual(remaining.windows.first?.usedPercent, 25)
        }
    }

    func testAlibabaDoesNotAssumeZeroForMissingUsedQuota() throws {
        try check(
            AlibabaCodingPlanProvider.parse(data(#"{"per5HourTotalQuota":100}"#)),
            AlibabaCodingPlanProvider.parse(data(#"{"per5HourTotalQuota":100,"per5HourUsedQuota":0}"#)))
    }

    func testMiMoKeepsItsRealBalanceWithoutInventingPlanUsage() throws {
        let balance = data(#"{"code":0,"data":{"balance":20,"currency":"CNY"}}"#)
        let missing = try MiMoProvider.parse(balance: balance, detail: nil, usage: data(#"{"data":{"monthUsage":{"items":[{"limit":100}]}}}"#))
        let zero = try MiMoProvider.parse(balance: balance, detail: nil, usage: data(#"{"data":{"monthUsage":{"items":[{"limit":100,"used":0}]}}}"#))
        try check(missing, zero)
        XCTAssertEqual(missing.balance?.balances.first?.total, 20)
    }

    func testQoderDoesNotTreatUnreportedSharedUsageAsUnused() throws {
        try check(
            QoderProvider.parse(data(#"{"totalQuota":{"quotaSummary":{"limitValue":100}}}"#)),
            QoderProvider.parse(data(#"{"totalQuota":{"quotaSummary":{"limitValue":100,"usedValue":0}}}"#)))
        let partial = try QoderProvider.parse(data(#"{"totalQuota":{"quotaSummary":{"limitValue":100,"usedValue":50}},"sharedQuota":{"quotaSummary":{"limitValue":100}}}"#))
        XCTAssertNil(partial.windows.first?.usedPercent)
        let published = try QoderProvider.parse(data(#"{"totalQuota":{"quotaSummary":{"limitValue":100,"usagePercentage":25}},"sharedQuota":{"quotaSummary":{"limitValue":100,"usagePercentage":75}}}"#))
        XCTAssertEqual(published.windows.first?.usedPercent, 50)
    }

    func testWindsurfRequiresUsedOrRemainingForEveryCounter() throws {
        for (total, used, remaining) in [("messages", "usedMessages", "remainingMessages"), ("flowActions", "usedFlowActions", "remainingFlowActions"), ("flexCredits", "usedFlexCredits", "remainingFlexCredits")] {
            try check(
                WindsurfProvider.parse(data("{\"usage\":{\"\(total)\":100}}")),
                WindsurfProvider.parse(data("{\"usage\":{\"\(total)\":100,\"\(used)\":0}}")))
            let actual = try WindsurfProvider.parse(data("{\"usage\":{\"\(total)\":100,\"\(remaining)\":80}}"))
            XCTAssertEqual(actual.windows.first?.usedPercent, 20)
        }
    }

    func testKiroRequiresTheCurrentUsageCounter() throws {
        try check(
            KiroProvider.parse(data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100}]}"#)),
            KiroProvider.parse(data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":0}]}"#)))
    }

    func testKimiWebMissingOrMalformedCounterDoesNotBecomeZero() async throws {
        for used in ["", ",\"used\":\"bad\"", ",\"used\":\"0\"", ",\"used\":\"20\""] {
            let send: HTTPSend = { _, url, _, _, _ in
                let body = url.path.hasSuffix("GetUsages")
                    ? "{\"usages\":[{\"scope\":\"FEATURE_CODING\",\"detail\":{\"limit\":\"100\"\(used)}}]}" : "{}"
                return HTTPResponse(status: 200, data: Data(body.utf8))
            }
            let snapshot = try await KimiProvider.fetchWeb(token: "test", edition: .global, send: send)
            let expected: Double? = used.contains("20") ? 20 : used.contains("\"0\"") ? 0 : nil
            XCTAssertEqual(try XCTUnwrap(snapshot.windows.first).usedPercent, expected)
            if expected == nil { XCTAssertNil(snapshot.windows.first?.detail) }
        }
    }

    func testClaudeCreditDoesNotInventUnusedMoneyOrFullRemainingPercentage() throws {
        let unknown = try XCTUnwrap(ClaudeProvider.creditWindows(data(#"{"promotion":{"limit_dollars":100}}"#)).first)
        XCTAssertNil(unknown.usedPercent)
        XCTAssertEqual(unknown.credit?.amount, L10n.t("Balance not provided", "余额未提供"))
        XCTAssertFalse(unknown.detail?.contains("$0.00") ?? false)
        let zero = try XCTUnwrap(ClaudeProvider.creditWindows(data(#"{"promotion":{"limit_dollars":100,"remaining_dollars":100}}"#)).first)
        XCTAssertEqual(zero.usedPercent, 0)
        XCTAssertEqual(zero.credit?.amount, "$100.00")
        let cinder = try XCTUnwrap(ClaudeProvider.creditWindows(data(#"{"cinder_cove":{}}"#)).first)
        XCTAssertNil(cinder.usedPercent)
        XCTAssertEqual(cinder.credit?.amount, L10n.t("Usage not provided", "用量未提供"))
    }
}
