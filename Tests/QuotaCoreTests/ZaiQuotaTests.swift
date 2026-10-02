import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// `/api/monitor/usage/quota/limit` on z.ai and bigmodel.cn.
final class ZaiQuotaTests: XCTestCase {
    func testLimitsBecomeWindows() throws {
        let body = #"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12,"nextResetTime":1791043200000},{"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"remaining":80,"percentage":20}]},"success":true}"#
        let snapshot = try ZaiProvider.parseQuota(Data(body.utf8), host: "https://api.z.ai")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 20])
        XCTAssertEqual(snapshot.windows[0].windowSeconds, 5 * 3600, "(3, 5) is five hours, not five weeks")
        XCTAssertEqual(snapshot.windows[0].title, WindowTitle.forSeconds(18_000))
        XCTAssertEqual(snapshot.windows[1].title, L10n.t("MCP calls", "MCP 调用"))
        XCTAssertEqual(snapshot.windows[1].windowSeconds, 30 * 86_400, "TIME_LIMIT (5, 1) is the month's MCP calls")
    }

    func testTheOtherUnits() throws {
        let body = #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3},{"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":4}]}}"#
        let snapshot = try ZaiProvider.parseQuota(Data(body.utf8), host: "https://api.z.ai")
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [604_800, 86_400])
    }

    /// No limits at all: the account has nothing to read, which is said as
    /// that, with the endpoint's words when it has some.
    func testNoLimitsSaysThereIsNoPlan() {
        for body in [#"{"code":200,"data":{"limits":[]},"success":true}"#, #"{"code":500,"msg":"No coding plan","success":false}"#] {
            XCTAssertThrowsError(try ZaiProvider.parseQuota(Data(body.utf8), host: "https://open.bigmodel.cn")) { error in
                guard case let ProviderError.noPlan(message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains("bigmodel.cn"))
            }
        }
        XCTAssertThrowsError(try ZaiProvider.parseQuota(Data("<html>".utf8), host: "https://api.z.ai"))
    }
}
