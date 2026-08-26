import XCTest
@testable import QuotaCore

/// The estimator reads real CLI session logs, so these tests build a throwaway
/// log tree per case and point the estimator at it.
final class CostEstimatorTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private var paths: CostPaths!

    /// Fixed clock so "this month" and "today" are deterministic.
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    /// The estimator buckets by the *local* calendar (that is what "this month"
    /// means to the user) while logs are stamped in UTC, so boundary fixtures
    /// are derived from the calendar rather than written as UTC literals.
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private var localMonthStart: Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    }

    private var localDayStart: Date {
        Calendar.current.startOfDay(for: now)
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-cost-\(UUID().uuidString)")
        claudeRoot = root.appendingPathComponent("claude/projects")
        codexRoot = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claudeRoot, codexSessions: codexRoot)
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    // MARK: Fixtures

    private func writeClaude(_ name: String, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: claudeRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func claudeLine(
        messageID: String,
        requestID: String,
        model: String = "claude-opus-5",
        timestamp: String = "2026-08-26T10:00:00.000Z",
        input: Int = 0,
        output: Int = 0,
        write5m: Int = 0,
        write1h: Int = 0,
        read: Int = 0) -> String
    {
        """
        {"type":"assistant","requestId":"\(requestID)","timestamp":"\(timestamp)",\
        "message":{"id":"\(messageID)","model":"\(model)","usage":{\
        "input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(write5m + write1h),\
        "cache_read_input_tokens":\(read),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)}}}}
        """
    }

    private func writeCodex(_ name: String, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .write(to: codexRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func codexLine(
        timestamp: String = "2026-08-26T10:00:00.000Z",
        input: Int,
        cached: Int,
        output: Int) -> String
    {
        """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output)}}}}
        """
    }

    // MARK: Deduplication

    func testSameAssistantTurnInTwoFilesIsBilledOnce() throws {
        let line = claudeLine(messageID: "msg_1", requestID: "req_1", output: 1_000_000)
        try writeClaude("a.jsonl", lines: [line])
        // Resuming a conversation replays prior turns into a new session file.
        try writeClaude("b.jsonl", lines: [line])

        let summary = CostEstimator.summary(paths: paths, now: now)

        // 1M output tokens on Opus = $25.00, counted exactly once.
        XCTAssertEqual(summary.monthUSD, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.monthTokens, 1_000_000)
        XCTAssertEqual(summary.deduplicated, 1)
    }

    func testDistinctTurnsAreBothBilled() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "msg_1", requestID: "req_1", output: 1_000_000),
            claudeLine(messageID: "msg_2", requestID: "req_2", output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.monthUSD, 50.0, accuracy: 0.0001)
        XCTAssertEqual(summary.deduplicated, 0)
    }

    // MARK: Cache tiers

    func testOneHourCacheWriteCostsMoreThanFiveMinute() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m5", requestID: "r5", write5m: 1_000_000),
        ])
        let fiveMinute = CostEstimator.summary(paths: paths, now: now).monthUSD

        CostEstimator.resetCache()
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m1", requestID: "r1", write1h: 1_000_000),
        ])
        let oneHour = CostEstimator.summary(paths: paths, now: now).monthUSD

        // Opus: 5m write = $6.25/M, 1h write = $10.00/M.
        XCTAssertEqual(fiveMinute, 6.25, accuracy: 0.0001)
        XCTAssertEqual(oneHour, 10.0, accuracy: 0.0001)
    }

    func testFlatCacheCreationFallsBackToFiveMinuteRate() throws {
        // Older log format: no `cache_creation` breakdown at all.
        let line = """
        {"type":"assistant","requestId":"r","timestamp":"2026-08-26T10:00:00.000Z",\
        "message":{"id":"m","model":"claude-opus-5","usage":{\
        "input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000,\
        "cache_read_input_tokens":0}}}
        """
        try writeClaude("a.jsonl", lines: [line])

        XCTAssertEqual(CostEstimator.summary(paths: paths, now: now).monthUSD, 6.25, accuracy: 0.0001)
    }

    // MARK: Codex cached-input handling

    func testCodexCachedInputIsNotBilledTwice() throws {
        // 1M input of which 1M was cached: the fresh-input charge must be zero.
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 1_000_000, output: 0),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        // gpt-5-codex cache read = $0.125/M. Billing the input again would give $1.375.
        XCTAssertEqual(summary.monthUSD, 0.125, accuracy: 0.0001)
    }

    func testCodexFreshInputIsBilledAtInputRate() throws {
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 0, output: 0),
        ])

        XCTAssertEqual(CostEstimator.summary(paths: paths, now: now).monthUSD, 1.25, accuracy: 0.0001)
    }

    // MARK: Time boundaries

    func testEventsBeforeThisMonthAreExcluded() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(
                messageID: "old", requestID: "old",
                timestamp: iso(localMonthStart.addingTimeInterval(-1)), output: 1_000_000),
            claudeLine(
                messageID: "new", requestID: "new",
                timestamp: iso(localMonthStart.addingTimeInterval(1)), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.monthUSD, 25.0, accuracy: 0.0001)
    }

    func testTodayIsASubsetOfTheMonth() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(
                messageID: "earlier", requestID: "e",
                timestamp: iso(localDayStart.addingTimeInterval(-3600)), output: 1_000_000),
            claudeLine(
                messageID: "today", requestID: "t",
                timestamp: iso(localDayStart.addingTimeInterval(3600)), output: 1_000_000),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.monthUSD, 50.0, accuracy: 0.0001)
        XCTAssertEqual(summary.todayUSD, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.todayTokens, 1_000_000)
    }

    // MARK: Attribution

    func testSpendIsAttributedPerCLI() throws {
        try writeClaude("a.jsonl", lines: [
            claudeLine(messageID: "m", requestID: "r", output: 1_000_000),
        ])
        try writeCodex("rollout-1.jsonl", lines: [
            codexLine(input: 1_000_000, cached: 0, output: 0),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.monthBySource[.claudeCode] ?? 0, 25.0, accuracy: 0.0001)
        XCTAssertEqual(summary.monthBySource[.codexCLI] ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(summary.monthUSD, 26.25, accuracy: 0.0001)
    }

    func testEmptyTreeProducesNoData() {
        let summary = CostEstimator.summary(paths: paths, now: now)
        XCTAssertFalse(summary.hasData)
        XCTAssertEqual(summary, .empty)
    }
}

// MARK: - Pricing table

final class PricingTests: XCTestCase {
    func testModelIDsMapToTheirListPrices() {
        // (model, input, output) per million tokens.
        let expectations: [(String, Double, Double)] = [
            ("claude-fable-5", 10, 50),
            ("claude-opus-5", 5, 25),
            ("claude-opus-4-8", 5, 25),
            ("claude-sonnet-5", 2, 10),
            ("claude-sonnet-4-6", 3, 15),
            ("claude-haiku-4-5", 1, 5),
            ("gpt-5-codex", 1.25, 10),
            ("gpt-5.3-codex", 1.25, 10),
        ]
        for (model, input, output) in expectations {
            let rates = Pricing.perMillion(for: model)
            XCTAssertEqual(rates.0, input, accuracy: 0.001, "input rate for \(model)")
            XCTAssertEqual(rates.1, output, accuracy: 0.001, "output rate for \(model)")
        }
    }

    func testSonnet5IsMatchedBeforeGenericSonnet() {
        // Ordering bug guard: "claude-sonnet-5" contains "sonnet" too.
        XCTAssertEqual(Pricing.perMillion(for: "claude-sonnet-5").0, 2, accuracy: 0.001)
        XCTAssertEqual(Pricing.perMillion(for: "claude-sonnet-4-6").0, 3, accuracy: 0.001)
    }

    func testAnthropicCacheWriteTiers() {
        // 5-minute = 1.25x input, 1-hour = 2x input.
        let opus = Pricing.perMillion(for: "claude-opus-5")
        XCTAssertEqual(opus.2, opus.0 * 1.25, accuracy: 0.001)
        XCTAssertEqual(opus.3, opus.0 * 2.0, accuracy: 0.001)
        XCTAssertEqual(opus.4, opus.0 * 0.1, accuracy: 0.001)
    }

    func testUnknownModelIsPricedNotFree() {
        XCTAssertGreaterThan(Pricing.perMillion(for: "some-future-model").0, 0)
    }
}
