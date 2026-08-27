import SQLite3
import XCTest
@testable import QuotaCore

final class SpendBreakdownTests: XCTestCase {
    func testContributionsAreLargestFirstAndDropZeroes() {
        let spend = SpendBreakdown(usd: 100, bySource: [
            .codexCLI: 30, .claudeCode: 65, .openCode: 0,
        ])

        XCTAssertEqual(spend.contributions.map(\.source), [.claudeCode, .codexCLI])
        XCTAssertEqual(spend.contributions.map(\.usd), [65, 30])
    }

    func testKnowsWhenItIsMixingEstimatesWithReportedFigures() {
        // The two are not the same kind of number, and the UI says so.
        XCTAssertTrue(SpendBreakdown(bySource: [.claudeCode: 5]).containsEstimates)
        XCTAssertFalse(SpendBreakdown(bySource: [.openCode: 5]).containsEstimates)
        XCTAssertTrue(SpendBreakdown(bySource: [.openCode: 5, .codexCLI: 1]).containsEstimates)
    }

    func testSourceProvenance() {
        XCTAssertTrue(CostSource.claudeCode.isEstimated)
        XCTAssertTrue(CostSource.codexCLI.isEstimated)
        XCTAssertFalse(CostSource.openCode.isEstimated, "opencode records its own cost")
    }

    func testChartColoursAreMutuallyDistinguishable() {
        // Adjacent slices of one ring: perceptual distance, not luminance.
        // Brand accents fail this — Codex and OpenCode differ by ~0.11 in
        // luminance and read as the same blue.
        let colours = CostSource.allCases.map(\.accentHex)
        for i in colours.indices {
            for j in colours.indices where j > i {
                XCTAssertGreaterThan(
                    deltaE(colours[i], colours[j]), 25,
                    "\(colours[i]) and \(colours[j]) are too close")
            }
        }
    }

    func testEmptyBreakdownHasNoData() {
        XCTAssertFalse(SpendBreakdown().hasData)
        XCTAssertTrue(SpendBreakdown().contributions.isEmpty)
    }

    // CIE76 colour difference in Lab.
    private func deltaE(_ a: String, _ b: String) -> Double {
        func lab(_ hex: String) -> (Double, Double, Double) {
            func channel(_ offset: Int) -> Double {
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: 2)
                let value = Double(UInt8(hex[start..<end], radix: 16) ?? 0) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let (r, g, blue) = (channel(0), channel(2), channel(4))
            let x = (r * 0.4124 + g * 0.3576 + blue * 0.1805) / 0.95047
            let y = r * 0.2126 + g * 0.7152 + blue * 0.0722
            let z = (r * 0.0193 + g * 0.1192 + blue * 0.9505) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a)
        let (l2, a2, b2) = lab(b)
        return sqrt(pow(l1 - l2, 2) + pow(a1 - a2, 2) + pow(b1 - b2, 2))
    }
}

/// The opencode source reads that tool's own SQLite store, so these build one.
final class OpenCodeCostTests: XCTestCase {
    private var root: URL!
    private var paths: CostPaths!
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-oc-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        paths = CostPaths(
            claudeProjects: empty,
            codexSessions: empty,
            openCodeDatabase: root.appendingPathComponent("opencode.db"))
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    /// (id, cost, updated) — `updated` is a Date, stored as epoch millis.
    private func makeDatabase(_ sessions: [(String, Double, Date)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(paths.openCodeDatabase.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE session (id TEXT, cost REAL, tokens_input INTEGER,
          tokens_output INTEGER, tokens_cache_read INTEGER,
          tokens_cache_write INTEGER, time_updated INTEGER);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (id, cost, updated) in sessions {
            let millis = Int(updated.timeIntervalSince1970 * 1000)
            let insert = """
            INSERT INTO session VALUES ('\(id)', \(cost), 100, 20, 5, 1, \(millis));
            """
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
    }

    private func localNoon(daysAgo offset: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: 12, to: day)!
    }

    func testUsesTheRecordedCostVerbatim() throws {
        // Not re-derived from token counts: opencode knows its own rates.
        try makeDatabase([("ses_a", 13.5847, localNoon(daysAgo: 0))])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.windowUSD, 13.5847, accuracy: 0.0001)
        XCTAssertEqual(summary.spend(.window).bySource[.openCode] ?? 0, 13.5847, accuracy: 0.0001)
    }

    func testSessionsAreDeduplicatedById() throws {
        try makeDatabase([
            ("ses_a", 5, localNoon(daysAgo: 0)),
            ("ses_a", 5, localNoon(daysAgo: 0)),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.windowUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.deduplicated, 1)
    }

    func testZeroCostSessionsAreSkipped() throws {
        try makeDatabase([("ses_a", 0, localNoon(daysAgo: 0)), ("ses_b", 2, localNoon(daysAgo: 0))])
        XCTAssertEqual(CostEstimator.summary(paths: paths, now: now).windowUSD, 2, accuracy: 0.0001)
    }

    func testSplitsAcrossPeriods() throws {
        try makeDatabase([
            ("ses_today", 10, localNoon(daysAgo: 0)),
            ("ses_yesterday", 4, localNoon(daysAgo: 1)),
            ("ses_older", 6, localNoon(daysAgo: 5)),
        ])

        let summary = CostEstimator.summary(paths: paths, now: now)

        XCTAssertEqual(summary.spend(.today).usd, 10, accuracy: 0.0001)
        XCTAssertEqual(summary.spend(.yesterday).usd, 4, accuracy: 0.0001)
        XCTAssertEqual(summary.spend(.window).usd, 20, accuracy: 0.0001)
    }

    func testAMissingDatabaseIsNotAnError() {
        // opencode simply may not be installed.
        let summary = CostEstimator.summary(paths: paths, now: now)
        XCTAssertFalse(summary.hasData)
    }
}
