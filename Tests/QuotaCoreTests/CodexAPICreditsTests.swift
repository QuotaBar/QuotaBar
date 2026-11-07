import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// The API credit a ChatGPT Pro plan includes. Replies recorded live in
/// November 2026 on a Pro 500 account, identifiers replaced.
final class CodexAPICreditsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!
    private func data(_ text: String) -> Data { Data(text.utf8) }

    private let linked = """
    {"eligible":false,"ineligibility_reason":"already_linked","offer":null,
     "benefit":{"currency":"USD","cadence":"monthly","period_credit_amount_usd":"500.00","expires_at":"2026-11-14T14:30:01Z"}}
    """

    func testALinkedCreditIsTheMonthlyAllowanceAndItsDeadline() throws {
        var benefit = try XCTUnwrap(CodexAPICredits.benefit(data(linked)))
        XCTAssertEqual(benefit.amount, 500)
        XCTAssertTrue(benefit.linked)
        XCTAssertFalse(benefit.claimable)
        XCTAssertEqual(benefit.expiresAt, ISO8601DateFormatter().date(from: "2026-11-14T14:30:01Z"))

        let links = """
        {"links":[{"id":"x","source_type":"chatgpt_account","source_account_id":"acc","destination_type":"api_org",
          "destination_account_id":"org-1","state":"active","destination_display_name":"GiantAccel","delivery_result":null,"can_unlink":true}]}
        """
        benefit.organization = CodexAPICredits.organization(data(links))
        XCTAssertEqual(benefit.organization, "GiantAccel")

        let window = try XCTUnwrap(CodexAPICredits.window(benefit, now: now))
        XCTAssertEqual(window.title, L10n.t("API credit", "API 赠送额度"))
        XCTAssertEqual(window.credit?.amount, L10n.t("$500.00 a month", "每月 $500.00"))
        XCTAssertNil(window.credit?.expiresAt, "a monthly allowance, not a balance to warn about")
        XCTAssertNil(window.usedPercent, "what is left is not in the reply")
        XCTAssertTrue(window.detail?.contains("GiantAccel") ?? false)
        XCTAssertTrue(window.extra)
    }

    func testAnUnclaimedCreditSaysSo() throws {
        let body = #"{"eligible":true,"ineligibility_reason":null,"offer":{"currency":"USD","cadence":"monthly","period_credit_amount_usd":"200.00"},"benefit":null}"#
        let benefit = try XCTUnwrap(CodexAPICredits.benefit(data(body)))
        XCTAssertTrue(benefit.claimable)
        let window = try XCTUnwrap(CodexAPICredits.window(benefit, now: now))
        XCTAssertEqual(window.credit?.caption, L10n.t("Not claimed yet", "还没领取"))
    }

    func testNoRowForAnAccountTheOfferIsNotFor() {
        XCTAssertNil(CodexAPICredits.benefit(data(#"{"eligible":false,"ineligibility_reason":"plan_not_eligible","offer":null,"benefit":null}"#)))
        XCTAssertNil(CodexAPICredits.benefit(data(#"{"eligible":false,"ineligibility_reason":"plan_not_eligible","benefit":{"period_credit_amount_usd":"500.00"}}"#)))
        XCTAssertNil(CodexAPICredits.benefit(data(#"{"detail":"Not found"}"#)))
        XCTAssertNil(CodexAPICredits.organization(data(#"{"links":[{"destination_type":"api_org","state":"inactive","destination_display_name":"Old"}]}"#)))
    }

    func testAPassedPeriodIsNotShown() throws {
        let benefit = try XCTUnwrap(CodexAPICredits.benefit(data(linked)))
        XCTAssertNil(CodexAPICredits.window(benefit, now: ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!))
    }

    // MARK: Keys

    func testShellExportsAreReadLiterallyOnly() {
        let text = """
        # export OPENAI_API_KEY=sk-commented-out-xxxxxxxxxxxx
        export OPENAI_API_KEY="sk-proj-first-xxxxxxxxxxxxxxxx"
        OPENAI_ADMIN_KEY='sk-admin-abcdefghijklmnopqrst' # org admin
        export OPENAI_API_KEY=sk-proj-second-xxxxxxxxxxxxxxx
        export OTHER=1
        """
        let found = CodexAPICredits.exports(text)
        XCTAssertEqual(found["OPENAI_API_KEY"], "sk-proj-second-xxxxxxxxxxxxxxx", "the last one wins")
        XCTAssertEqual(found["OPENAI_ADMIN_KEY"], "sk-admin-abcdefghijklmnopqrst")
        XCTAssertNil(CodexAPICredits.exports("export OPENAI_API_KEY=$(security find-generic-password -w)")["OPENAI_API_KEY"])
        XCTAssertNil(CodexAPICredits.exports("export OPENAI_API_KEY=\"$KEY\"")["OPENAI_API_KEY"])
    }

    func testKeysAreFoundOnTheMacAdminFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"OPENAI_API_KEY":"sk-proj-fromcodexauthxxxxxxx","tokens":null}"#
            .write(to: home.appendingPathComponent(".codex/auth.json"), atomically: true, encoding: .utf8)
        try "export OPENAI_ADMIN_KEY=sk-admin-fromzshrcxxxxxxxxxx\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let keys = CodexAPICredits.localKeys(environment: ["OPENAI_API_KEY": "sk-proj-fromcodexauthxxxxxxx", "OPENAI_ADMIN_KEY": "nope"], home: home)
        XCTAssertEqual(keys.map(\.value), ["sk-admin-fromzshrcxxxxxxxxxx", "sk-proj-fromcodexauthxxxxxxx"])
        XCTAssertEqual(keys.first?.source, "~/.zshrc · OPENAI_ADMIN_KEY")
        XCTAssertEqual(keys.last?.source, "OPENAI_API_KEY", "the same key twice is listed once, where found first")
        XCTAssertEqual(CodexAPICredits.keys(saved: "sk-typed-in-settings-xxxx").map(\.value), ["sk-typed-in-settings-xxxx"])
    }

    // MARK: Balance

    func testTheGrantThatEndsWithThePeriodIsTheBalance() throws {
        let body = """
        {"object":"credit_summary","total_granted":300.0,"total_used":10.07,"total_available":289.93,
         "grants":{"object":"list","data":[
           {"object":"credit_grant","grant_amount":34.0,"used_amount":10.0,"effective_at":1790000000,"expires_at":1798000000},
           {"object":"credit_grant","grant_amount":266.0,"used_amount":0.07,"effective_at":1793232000,"expires_at":1794666601}]}}
        """
        let expiring = ISO8601DateFormatter().date(from: "2026-11-14T14:30:01Z")!
        let balance = try XCTUnwrap(CodexAPICredits.grantBalance(Data(body.utf8), expiring: expiring))
        XCTAssertEqual(balance.granted, 266)
        XCTAssertEqual(balance.remaining, 265.93, accuracy: 0.0001)
        XCTAssertFalse(balance.estimated)

        let totals = try XCTUnwrap(CodexAPICredits.grantBalance(Data(#"{"total_granted":50,"total_available":20}"#.utf8), expiring: nil))
        XCTAssertEqual(totals.used, 30)
        XCTAssertNil(CodexAPICredits.grantBalance(Data(#"{"error":{"message":"x"}}"#.utf8), expiring: expiring))
    }

    func testCostsAddUpAcrossBucketsInDollars() throws {
        let body = """
        {"object":"page","data":[
          {"start_time":1,"end_time":2,"results":[{"amount":{"value":1.25,"currency":"usd"}},{"amount":{"value":0.5,"currency":"usd"}}]},
          {"start_time":2,"end_time":3,"results":[]}],
         "has_more":true,"next_page":"page_abc"}
        """
        let read = try XCTUnwrap(CodexAPICredits.costs(Data(body.utf8)))
        XCTAssertEqual(read.total, 1.75, accuracy: 0.0001)
        XCTAssertEqual(read.next, "page_abc")
        XCTAssertNil(CodexAPICredits.costs(Data(#"{"error":"forbidden"}"#.utf8)))
    }

    func testThePeriodBeganAMonthBeforeItEnds() throws {
        let benefit = try XCTUnwrap(CodexAPICredits.benefit(data(linked)))
        XCTAssertEqual(CodexAPICredits.periodStart(benefit, now: now), ISO8601DateFormatter().date(from: "2026-10-14T14:30:01Z"))
    }

    func testABalanceMakesABar() throws {
        var benefit = try XCTUnwrap(CodexAPICredits.benefit(data(linked)))
        benefit.organization = "GiantAccel"
        let exact = try XCTUnwrap(CodexAPICredits.window(benefit, balance: .init(granted: 266, used: 0.07, estimated: false), now: now))
        XCTAssertEqual(exact.credit?.amount, "$265.93")
        XCTAssertEqual(exact.usedPercent ?? 0, 0.07 / 266 * 100, accuracy: 0.0001)
        XCTAssertNotNil(exact.credit?.expiresAt, "an exact balance gets the expiry reminder")
        XCTAssertTrue(exact.detail?.hasPrefix("$0.07 / $266.00") ?? false)

        let estimate = try XCTUnwrap(CodexAPICredits.window(benefit, balance: .init(granted: 500, used: 600, estimated: true), now: now))
        XCTAssertEqual(estimate.credit?.amount, L10n.t("about $0.00", "约 $0.00"))
        XCTAssertEqual(estimate.usedPercent, 100)
        XCTAssertNil(estimate.credit?.expiresAt, "an estimate sends no reminder")
    }
}
