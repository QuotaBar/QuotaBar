import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// The API credit a Claude plan includes, as platform.claude.com's billing
/// page reads it. The reply shape follows steipete/CodexBar's Claude Platform
/// provider; identifiers made up.
final class ClaudeConsoleCreditsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testOnlyAPIOrganizationsOwnBilling() throws {
        let list = """
        [{"uuid":"chat-1","name":"Chat","capabilities":["chat","claude_max"]},
         {"uuid":"api-1","name":"Peter's Individual Org","capabilities":["api","chat"]},
         {"uuid":"bad id;","capabilities":["api"]}]
        """
        let found = try XCTUnwrap(ClaudeConsoleCredits.organizations(data(list)))
        XCTAssertEqual(found.map(\.id), ["api-1"])
        XCTAssertEqual(found.first?.name, "Peter's Individual Org")
        XCTAssertNil(ClaudeConsoleCredits.organizations(data(#"{"error":"x"}"#)))
    }

    func testThePlansCreditComesFirstAndPurchasedOnesAreLeftOut() throws {
        let body = """
        {"amount":32475,"currency":"USD","balance":{"credits":{"exponent":2}},
         "promo_tranches":[
           {"name":"Launch bonus","program_id":"promo","granted_amount_minor_units":1000,"remaining_amount_minor_units":1000,"expires_at":"2026-11-20T00:00:00Z"},
           {"name":"Max plan credit","program_id":"subscription_api_credit","granted_amount_minor_units":20000,"remaining_amount_minor_units":12475,"expires_at":"2026-12-01T00:00:00Z"},
           {"program_id":"subscription_api_credit","granted_amount_minor_units":20000,"remaining_amount_minor_units":0,"expires_at":"2026-11-30T00:00:00Z"},
           {"program_id":"promo","granted_amount_minor_units":500,"remaining_amount_minor_units":500,"expires_at":"2026-11-01T00:00:00Z"}],
         "tranches":[{"granted_amount_minor_units":10000,"remaining_amount_minor_units":10000,"expires_at":null}]}
        """
        let grants = try XCTUnwrap(ClaudeConsoleCredits.grants(data(body), now: now))
        XCTAssertEqual(grants.count, 4, "the passed grant is dropped")
        XCTAssertEqual(grants.filter(\.purchased).map(\.granted), [100])

        let windows = ClaudeConsoleCredits.windows(.init(organization: "Org", grants: grants), now: now)
        XCTAssertEqual(windows.count, 2, "spent and bought grants are not rows")
        let plan = windows[0]
        XCTAssertEqual(plan.title, L10n.t("API credit", "API 赠送额度"))
        XCTAssertEqual(plan.credit?.amount, "$124.75")
        XCTAssertEqual(plan.usedPercent ?? 0, 37.625, accuracy: 0.001)
        XCTAssertTrue(plan.detail?.hasPrefix("$75.25 / $200.00") ?? false)
        XCTAssertEqual(plan.credit?.expiresAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        XCTAssertTrue(plan.extra)
        XCTAssertEqual(windows[1].title, "Launch bonus")
        XCTAssertNotEqual(windows[0].id, windows[1].id)
    }

    func testTheReportedExponentScalesAmounts() throws {
        let body = """
        {"amount":2000000,"balance":{"credits":{"exponent":4}},
         "promo_tranches":[{"program_id":"subscription_api_credit","granted_amount_minor_units":2000000,"remaining_amount_minor_units":2000000}]}
        """
        let grants = try XCTUnwrap(ClaudeConsoleCredits.grants(data(body), now: now))
        XCTAssertEqual(grants.first?.granted, 200)
        XCTAssertNil(grants.first?.expiresAt)
    }

    func testRepliesThatAreNotABalanceAreRejected() {
        XCTAssertNil(ClaudeConsoleCredits.grants(data(#"{"error":{"type":"permission_error"}}"#), now: now))
        XCTAssertNil(ClaudeConsoleCredits.grants(data(#"{"amount":100,"currency":"EUR","promo_tranches":[]}"#), now: now))
        XCTAssertNil(ClaudeConsoleCredits.grants(data(#"{"amount":100,"balance":{"credits":{"exponent":9}}}"#), now: now))
        XCTAssertNil(ClaudeConsoleCredits.grants(data(#"{"amount":100,"promo_tranches":{}}"#), now: now))
        XCTAssertEqual(ClaudeConsoleCredits.grants(data(#"{"amount":0}"#), now: now), [])
    }

    func testTheDeadlineIsTheUTCDay() {
        let midnight = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        XCTAssertTrue(ClaudeConsoleCredits.utcDay(midnight).contains("1"))
        XCTAssertFalse(ClaudeConsoleCredits.utcDay(midnight).contains("30"), "not the evening before in the Americas")
    }

    func testConsoleCookiesAreNotClaudeAis() {
        XCTAssertEqual(ClaudeWebSession.Site.console.matches("host_key"),
                       "(host_key = 'platform.claude.com' or host_key like '%.platform.claude.com')")
        XCTAssertFalse(ClaudeWebSession.Site.console.inApp)
    }
}
