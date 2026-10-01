import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// What Codex and Claude give an account beside its plan: credits and limit
/// resets. Fixtures recorded live in October 2026, identifiers replaced.
final class GivenCreditsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    // MARK: Codex credits

    func testCodexCreditBalanceIsCountedAndExplained() throws {
        let response = """
        {"plan_type":"promax","rate_limit":null,
         "credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"62500",
                    "approx_local_messages":[15625,81250],"approx_cloud_messages":[2500,15625]}}
        """
        let snapshot = try CodexProvider.parse(Data(response.utf8))
        XCTAssertEqual(snapshot.planName, "Pro 500")
        let credits = try XCTUnwrap(snapshot.windows.first { $0.title == L10n.t("Credits", "额度点数") })
        XCTAssertEqual(credits.detail, L10n.t("62,500 credits", "62,500 点"))
        XCTAssertTrue(try XCTUnwrap(credits.note).contains("15,625–81,250"))
        XCTAssertEqual(credits.credit?.amount, L10n.t("62,500 credits", "62,500 点"))
        XCTAssertNil(credits.credit?.expiresAt, "the endpoint gives credits no deadline")
        XCTAssertFalse(snapshot.upFrontWindows(for: .codex).contains { $0.id == credits.id }, "under the arrow, not up front")
    }

    /// `/accounts/{id}/remaining_balance`, recorded live.
    func testCodexCreditsCarryTheirDeadlineAndOrigin() throws {
        let body = """
        {"balance":"62500","expiring_balance_details":[{"amount_granted":"62500","amount_remaining":"62500",
          "expiry_date":"2027-01-01T00:00:00Z","grant_type":"promotional_credit"}]}
        """
        let grants = try XCTUnwrap(CodexProvider.creditGrants(Data(body.utf8), now: now))
        XCTAssertEqual(grants.count, 1)
        XCTAssertTrue(grants[0].isGiven)

        let usage = """
        {"plan_type":"pro","credits":{"has_credits":true,"unlimited":false,"balance":"62500",
                                      "approx_local_messages":[15625,81250]}}
        """
        var window = try XCTUnwrap(try CodexProvider.parse(Data(usage.utf8)).windows.first { $0.credit != nil })
        CodexProvider.apply(grants, to: &window)
        XCTAssertEqual(window.credit?.expiresAt, ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        XCTAssertEqual(window.credit?.caption, L10n.t("Given 62,500 credits", "赠送 62,500 点"))
    }

    func testSpentAndPassedGrantsAreDropped() throws {
        let body = """
        {"balance":"10","expiring_balance_details":[
          {"amount_granted":"100","amount_remaining":"0","expiry_date":"2026-12-01T00:00:00Z","grant_type":"promotional_credit"},
          {"amount_granted":"100","amount_remaining":"10","expiry_date":"2026-09-01T00:00:00Z","grant_type":"purchase"},
          {"amount_granted":"50","amount_remaining":"10","expiry_date":"2027-02-01T00:00:00Z","grant_type":"purchase"}]}
        """
        let grants = try XCTUnwrap(CodexProvider.creditGrants(Data(body.utf8), now: now))
        XCTAssertEqual(grants.map(\.granted), [50])
        XCTAssertNil(CodexProvider.creditGrants(Data(#"{"balance":"0"}"#.utf8), now: now))
    }

    // MARK: Claude limit resets

    /// `/api/oauth/usage?cedar_ember=1`, asked as Claude Code 2.1.280.
    private let resets = """
    {"cedar_ember":{"eligible":true,"ineligible_reason":null,"at_limit":false,"exhausted":[],
     "grants":[{"id":"opus55-launch-promax-20260921",
                "label":"Claude Opus 5.5 launch: one usage-limit reset for Pro and Max",
                "resets_total":1,"resets_left":1,
                "starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00",
                "clears":["five_hour","seven_day","seven_day_overage_included"],
                "paused":false,"usable_now":true,"use_requires_limit":false,
                "percent_used":{"five_hour":1,"seven_day":6},"blocking":[],"arm":null}],
     "next_grant_id":"opus55-launch-promax-20260921","weekly_resets_at":"2026-10-04T21:00:00+00:00",
     "cooldown_until":null}}
    """

    func testClaudeResetGrantsBecomeResetCredits() throws {
        let credits = try XCTUnwrap(ClaudeProvider.resetCredits(Data(resets.utf8), now: now)?.credits)
        XCTAssertEqual(credits.available, 1)
        XCTAssertEqual(credits.totalEarned, 1)
        XCTAssertEqual(credits.applicable, 0, "not at a limit, so none apply to one right now")
        XCTAssertEqual(credits.credits.count, 1)
        XCTAssertEqual(credits.credits[0].id, "opus55-launch-promax-20260921")
        XCTAssertEqual(credits.credits[0].title, "Full reset")
        XCTAssertEqual(credits.credits[0].expiresAt, ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))
        XCTAssertTrue(credits.isShown)
    }

    func testAtALimitTheUsableResetsApply() throws {
        let atLimit = resets.replacingOccurrences(of: "\"at_limit\":false", with: "\"at_limit\":true")
        XCTAssertEqual(ClaudeProvider.resetCredits(Data(atLimit.utf8), now: now)?.credits?.applicable, 1)
    }

    func testSpentPausedAndExpiredGrantsAreNotAvailable() throws {
        let spent = resets.replacingOccurrences(of: "\"resets_left\":1", with: "\"resets_left\":0")
        let read = try XCTUnwrap(ClaudeProvider.resetCredits(Data(spent.utf8), now: now)?.credits)
        XCTAssertEqual(read.available, 0)
        XCTAssertEqual(read.totalEarned, 1, "given once, spent")
        XCTAssertTrue(read.isShown)

        let paused = resets.replacingOccurrences(of: "\"paused\":false", with: "\"paused\":true")
        XCTAssertEqual(ClaudeProvider.resetCredits(Data(paused.utf8), now: now)?.credits?.available, 0)

        let later = ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z")!
        XCTAssertEqual(ClaudeProvider.resetCredits(Data(resets.utf8), now: later)?.credits?.available, 0)

        let early = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z")!
        XCTAssertNil(ClaudeProvider.resetCredits(Data(resets.utf8), now: early)?.credits, "not started yet")
    }

    /// Asked by anything but a current Claude Code, the block lists nothing.
    func testAnIneligibleAnswerHasNoResets() throws {
        let other = """
        {"cedar_ember":{"eligible":false,"ineligible_reason":"surface","at_limit":false,"exhausted":[],
         "grants":[],"next_grant_id":null,"weekly_resets_at":null,"cooldown_until":null,"event_props":null}}
        """
        let read = try XCTUnwrap(ClaudeProvider.resetCredits(Data(other.utf8), now: now))
        XCTAssertNil(read.credits)
        XCTAssertNil(ClaudeProvider.resetCredits(Data("{\"five_hour\":null}".utf8), now: now))
    }

    func testWhatAGrantClears() {
        XCTAssertEqual(ClaudeProvider.resetTitle(["five_hour"]), "Session reset")
        XCTAssertEqual(ClaudeProvider.resetTitle(["seven_day_overage_included"]), "Weekly reset")
        XCTAssertNil(ClaudeProvider.resetTitle([]))
    }

    func testTheResetCountIsReadAgainWhenLimitsRefill() {
        let cache = ClaudeProvider.ResetGrantCache()
        let credits = ResetCredits(available: 1, totalEarned: 1)
        cache.store(credits, token: "t", used: 40, now: now)
        XCTAssertEqual(cache.reusable(token: "t", used: 42, now: now.addingTimeInterval(60)), .some(credits))
        // Nil outside: read again. (`.some(nil)` would be a reading of none.)
        XCTAssertTrue(cache.reusable(token: "t", used: 6, now: now.addingTimeInterval(60)) == nil, "a reset was just used")
        XCTAssertTrue(cache.reusable(token: "t", used: 42, now: now.addingTimeInterval(901)) == nil)
        XCTAssertTrue(cache.reusable(token: "other", used: 42, now: now) == nil)
        XCTAssertEqual(cache.last(token: "t"), credits)
    }

    // MARK: Claude credits given

    /// `/api/oauth/usage` for a Max account given a $250 credit.
    private let usage = """
    {"five_hour":{"utilization":0.0,"resets_at":"2026-10-01T16:10:00+00:00","limit_dollars":null,
                  "used_dollars":null,"remaining_dollars":null,"locked_reason":null},
     "seven_day":{"utilization":6.0,"resets_at":"2026-10-04T21:00:00+00:00","limit_dollars":null,
                  "used_dollars":null,"remaining_dollars":null,"locked_reason":null},
     "seven_day_opus":null,"cinder_cove":null,"cedar_ember":null,
     "iguana_necktie":{"utilization":10.0,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":250,
                       "used_dollars":25.0,"remaining_dollars":225.0,"locked_reason":null},
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
     "limits":[{"kind":"weekly_all","group":"weekly","percent":6,"severity":"normal",
                "resets_at":"2026-10-04T21:00:00+00:00","scope":null,"is_active":true}],
     "spend":{"balance":null,"enabled":false}}
    """

    func testAGivenDollarCreditIsAnAllowanceBesideThePlan() throws {
        let snapshot = try ClaudeProvider.parse(Data(usage.utf8))
        let credit = try XCTUnwrap(snapshot.windows.first { $0.title == "Cloud session credit" })
        XCTAssertEqual(credit.usedPercent, 10)
        XCTAssertEqual(credit.credit?.amount, "$225.00")
        XCTAssertEqual(credit.credit?.expiresAt, ISO8601DateFormatter().date(from: "2026-11-05T07:59:00Z"))
        XCTAssertFalse(snapshot.upFrontWindows(for: .claude).contains { $0.id == credit.id })
        XCTAssertTrue(try XCTUnwrap(credit.detail).hasPrefix("$25.00 / $250.00"))
        XCTAssertNil(credit.resetsAt, "it runs out rather than resets")
        XCTAssertTrue(credit.extra)
        XCTAssertEqual(snapshot.headlinePercent, 6, "the plan's own limit, not the credit")
    }

    func testTheOneTimeClaudeCodeCreditIsShown() throws {
        let body = """
        {"limits":[{"kind":"session","percent":3,"resets_at":"2026-10-01T16:10:00+00:00"}],
         "cinder_cove":{"utilization":40.0,"resets_at":"2026-12-01T00:00:00+00:00"}}
        """
        let windows = ClaudeProvider.creditWindows(Data(body.utf8), now: now)
        XCTAssertEqual(windows.map(\.title), ["Claude Code and Cowork credit"])
        XCTAssertEqual(windows.first?.credit?.amount, L10n.t("60% left", "剩余 60%"))
        XCTAssertEqual(windows.first?.usedPercent, 40)
    }

    func testAnUnknownDollarCreditIsABonusCredit() {
        let body = """
        {"amber_gauge":{"utilization":0,"limit_dollars":20,"used_dollars":0,"resets_at":"2026-12-01T00:00:00+00:00"}}
        """
        XCTAssertEqual(ClaudeProvider.creditWindows(Data(body.utf8), now: now).map(\.title), [L10n.t("Bonus credit", "赠送额度")])
    }

    func testACreditSurvivesTheCache() throws {
        var window = UsageWindow(title: "Cloud session credit", usedPercent: 10)
        window.credit = CreditAmount(amount: "$225.00", caption: "Used", expiresAt: now)
        let data = try JSONEncoder().encode(window)
        XCTAssertEqual(try JSONDecoder().decode(UsageWindow.self, from: data).credit, window.credit)
    }

    func testPlanWindowsAndSpentCreditsAreNotCredits() {
        let body = """
        {"five_hour":{"utilization":1,"limit_dollars":50,"used_dollars":1},
         "seven_day_sonnet":{"utilization":1,"limit_dollars":50},
         "old_promo":{"utilization":0,"limit_dollars":100,"resets_at":"2026-09-01T00:00:00+00:00"},
         "nothing":{"utilization":0,"limit_dollars":null}}
        """
        XCTAssertEqual(ClaudeProvider.creditWindows(Data(body.utf8), now: now).count, 0)
    }
}
