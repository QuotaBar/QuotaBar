import XCTest
@testable import QuotaCore

/// Shapes recorded from CodexBar's fixtures for the cloud endpoints; the
/// live services have not been exercised from here (Antigravity's token on
/// this Mac had expired, Qwen Cloud has no account), so these pin the
/// parsers, not the wire.
final class AntigravityParsingTests: XCTestCase {
    func testAvailableModelsBecomeScopedWindows() throws {
        let data = Data("""
        {"models":{
          "gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-09-13T00:00:00Z"}},
          "claude-sonnet-4-5":{"label":"Claude Sonnet 4.5","quotaInfo":{"remainingFraction":0.1,"resetTime":"2026-09-13T00:00:00Z"}},
          "gemini-2.5-flash":{"displayName":"Gemini 2.5 Flash"}}}
        """.utf8)
        let snapshot = try AntigravityProvider.parse(models: data, plan: "Google AI Pro")
        XCTAssertEqual(snapshot.windows.map(\.title), ["Gemini 3 Pro", "Claude Sonnet 4.5"])
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 40, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 90, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].scope, "Claude Sonnet 4.5")
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
        XCTAssertEqual(snapshot.headlinePercent!, 90, accuracy: 0.001)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    /// Trimmed from Antigravity 2.28.0's `fetchAvailableModels`, 2026-10-29:
    /// tab-completion and tier plumbing with no name, four ids answering as
    /// one model, and each family resetting together.
    static let recordedModels = """
    {"models":{
      "chat_20706":{"quotaInfo":{"remainingFraction":1},"isInternal":true,"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "chat_23310":{"quotaInfo":{"remainingFraction":1},"isInternal":true,"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "tab_flash_lite_preview":{"quotaInfo":{"remainingFraction":1},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "tab_jump_flash_lite_preview":{"quotaInfo":{"remainingFraction":1},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-3.8-flash-tiered":{"quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "claude-opus-4-6-thinking":{"displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:29:12Z"},"modelProvider":"MODEL_PROVIDER_ANTHROPIC"},
      "claude-sonnet-4-6":{"displayName":"Claude Sonnet 4.6 (Thinking)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:29:12Z"},"modelProvider":"MODEL_PROVIDER_ANTHROPIC"},
      "gpt-oss-120b-medium":{"displayName":"GPT-OSS 120B (Medium)","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:29:12Z"},"modelProvider":"MODEL_PROVIDER_OPENAI"},
      "gemini-2.5-pro":{"displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":GEMINI_PRO,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-3.1-flash-image":{"displayName":"Gemini 3.1 Flash Image","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-3.1-flash-lite":{"displayName":"Gemini 3.1 Flash Lite","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-2.5-flash-thinking":{"displayName":"Gemini 3.5 Flash Lite","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-2.5-flash":{"displayName":"Gemini 3.5 Flash Lite","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-2.5-flash-lite":{"displayName":"Gemini 3.5 Flash Lite","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"},
      "gemini-3.5-flash-lite":{"displayName":"Gemini 3.5 Flash Lite","quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-29T22:20:17Z"},"modelProvider":"MODEL_PROVIDER_GOOGLE"}},
     "tabModelIds":["chat_20706","chat_23310"]}
    """

    func testPlumbingAndAliasesAreLeftOutAndFamiliesShareAWindow() throws {
        let data = Data(Self.recordedModels.replacingOccurrences(of: "GEMINI_PRO", with: "1").utf8)
        let snapshot = try AntigravityProvider.parse(models: data, plan: "Antigravity")
        XCTAssertEqual(snapshot.windows.map(\.title), ["Gemini", "Claude and GPT"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 0])
        XCTAssertEqual(
            snapshot.windows[0].note,
            "Gemini 2.5 Pro, Gemini 3 Flash, Gemini 3.1 Flash Image, Gemini 3.1 Flash Lite, Gemini 3.5 Flash Lite")
        XCTAssertEqual(snapshot.windows[1].note, "Claude Opus 4.6 (Thinking), Claude Sonnet 4.6 (Thinking), GPT-OSS 120B (Medium)")
        XCTAssertEqual(snapshot.windows[0].resetsAt, Dates.parseISO("2026-10-29T22:20:17Z"))
        // Nothing used: the first window is the figure, and it is Gemini's.
        XCTAssertEqual(snapshot.headlineWindow?.title, "Gemini")
    }

    /// A client that names no version gets the Claude and GPT group alone;
    /// Gemini then comes from the model list, still first.
    func testASummaryWithoutGeminiTakesGeminiFromTheModelList() throws {
        let summary = """
        {"groups":[{"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.6,"resetTime":"2026-11-05T17:36:48Z"},
          {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2026-10-29T22:36:48Z"}]}]}
        """
        let models = Self.recordedModels.replacingOccurrences(of: "GEMINI_PRO", with: "1")
        let snapshot = try AntigravityProvider.parse(summary: Data(summary.utf8), models: Data(models.utf8), plan: "Google AI Pro")
        XCTAssertEqual(snapshot.windows.map(\.scope), ["Gemini", "Claude and GPT", "Claude and GPT"])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [nil, 18_000, 604_800])
        XCTAssertEqual(snapshot.windows[2].usedPercent!, 40, accuracy: 0.001)
        XCTAssertEqual(snapshot.headlineWindow?.scope, "Claude and GPT")
    }

    func testAFullSummaryNeedsNoModelList() throws {
        let summary = """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":1}]},
          {"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","remainingFraction":1}]}]}
        """
        let snapshot = try AntigravityProvider.parse(summary: Data(summary.utf8), models: Data(#"{"models":{}}"#.utf8))
        XCTAssertEqual(snapshot.windows.map(\.scope), ["Gemini", "Claude and GPT"])
    }

    func testTheUserAgentNamesTheInstalledVersion() {
        XCTAssertEqual(AntigravityProvider.userAgent(version: nil), "antigravity")
        XCTAssertEqual(AntigravityProvider.userAgent(version: ""), "antigravity")
        XCTAssertTrue(AntigravityProvider.userAgent(version: "2.28.0").hasPrefix("antigravity/2.28.0 darwin/"))
    }

    func testThePlanIsTheSubscriptionNotTheCodeAssistTier() throws {
        let both = #"{"currentTier":{"id":"free-tier","name":"Antigravity"},"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"},"cloudaicompanionProject":"aicode-consumers"}"#
        let assist = try JSONDecoder().decode(AntigravityProvider.CodeAssist.self, from: Data(both.utf8))
        XCTAssertEqual(assist.planName, "Google AI Pro")
        XCTAssertEqual(assist.projectID, "aicode-consumers")
        let free = #"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AntigravityProvider.CodeAssist.self, from: Data(free.utf8)).planName, "Antigravity")
    }

    func testAFamilyWhoseModelsPartWaysShowsEachModel() throws {
        let data = Data(Self.recordedModels.replacingOccurrences(of: "GEMINI_PRO", with: "0.25").utf8)
        let snapshot = try AntigravityProvider.parse(models: data)
        XCTAssertEqual(snapshot.windows.map(\.title), [
            "Gemini 2.5 Pro", "Gemini 3 Flash", "Gemini 3.1 Flash Image", "Gemini 3.1 Flash Lite", "Gemini 3.5 Flash Lite",
            "Claude and GPT",
        ])
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.headlineWindow?.title, "Gemini 2.5 Pro")
    }

    func testBucketsKeepTheEmptiestPerModel() throws {
        let data = Data("""
        {"buckets":[
          {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2026-09-13T00:00:00Z"},
          {"modelId":"gemini-2.5-flash","remainingFraction":0.4,"resetTime":"2026-09-13T00:00:00Z"},
          {"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"2026-09-13T00:00:00Z"}]}
        """.utf8)
        let snapshot = try AntigravityProvider.parse(buckets: data)
        XCTAssertEqual(snapshot.windows.map(\.title), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 60, accuracy: 0.001)
    }

    func testNoQuotasIsABadResponse() {
        XCTAssertThrowsError(try AntigravityProvider.parse(models: Data(#"{"models":{}}"#.utf8)))
        XCTAssertThrowsError(try AntigravityProvider.parse(buckets: Data("nope".utf8)))
    }

    func testTokenFileShape() {
        let root: [String: Any] = [
            "token": ["access_token": "ya29.x", "expiry": "2026-09-11T01:49:43.809006+05:00", "token_type": "Bearer"],
            "auth_method": "consumer",
        ]
        let token = LocalCredentials.antigravityToken(in: root)
        XCTAssertEqual(token?.accessToken, "ya29.x")
        XCTAssertNotNil(token?.expiry)
        XCTAssertTrue(token!.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(token!.isExpired(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertNil(LocalCredentials.antigravityToken(in: ["token": ["expiry": "x"]]))
    }

    func testPythonISOFormatIsParsed() {
        XCTAssertNotNil(LocalCredentials.parseFlexibleISO("2026-09-11T01:49:43.809006+05:00"))
        XCTAssertNotNil(LocalCredentials.parseFlexibleISO("2026-09-11T01:49:43Z"))
        XCTAssertNil(LocalCredentials.parseFlexibleISO(""))
    }
}

final class QwenParsingTests: XCTestCase {
    /// Personal and Solo Token Plans have one monthly window and nothing else
    /// (the shape CodexBar recorded for them, issue 2349 there).
    func testAMonthlyOnlyTokenPlanIsRead() throws {
        let data = Data(#"{"data":{"DataV2":{"data":{"data":{"per1MonthPercentage":0.25,"per1MonthResetTime":1791043200000}}}}}"#.utf8)
        let snapshot = try QwenProvider.parse(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 2_592_000)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_043_200), "milliseconds")
    }

    func testTheMonthlyWindowJoinsTheRollingOnes() throws {
        let data = Data(#"{"per5HourPercentage":0.1,"per1WeekPercentage":0.2,"per1MonthPercentage":0.3}"#.utf8)
        let snapshot = try QwenProvider.parse(data)
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800, 2_592_000])
        XCTAssertEqual(snapshot.windows.map { $0.usedPercent.map { ($0 * 10).rounded() / 10 } }, [10, 20, 30])
    }

    func testEmbeddedJSONUsageBecomesTwoWindows() throws {
        let inner = #"{"code":0,"data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000},"success":true}"#
        let payload: [String: Any] = ["data": ["DataV2": ["data": inner]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let subscription = Data(#"{"data":{"specCode":"standard","status":"VALID"}}"#.utf8)
        let snapshot = try QwenProvider.parse(data, subscription: subscription)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 18_000)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].windowSeconds, 604_800)
        XCTAssertEqual(snapshot.planName, "Standard")
    }

    func testFlatShapeAndPointsAreAccepted() throws {
        let data = Data(#"{"data":{"per5HourPercentage":42,"per1WeekPercentage":0.5}}"#.utf8)
        let snapshot = try QwenProvider.parse(data)
        XCTAssertEqual(snapshot.windows[0].usedPercent!, 42, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].usedPercent!, 50, accuracy: 0.001)
        XCTAssertNil(snapshot.planName)
    }

    func testLoginPageIsUnauthorized() {
        XCTAssertThrowsError(try QwenProvider.parse(Data(#"{"code":"NeedLogin","redirect":"https://login"}"#.utf8))) { error in
            guard case ProviderError.unauthorized = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try QwenProvider.parse(Data(#"{"data":{}}"#.utf8)))
    }

    func testSecTokenIsFoundInThePage() {
        XCTAssertEqual(QwenProvider.secToken(inHTML: #"window.ALIYUN_CONSOLE_CONFIG = {"sec_token":"abc.def"}"#), "abc.def")
        XCTAssertEqual(QwenProvider.secToken(inHTML: "sec_token = 'xyz'"), "xyz")
        XCTAssertNil(QwenProvider.secToken(inHTML: "<html>login</html>"))
    }

    func testCookieHelpers() {
        XCTAssertEqual(QwenProvider.normalizeCookie("Cookie: a=1; cna=zz"), "a=1; cna=zz")
        XCTAssertEqual(QwenProvider.cookieValue("cna", in: "a=1; cna=zz; b=2"), "zz")
        XCTAssertNil(QwenProvider.cookieValue("x", in: "a=1"))
        XCTAssertNil(QwenProvider.normalizeCookie("   "))
    }
}
