import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// `agy -p /usage --output-format json`, in the shape agy 1.1.11 and later
/// print it.
final class AntigravityCLITests: XCTestCase {
    private func report(status: String = "SUCCESS", command: String = "usage", disabled: Bool = false) -> String {
        """
        {"conversation_id":"","status":"\(status)","num_turns":0,
         "command":{"name":"\(command)","data":{"description":"Models share limits","groups":[
           {"name":"Gemini Models","buckets":[
             {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.86,"reset_time":"2026-10-07T18:40:27Z"},
             {"id":"gemini-5h","window":"5h","remaining_fraction":0.95,"reset_time":"2026-10-01T15:48:04Z","disabled":\(disabled)}]},
           {"name":"Claude and GPT models","buckets":[
             {"id":"3p-weekly","window":"weekly","remaining_fraction":0.89,"reset_time":"2026-10-07T02:38:46Z"},
             {"id":"3p-5h","window":"5h","remaining_fraction":1.0,"reset_time":"2026-10-01T17:29:19Z"}]}]}}}
        """
    }

    func testTheReportReadsLikeTheAppsSummary() throws {
        let snapshot = try AntigravityCLI.parseReport(Data(report().utf8))
        XCTAssertEqual(snapshot.windows.map(\.scope), ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"])
        XCTAssertEqual(snapshot.windows.map(\.windowSeconds), [18_000, 604_800, 18_000, 604_800], "5-hour before weekly")
        XCTAssertEqual(snapshot.windows[1].usedPercent ?? 0, 14, accuracy: 0.001)
        XCTAssertEqual(snapshot.sourceLabel, "Antigravity CLI")
    }

    func testADisabledLimitIsLeftOut() throws {
        let snapshot = try AntigravityCLI.parseReport(Data(report(disabled: true).utf8))
        XCTAssertEqual(snapshot.windows.count, 3)
    }

    func testAnythingButASuccessfulUsageReportIsRefused() {
        XCTAssertThrowsError(try AntigravityCLI.parseReport(Data(report(status: "ERROR").utf8)))
        XCTAssertThrowsError(try AntigravityCLI.parseReport(Data(report(command: "models").utf8)))
        XCTAssertThrowsError(try AntigravityCLI.parseReport(Data("Signed out. Run agy to sign in.".utf8)))
    }
}
