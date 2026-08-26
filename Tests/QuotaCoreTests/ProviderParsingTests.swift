import XCTest
@testable import QuotaCore

/// Fixtures are real responses recorded from the providers, with account
/// identifiers replaced. They exist to pin the parsers to the shapes the
/// services actually return rather than to the shapes we assumed.
final class CodexParsingTests: XCTestCase {
    /// A Pro account: one 7-day primary window, no secondary, plus a separate
    /// per-model limit and a credits block.
    private let proResponse = """
    {
      "user_id": "user-TEST",
      "account_id": "00000000-0000-0000-0000-000000000000",
      "email": "dev@example.com",
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 35,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 524721,
          "reset_at": 1788285767
        },
        "secondary_window": null
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "primary_window": {
              "used_percent": 4,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": 1787779046
            },
            "secondary_window": {
              "used_percent": 9,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 604800,
              "reset_at": 1788365846
            }
          }
        }
      ],
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "0"
      },
      "spend_control": {"reached": false, "individual_limit": null}
    }
    """

    func testPrimaryWindowIsLabelledFromItsActualLength() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))

        // Regression: this window used to be hardcoded as "5-hour window"
        // even though the account reports a 604800s (weekly) window.
        let primary = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(primary.title, WindowTitle.forSeconds(604_800))
        XCTAssertEqual(primary.usedPercent, 35)
        XCTAssertTrue(primary.isActive)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_788_285_767))
    }

    func testAdditionalRateLimitsAreSurfaced() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        let titles = snapshot.windows.map(\.title)

        XCTAssertTrue(titles.contains { $0.hasPrefix("GPT-5.3-Codex-Spark") },
                      "per-model limits should not be dropped, got \(titles)")
        let spark = snapshot.windows.filter { $0.title.hasPrefix("GPT-5.3-Codex-Spark") }
        XCTAssertEqual(spark.count, 2, "both the 5-hour and weekly Spark windows")
        XCTAssertEqual(spark.map(\.usedPercent), [4, 9])
    }

    func testAccountPrefersEmailOverUUID() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.planName, "Pro")
    }

    func testZeroBalanceWithoutCreditsIsHidden() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertFalse(snapshot.windows.contains { $0.title == L10n.t("Credits", "额度点数") })
    }

    func testCreditBalanceIsShownWhenPresent() throws {
        let response = """
        {"plan_type":"plus","rate_limit":null,
         "credits":{"has_credits":true,"unlimited":false,"balance":"$12.40"}}
        """
        let snapshot = try CodexProvider.parse(Data(response.utf8))
        let credits = try XCTUnwrap(snapshot.windows.first { $0.title == L10n.t("Credits", "额度点数") })
        XCTAssertEqual(credits.detail, "$12.40")
    }

    func testHeadlineIsTheHighestWindow() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        XCTAssertEqual(snapshot.headlinePercent, 35)
    }

    func testWindowIDsStayUniqueAcrossRepeatedTitles() throws {
        let snapshot = try CodexProvider.parse(Data(proResponse.utf8))
        let ids = snapshot.windows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids break ForEach rendering")
    }

    func testGarbageResponseIsRejected() {
        XCTAssertThrowsError(try CodexProvider.parse(Data("not json".utf8)))
    }
}

final class ClaudeParsingTests: XCTestCase {
    /// Real shape: `limits` carries per-model weekly caps that the legacy
    /// `five_hour` / `seven_day` fields do not express.
    private let response = """
    {
      "five_hour": {"utilization": 13.0, "resets_at": "2026-08-26T18:09:59.565722+00:00",
                    "limit_dollars": null, "used_dollars": null},
      "seven_day": {"utilization": 12.0, "resets_at": "2026-08-30T20:59:59.565738+00:00",
                    "limit_dollars": null, "used_dollars": null},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null,
                      "utilization": null, "spend_limit_reached": false},
      "limits": [
        {"kind": "session", "group": "session", "percent": 13, "severity": "normal",
         "resets_at": "2026-08-26T18:09:59.565722+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 12, "severity": "normal",
         "resets_at": "2026-08-30T20:59:59.565738+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 10, "severity": "normal",
         "resets_at": "2026-08-30T20:59:59.565928+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ]
    }
    """

    func testAllThreeLimitsAreParsed() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))

        // Regression: only five_hour and seven_day used to be read, silently
        // dropping the per-model weekly cap.
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [13, 12, 10])
    }

    func testScopedWeeklyWindowNamesItsModel() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        let scoped = try XCTUnwrap(snapshot.windows.last)
        XCTAssertTrue(scoped.title.contains("Fable"), "got \(scoped.title)")
    }

    func testActiveWindowIsMarked() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertEqual(snapshot.windows.filter(\.isActive).count, 1)
        XCTAssertTrue(snapshot.windows[0].isActive)
    }

    func testResetTimestampsAreParsed() throws {
        let snapshot = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Dates.parseISO("2026-08-26T18:09:59.565722+00:00"))
    }

    func testFallsBackToLegacyFieldsWhenLimitsIsAbsent() throws {
        let legacy = """
        {"five_hour": {"utilization": 42.0, "resets_at": "2026-08-26T18:09:59Z",
                       "limit_dollars": 20.0, "used_dollars": 8.4},
         "seven_day": {"utilization": 7.0, "resets_at": "2026-08-30T20:59:59Z"}}
        """
        let snapshot = try ClaudeProvider.parse(Data(legacy.utf8))

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 42)
        XCTAssertEqual(snapshot.windows[0].detail, "$8.40 / $20.00")
    }

    func testExtraUsageAppearsOnlyWhenEnabled() throws {
        let disabled = try ClaudeProvider.parse(Data(response.utf8))
        XCTAssertFalse(disabled.windows.contains { $0.title == L10n.t("Extra usage", "额外用量") })

        let enabled = """
        {"limits": [{"kind":"session","percent":5,"resets_at":null,"is_active":true}],
         "extra_usage": {"is_enabled": true, "monthly_limit": 50.0, "used_credits": 12.5,
                         "utilization": 25.0, "spend_limit_reached": false}}
        """
        let snapshot = try ClaudeProvider.parse(Data(enabled.utf8))
        let extra = try XCTUnwrap(snapshot.windows.first { $0.title == L10n.t("Extra usage", "额外用量") })
        XCTAssertEqual(extra.usedPercent, 25)
        XCTAssertEqual(extra.detail, "$12.50 / $50.00")
    }

    func testEmptyResponseIsRejected() {
        XCTAssertThrowsError(try ClaudeProvider.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .badResponse)
        }
    }
}

extension ProviderError: @retroactive Equatable {
    public static func == (lhs: ProviderError, rhs: ProviderError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
