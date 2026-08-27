import XCTest
@testable import QuotaCore

final class PricingCatalogTests: XCTestCase {
    /// The published catalog's shape, trimmed to the fields we price with.
    private let payload = """
    {
      "gpt-5.6-sol": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002,
                      "cache_read_input_token_cost": 0.0000004, "max_tokens": 128000},
      "claude-opus-5": {"input_cost_per_token": 0.000005, "output_cost_per_token": 0.000025,
                        "cache_creation_input_token_cost": 0.00000625,
                        "cache_read_input_token_cost": 0.0000005},
      "claude-opus-4-5": {"input_cost_per_token": 0.000005, "output_cost_per_token": 0.000025},
      "some-embedding": {"input_cost_per_token": 0, "output_cost_per_token": 0}
    }
    """

    func testConvertsPerTokenCostsToPerMillion() throws {
        let table = try XCTUnwrap(PricingCatalog.parse(Data(payload.utf8)))
        let sol = try XCTUnwrap(table["gpt-5.6-sol"])

        XCTAssertEqual(sol.input, 4, accuracy: 0.0001)
        XCTAssertEqual(sol.output, 20, accuracy: 0.0001)
        XCTAssertEqual(sol.cacheRead, 0.4, accuracy: 0.0001)
    }

    func testDerivesTheLongCacheWriteRate() throws {
        let table = try XCTUnwrap(PricingCatalog.parse(Data(payload.utf8)))
        let opus = try XCTUnwrap(table["claude-opus-5"])

        // The catalog publishes only the 5-minute write; the 1-hour one is 2x input.
        XCTAssertEqual(opus.cacheWrite, 6.25, accuracy: 0.0001)
        XCTAssertEqual(opus.cacheWriteLong, 10, accuracy: 0.0001)
    }

    func testSkipsFreeEntries() throws {
        let table = try XCTUnwrap(PricingCatalog.parse(Data(payload.utf8)))
        XCTAssertNil(table["some-embedding"], "zero-cost rows are not billable models")
    }

    func testRejectsGarbage() {
        XCTAssertNil(PricingCatalog.parse(Data("not json".utf8)))
    }

    // MARK: Lookup

    private func catalog(seeded: String) throws -> PricingCatalog {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-pricing-\(UUID().uuidString)")
            .appendingPathComponent("pricing.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let table = try XCTUnwrap(PricingCatalog.parse(Data(seeded.utf8)))
        try JSONEncoder().encode(table).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return PricingCatalog(cacheURL: url)
    }

    func testExactModelIdWins() throws {
        let catalog = try catalog(seeded: payload)
        XCTAssertEqual(catalog.rates(for: "gpt-5.6-sol")?.input, 4)
    }

    func testStripsADateStampWhenTheExactIdIsAbsent() throws {
        let catalog = try catalog(seeded: payload)
        XCTAssertEqual(catalog.rates(for: "claude-opus-4-5-20251101")?.input, 5)
    }

    func testDoesNotPrefixMatch() throws {
        // The whole point: "gpt-5.6-luna" must not resolve through "gpt-5.6-sol"
        // or any other prefix. An unknown model returns nil so the caller can
        // fall back deliberately.
        let catalog = try catalog(seeded: payload)
        XCTAssertNil(catalog.rates(for: "gpt-5.6-luna"))
        XCTAssertNil(catalog.rates(for: "gpt-5"))
    }

    func testLookupIsCaseInsensitive() throws {
        let catalog = try catalog(seeded: payload)
        XCTAssertEqual(catalog.rates(for: "GPT-5.6-Sol")?.input, 4)
    }

    func testAnAbsentCacheLeavesItUnloaded() {
        let catalog = PricingCatalog(
            cacheURL: URL(fileURLWithPath: "/nonexistent/quotabar/pricing.json"))
        XCTAssertFalse(catalog.isLoaded)
        XCTAssertNil(catalog.rates(for: "claude-opus-5"))
    }
}
