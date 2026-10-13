import XCTest
@testable import QuotaCore
@testable import QuotaModel

final class XSubscriptionProviderTests: XCTestCase {
    private func data(_ value: String) -> Data { Data(value.utf8) }
    private let period = #"""
      {"availability":"available","weeklyIncludedUsage":{"usedCents":400,"budgetCents":2000,
        "periodStart":"2026-10-13T16:33:09.198Z","resetsAt":"2026-10-20T16:33:09.198Z"}}
      """#

    private func token(_ claims: [String: Any]) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).test-signature"
    }

    private var bridgeClaims: [String: Any] {
        ["iss": "cursor", "aud": "https://auth.x.ai", "principal_type": "User", "principal_id": "user-one",
         "xai_user_id": "user-one", "xai_team_id": "workspace-one", "cursor_user_id": "42", "exp": 3000]
    }

    private func credential(_ claims: [String: Any]) throws -> XSubscriptionClient.Bridge.Credential {
        let raw: [String: Any] = [
            "token": try token(claims), "edgeBaseUrl": "https://grok.com",
            "tokenSource": "XAI_COMMERCE_BEARER_TOKEN_SOURCE_PARTNER_JWT",
        ]
        return try JSONDecoder().decode(XSubscriptionClient.Bridge.Credential.self,
                                        from: JSONSerialization.data(withJSONObject: raw))
    }

    func testWeeklyDashboardUsesItsRealSharedCounterAndNeverTheMonthlyCounter() throws {
        let response = try JSONDecoder().decode(XSubscriptionClient.Usage.self, from: data(period))
        let window = XSubscriptionClient.weeklyWindow(response)
        XCTAssertEqual(window.usedPercent, 20)
        XCTAssertEqual(window.windowSeconds, 7 * 86_400)
        XCTAssertNotNil(window.resetsAt)
        let oldOnly = try JSONDecoder().decode(XSubscriptionClient.Usage.self, from: data(#"{"availability":"available","monthlyUsage":{"usedCents":0,"limitCents":10000}}"#))
        XCTAssertNil(XSubscriptionClient.weeklyWindow(oldOnly).usedPercent)
    }

    func testUnknownWeeklyCountsStayUnknownWhileReportedZeroIsZero() throws {
        for replacement in [#""usedCents":null"#, #""unused":0"#] {
            let raw = period.replacingOccurrences(of: #""usedCents":400"#, with: replacement)
            let response = try JSONDecoder().decode(XSubscriptionClient.Usage.self, from: data(raw))
            XCTAssertNil(XSubscriptionClient.weeklyWindow(response).usedPercent)
        }
        let zero = period.replacingOccurrences(of: #""usedCents":400"#, with: #""usedCents":0"#)
        let response = try JSONDecoder().decode(XSubscriptionClient.Usage.self, from: data(zero))
        XCTAssertEqual(XSubscriptionClient.weeklyWindow(response).usedPercent, 0)
    }

    func testPrepaidValuesAreDollarsAndOnlyVerifiedProtoZeroIsZero() throws {
        for (scalar, expected) in [(#""availableCents":"1250""#, 12.50), (#""availableCents":0"#, 0), ("", 0)] {
            let delimiter = scalar.isEmpty ? "" : ","
            let raw = "{\"billingMode\":\"PREPAID_BILLING_MODE_PREPAID\",\"eligible\":true\(delimiter)\(scalar)}"
            let response = try JSONDecoder().decode(XSubscriptionClient.Prepaid.self, from: data(raw))
            XCTAssertEqual(response.balance?.currency, "USD")
            XCTAssertEqual(response.balance?.total, expected)
        }
        for raw in [#"{}"#, #"{"eligible":true}"#, #"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":null}"#,
                    #"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":"invalid"}"#] {
            let response = try JSONDecoder().decode(XSubscriptionClient.Prepaid.self, from: data(raw))
            XCTAssertNil(response.balance)
        }
    }

    func testCompletedMigrationUsesNewUsageAndBalanceWithoutInventingIdentity() async throws {
        let replies: [String: String] = [
            XSubscriptionClient.unifiedMeURL.path: #"{"isMerged":true,"isUnificationComplete":true,"dashboard":{"email":"second@example.com","userId":42}}"#,
            XSubscriptionClient.planURL.path: #"{"isMerged":true,"planInfo":{"planName":"Premium"}}"#,
            XSubscriptionClient.usageURL.path: period,
            XSubscriptionClient.prepaidURL.path: #"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":"1250"}"#,
        ]
        let send: HTTPSend = { _, url, _, _, _ in
            HTTPResponse(status: 200, data: Data((replies[url.path] ?? "{}").utf8))
        }
        let probe = await XSubscriptionClient.read(cookie: "test", account: "old@example.com", send: send)
        let snapshot = try XCTUnwrap(probe.snapshot)
        XCTAssertTrue(probe.migrated)
        XCTAssertEqual(snapshot.xSubscription?.tier, "premium")
        XCTAssertEqual(snapshot.account, "second@example.com")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 20)
        XCTAssertEqual(snapshot.balance?.balances.first?.total, 12.50)
        XCTAssertNil(snapshot.xSubscription?.verifiedIdentity, "An email or old Cursor user id is not an xAI workspace/seat identity.")
    }

    func testCompletedMigrationWithUnavailableUsageDoesNotReturnTheLegacyZero() async throws {
        let send: HTTPSend = { _, url, _, _, _ in
            switch url.path {
            case XSubscriptionClient.unifiedMeURL.path:
                return HTTPResponse(status: 200, data: Data(#"{"isMerged":true,"isUnificationComplete":true}"#.utf8))
            case XSubscriptionClient.planURL.path:
                return HTTPResponse(status: 200, data: Data(#"{"isMerged":true,"planInfo":{"planName":"Ultra"}}"#.utf8))
            default: throw ProviderError.network("offline")
            }
        }
        let probe = await XSubscriptionClient.read(cookie: "test", account: nil, send: send)
        XCTAssertTrue(probe.migrated)
        XCTAssertEqual(probe.snapshot?.xSubscription?.tier, "ultra")
        XCTAssertNil(probe.snapshot?.windows.first?.usedPercent)
        XCTAssertNil(probe.snapshot?.balance)
    }

    func testIncompleteOrLegacyAccountDoesNotBecomeXSubscription() async {
        for body in [#"{}"#, #"{"isMerged":true,"isUnificationComplete":false}"#, #"{"isMerged":false,"isUnificationComplete":true}"#] {
            let send: HTTPSend = { _, url, _, _, _ in
                HTTPResponse(status: 200, data: Data((url.path == XSubscriptionClient.unifiedMeURL.path ? body : #"{"planInfo":{"planName":"Premium"}}"#).utf8))
            }
            let probe = await XSubscriptionClient.read(cookie: "test", account: nil, send: send)
            XCTAssertFalse(probe.migrated)
            XCTAssertNil(probe.snapshot)
        }
    }

    func testSubscriptionMetadataOutageIsNotAnAffirmativeLegacyPlan() async {
        let send: HTTPSend = { _, _, _, _, _ in throw ProviderError.network("offline") }
        let probe = await XSubscriptionClient.read(cookie: "test", account: nil, send: send)
        XCTAssertFalse(probe.migrated)
        XCTAssertTrue(probe.migrationUnavailable)
        XCTAssertNil(probe.snapshot)
    }

    func testEmptyAndMalformedMigrationRepliesCannotAuthorizeTheRetainedLegacySummary() async throws {
        for raw in [#"{}"#, #"{"unrelated":true}"#, "not-json"] {
            let send: HTTPSend = { _, _, _, _, _ in HTTPResponse(status: 200, data: Data(raw.utf8)) }
            for sand in [nil, try JSONDecoder().decode(GrokBot.Status.self, from: data(#"{}"#))] {
                let probe = await XSubscriptionClient.read(cookie: "test", account: nil, sand: sand, send: send)
                XCTAssertFalse(probe.migrated)
                XCTAssertTrue(probe.migrationUnavailable)
                XCTAssertNil(probe.snapshot)
            }
        }
        let knownOld = try JSONDecoder().decode(GrokBot.Status.self, from: data(#"{"isUnified":false}"#))
        let send: HTTPSend = { _, _, _, _, _ in HTTPResponse(status: 200, data: Data("{}".utf8)) }
        let old = await XSubscriptionClient.read(cookie: "test", account: nil, sand: knownOld, send: send)
        XCTAssertFalse(old.migrated)
        XCTAssertFalse(old.migrationUnavailable)
    }

    func testExplicitIncompleteMigrationDoesNotBecomeSharedFromAContradictoryBotFlag() async throws {
        let sand = try JSONDecoder().decode(GrokBot.Status.self, from: data(#"{"isUnified":true,"cursorPlanName":"Premium"}"#))
        let send: HTTPSend = { _, url, _, _, _ in
            HTTPResponse(status: 200, data: Data((url.path == XSubscriptionClient.unifiedMeURL.path
                ? #"{"isMerged":true,"isUnificationComplete":false}"# : "{}").utf8))
        }
        let probe = await XSubscriptionClient.read(cookie: "test", account: nil, sand: sand, send: send)
        XCTAssertFalse(probe.migrated)
        XCTAssertNil(probe.snapshot)
    }

    func testGrokPrepaidCentsIncludingSignedLedgerAndProtoZero() throws {
        let prefix = #"{"config":{"creditUsagePercent":20,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-13T00:00:00Z","end":"2026-10-20T00:00:00Z"}"#
        for (value, expected) in [(#"{"val":1250}"#, 12.50), (#"{"val":-500}"#, 5.0), (#"{}"#, 0), (#"{"val":"1250"}"#, 12.50)] {
            let snapshot = try GrokProvider.parse(data(prefix + ",\"prepaidBalance\":" + value + "}}"))
            XCTAssertEqual(snapshot.balance?.balances.first?.total, expected)
        }
        for value in [#"null"#, #"{"val":null}"#, #"{"val":"invalid"}"#] {
            let snapshot = try GrokProvider.parse(data(prefix + ",\"prepaidBalance\":" + value + "}}"))
            XCTAssertNil(snapshot.balance)
        }
        let legacy = try GrokProvider.parse(data(prefix + ",\"isUnifiedBillingUser\":true}}"))
        XCTAssertNil(legacy.xSubscription, "The older unified billing flag does not establish migration.")
    }

    func testGrokAuthIdentityComesFromSameSelectedAuthEntry() throws {
        let auth = LocalCredentials.grokAuth(in: ["issuer": [
            "key": "example-token", "email": "one@example.com", "user_id": "user-one", "team_id": "workspace-one",
            "expires_at": "2030-10-13T00:00:00Z",
        ]])
        XCTAssertEqual(auth?.userID, "user-one")
        XCTAssertEqual(auth?.workspaceID, "workspace-one")
        XCTAssertNil(LocalCredentials.grokAuth(in: ["access_token": "manual", "email": "one@example.com"])?.userID)
    }

    func testIssuedBridgeBindsTheActualCursorAccountToTheExactGrokWorkspaceAndSeat() throws {
        let issued = try credential(bridgeClaims)
        let bridge = XSubscriptionClient.identity(credential: issued, dashboardUserID: 42, now: Date(timeIntervalSince1970: 2000))
        let cliClaims: [String: Any] = [
            "iss": "https://auth.x.ai", "sub": "user-one", "principal_type": "User",
            "principal_id": "user-one", "team_id": "workspace-one",
        ]
        let cli = LocalCredentials.GrokAuth(accessToken: try token(cliClaims), email: "same@example.com",
                                            userID: "user-one", workspaceID: "workspace-one")
        XCTAssertEqual(bridge?.workspaceID, "team:workspace-one")
        XCTAssertEqual(bridge?.seatID, "user:user-one")
        XCTAssertEqual(XSubscriptionClient.grokIdentity(cli), bridge)
        XCTAssertNil(XSubscriptionClient.identity(credential: issued, dashboardUserID: 999, now: Date(timeIntervalSince1970: 2000)))
        let changedTeam = LocalCredentials.GrokAuth(accessToken: try token(cliClaims), email: "same@example.com",
                                                    userID: "user-one", workspaceID: "workspace-two")
        XCTAssertNil(XSubscriptionClient.grokIdentity(changedTeam), "The auth alias must be corroborated by its own token.")
    }

    func testExpiredIncompleteAndMalformedBridgesCannotMerge() throws {
        for change: [String: Any] in [
            ["exp": 1999], ["iss": "untrusted"], ["principal_type": "Team"],
            ["principal_id": "another-user"], ["xai_user_id": "another-user"],
            ["xai_team_id": NSNull()], ["cursor_user_id": "999"],
        ] {
            let claims = bridgeClaims.merging(change) { _, changed in changed }
            XCTAssertNil(XSubscriptionClient.identity(credential: try credential(claims), dashboardUserID: 42,
                                                       now: Date(timeIntervalSince1970: 2000)))
        }
        let malformed = try JSONDecoder().decode(XSubscriptionClient.Bridge.Credential.self, from: data(#"{"token":"not-a-jwt","edgeBaseUrl":"https://grok.com","tokenSource":"XAI_COMMERCE_BEARER_TOKEN_SOURCE_PARTNER_JWT"}"#))
        XCTAssertNil(XSubscriptionClient.identity(credential: malformed, dashboardUserID: 42))
        let personal = bridgeClaims.merging(["xai_team_id": ""]) { _, changed in changed }
        let personalIdentity = XSubscriptionClient.identity(credential: try credential(personal), dashboardUserID: 42,
                                                            now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(personalIdentity?.workspaceID, "personal:user-one")
        let teamIdentity = XSubscriptionClient.identity(credential: try credential(bridgeClaims), dashboardUserID: 42,
                                                        now: Date(timeIntervalSince1970: 2000))
        XCTAssertNotEqual(personalIdentity, teamIdentity, "A missing team cannot merge an unrelated team workspace.")
    }

    func testBotOnlyMigratedAccountKeepsSharedReadingButCannotReplaceAnotherUnavailableCredential() throws {
        let snapshot = UsageSnapshot(
            planName: "Premium", account: "bot@example.com",
            windows: [UsageWindow(title: "Shared weekly usage", usedPercent: 15)],
            balance: BalanceSheet(balances: [AccountBalance(currency: "USD", total: 12.50)]),
            xSubscription: XSubscriptionInfo(tier: "premium", workspaceID: "team:one", seatID: "user:one"))
        let botOnly = try GrokProvider.botOnly(.subscription(snapshot))
        XCTAssertEqual(botOnly.xSubscription, snapshot.xSubscription)
        XCTAssertEqual(botOnly.balance, snapshot.balance)
        XCTAssertEqual(botOnly.windows.count, 1)
        XCTAssertThrowsError(try GrokProvider.withoutCredits(.usageUnavailable("unavailable"), bot: .subscription(snapshot)),
                             "A different manual/CLI credential cannot silently display the Bot account's new subscription.")
    }

    func testActualDashboardTransportHeadersPermitTheWalletAndIdentityPostReads() async throws {
        var claims = bridgeClaims
        claims["exp"] = Date().addingTimeInterval(300).timeIntervalSince1970
        let bridgeToken = try token(claims)
        let bridgeBody = try JSONSerialization.data(withJSONObject: ["credential": [
            "token": bridgeToken, "edgeBaseUrl": "https://grok.com",
            "tokenSource": "XAI_COMMERCE_BEARER_TOKEN_SOURCE_PARTNER_JWT",
        ]])
        let replies: [String: Data] = [
            XSubscriptionClient.unifiedMeURL.path: data(#"{"isMerged":true,"isUnificationComplete":true,"dashboard":{"userId":42}}"#),
            XSubscriptionClient.planURL.path: data(#"{"isMerged":true,"planInfo":{"planName":"Premium"}}"#),
            XSubscriptionClient.usageURL.path: data(period),
            XSubscriptionClient.prepaidURL.path: data(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":"1250"}"#),
            XSubscriptionClient.identityURL.path: bridgeBody,
        ]
        let send: HTTPSend = { method, url, headers, body, _ in
            if method == "POST" && (headers["Origin"] != "https://cursor.com" || headers["Content-Type"] != "application/json") {
                return HTTPResponse(status: 403, data: Data("{}".utf8))
            }
            if url == XSubscriptionClient.identityURL {
                let posted = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }
                XCTAssertEqual(posted?["purpose"], 1)
            }
            return HTTPResponse(status: 200, data: replies[url.path] ?? Data("{}".utf8))
        }
        let read = await XSubscriptionClient.read(cookie: "test", account: nil, send: send)
        XCTAssertEqual(read.snapshot?.balance?.balances.first?.total, 12.50)
        XCTAssertEqual(read.snapshot?.xSubscription?.workspaceID, "team:workspace-one")
        XCTAssertEqual(read.snapshot?.xSubscription?.seatID, "user:user-one")
    }
}
