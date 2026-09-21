import XCTest
@testable import QuotaCore

final class CardWindowsTests: XCTestCase {
    private func window(_ title: String, _ seconds: Int?, scope: String? = nil, used: Double? = 10) -> UsageWindow {
        UsageWindow(title: scope.map { "\(title) · \($0)" } ?? title, usedPercent: used, windowSeconds: seconds, scope: scope)
    }

    private func ids(_ windows: [UsageWindow]) -> [String] { windows.map(\.title) }

    /// Pro has no 5-hour limit: the week alone; Spark's limits are folded.
    func testCodexProShowsTheWeekOnly() {
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [
            window("Week", 604_800),
            window("5h", 18_000, scope: "GPT-5.3-Codex-Spark"),
            window("Week", 604_800, scope: "GPT-5.3-Codex-Spark"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex)), ["Week"])
    }

    /// With the plan's week spent, the reserve being drawn on joins it up
    /// front; while the plan has room, the reserve stays folded.
    func testCodexShowsTheReserveWhileItIsInUse() {
        var reserve = window("Week", 604_800, scope: "gpt-reserve")
        reserve.label = "备用 · Luna"
        let idle = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("Week", 604_800), reserve])
        XCTAssertEqual(ids(idle.upFrontWindows(for: .codex)), ["Week"])
        reserve.inUse = true
        let drawing = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("Week", 604_800, used: 100), reserve])
        XCTAssertEqual(ids(drawing.upFrontWindows(for: .codex)), ["Week", "Week · gpt-reserve"])
        // Also over a list chosen from the card's menu before the reserve mattered.
        XCTAssertEqual(ids(drawing.upFrontWindows(for: .codex, shown: ["Week"])), ["Week", "Week · gpt-reserve"])
        XCTAssertEqual(ids(idle.upFrontWindows(for: .codex, shown: ["Week"])), ["Week"])
    }

    /// The owner's Codex on 2026-09-21: "Week" chosen from the card's menu
    /// on Pro, where it was the only plan limit; then the account went to
    /// Plus, and the 5-hour limit it gained stayed folded — off the card, and
    /// out of the copied image.
    func testALimitTheChoiceNeverSawIsNotFoldedByIt() {
        var reserve = window("Week", 604_800, scope: "gpt-reserve")
        reserve.label = "备用 · Luna"
        let plus = UsageSnapshot(planName: "Plus", account: nil, windows: [window("5h", 18_000), window("Week", 604_800), reserve])
        // Saved before the card kept what it had seen.
        XCTAssertEqual(ids(plus.upFrontWindows(for: .codex, shown: ["Week"])), ["5h", "Week"])
        // Chosen among the week and the reserve: the 5-hour is new to it.
        XCTAssertEqual(ids(plus.upFrontWindows(for: .codex, shown: ["Week"], known: ["Week", "Week · gpt-reserve"])), ["5h", "Week"])
        // Chosen with the 5-hour in sight: folded on purpose, and stays so.
        XCTAssertEqual(ids(plus.upFrontWindows(for: .codex, shown: ["Week"], known: ["5h", "Week", "Week · gpt-reserve"])), ["Week"])
        // A scoped window folded before `known` was kept stays folded.
        let claude = UsageSnapshot(planName: "Max", account: nil, windows: [window("5h", 18_000), window("Week", 604_800), window("Week", 604_800, scope: "Fable")])
        XCTAssertEqual(ids(claude.upFrontWindows(for: .claude, shown: ["5h", "Week"])), ["5h", "Week"])
        // And other providers' lists are left as they were chosen.
        let cursor = UsageSnapshot(planName: nil, account: nil, windows: [window("Month", 2_592_000), window("Models", 2_592_000)])
        XCTAssertEqual(ids(cursor.upFrontWindows(for: .cursor, shown: ["Month"])), ["Month"])
    }

    func testCodexPlusShowsTheFiveHourAndTheWeek() {
        let snapshot = UsageSnapshot(planName: "Plus", account: nil, windows: [
            window("5h", 18_000),
            window("Week", 604_800),
            window("5h", 18_000, scope: "GPT-5.3-Codex-Spark"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex)), ["5h", "Week"])
    }

    func testClaudeShowsTheFiveHourTheWeekAndFable() {
        let snapshot = UsageSnapshot(planName: "Max 20x", account: nil, windows: [
            window("5h", 18_000),
            window("Week", 604_800),
            window("Week", 604_800, scope: "Fable"),
        ])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .claude)), ["5h", "Week", "Week · Fable"])
    }

    /// The window the owner picked for the ring is marked on the card, so it
    /// is never folded away.
    func testThePickedWindowIsAlwaysUpFront() {
        let spark = window("Week", 604_800, scope: "GPT-5.3-Codex-Spark")
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("Week", 604_800), spark])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, picked: spark.id)), ["Week", "Week · GPT-5.3-Codex-Spark"])
    }

    /// Everyone else keeps two: Cursor's plan and its named-model limit.
    func testOtherProvidersKeepTheTwoMostUseful() {
        let snapshot = UsageSnapshot(planName: nil, account: nil, windows: [
            window("Monthly", nil, used: 93),
            window("Named models", nil, scope: "Named models", used: 99.8),
            window("Grok Bot", 604_800, scope: "Grok Bot", used: 15),
        ])
        XCTAssertEqual(snapshot.upFrontWindows(for: .cursor).count, 2)
    }

    /// Chosen from the card's menu: Spark's week up front, the plan's week folded.
    func testTheOwnersChoiceWins() {
        let week = window("Week", 604_800)
        let spark = window("Week", 604_800, scope: "GPT-5.3-Codex-Spark")
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [week, spark])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, shown: [spark.id])), ["Week · GPT-5.3-Codex-Spark"])
    }

    /// Window ids are titles: after a language switch the saved choice
    /// matches nothing, and the card falls back to its own choice.
    func testAChoiceThatMatchesNothingFallsBack() {
        let snapshot = UsageSnapshot(planName: "Pro 20x", account: nil, windows: [window("周窗口", 604_800)])
        XCTAssertEqual(ids(snapshot.upFrontWindows(for: .codex, shown: ["Week"])), ["周窗口"])
    }

    func testTheChoiceSurvivesCoding() throws {
        var prefs = ExperiencePrefs()
        prefs.cardWindows["codex"] = ["周窗口"]
        prefs.hiddenWindows["codex"] = ["周窗口 · GPT-5.3-Codex-Spark"]
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back.cardWindows["codex"], ["周窗口"])
        XCTAssertTrue(back.cardWindowsKnown.isEmpty)
        XCTAssertEqual(back.hiddenWindows["codex"], ["周窗口 · GPT-5.3-Codex-Spark"])
        let odd = try JSONDecoder().decode(ExperiencePrefs.self, from: Data(#"{"cardWindows":7}"#.utf8))
        XCTAssertTrue(odd.cardWindows.isEmpty)
        XCTAssertTrue(odd.hiddenWindows.isEmpty, "a config from before the menu had it")
    }

    /// Spark hidden (issue #2): gone from the reading, so from the card, its
    /// arrow and the ring's automatic pick alike.
    func testHiddenWindowsLeaveTheReading() {
        let week = window("Week", 604_800, used: 40)
        let spark5h = window("5h", 18_000, scope: "GPT-5.3-Codex-Spark", used: 90)
        let sparkWeek = window("Week", 604_800, scope: "GPT-5.3-Codex-Spark", used: 5)
        let snapshot = UsageSnapshot(planName: "Plus", account: nil, windows: [week, spark5h, sparkWeek])
        let shown = snapshot.hiding([spark5h.id, sparkWeek.id])
        XCTAssertEqual(ids(shown.windows), ["Week"])
        XCTAssertEqual(shown.headlineWindow?.id, week.id, "the fullest was Spark's 5-hour")
        XCTAssertEqual(ids(snapshot.hiding(nil).windows).count, 3)
    }

    func testHidingEveryWindowShowsTheReadingWhole() {
        let snapshot = UsageSnapshot(planName: nil, account: nil, windows: [window("Week", 604_800)])
        XCTAssertEqual(ids(snapshot.hiding(["Week"]).windows), ["Week"])
    }
}

final class WindowRenameTests: XCTestCase {
    private func window(_ title: String, _ seconds: Int?, scope: String? = nil) -> UsageWindow {
        UsageWindow(title: title, usedPercent: 10, windowSeconds: seconds, scope: scope)
    }

    func testClaudeInChinesePairsWithClaudeInEnglish() {
        let zh = [window("5 小时窗口", 18_000), window("周窗口", 604_800), window("周窗口 · Fable", 604_800, scope: "Fable")]
        let en = [window("5-hour window", 18_000), window("Weekly window", 604_800), window("Weekly window · Fable", 604_800, scope: "Fable")]
        XCTAssertEqual(WindowRename.pairs(from: zh, to: en), [
            "5 小时窗口": "5-hour window",
            "周窗口": "Weekly window",
            "周窗口 · Fable": "Weekly window · Fable",
        ])
    }

    /// Two model-scoped weeks either side, in the same order: paired in order.
    /// A window only one reading has is left alone.
    func testPairsInOrderAndSkipsWhatDoesNotMatch() {
        let zh = [window("月度套餐", nil), window("指定模型", nil, scope: "指定模型"), window("Grok Bot", 604_800, scope: "Grok Bot")]
        let en = [window("Monthly plan", nil), window("Named models", nil, scope: "Named models")]
        XCTAssertEqual(WindowRename.pairs(from: zh, to: en), ["月度套餐": "Monthly plan", "指定模型": "Named models"])
    }
}

final class WindowMenuNameTests: XCTestCase {
    /// One model's 5-hour and weekly limits share a scope, and so a display
    /// name; in a menu nothing else tells them apart.
    func testScopedWindowsCarryTheirLength() {
        let five = UsageWindow(title: "Spark · 5h", usedPercent: 1, windowSeconds: 18_000, scope: "Spark")
        let week = UsageWindow(title: "Spark · Week", usedPercent: 1, windowSeconds: 604_800, scope: "Spark")
        XCTAssertEqual(five.displayName, week.displayName)
        XCTAssertNotEqual(five.menuName, week.menuName)
        let plan = UsageWindow(title: "Week", usedPercent: 1, windowSeconds: 604_800)
        XCTAssertEqual(plan.menuName, "Week")
    }
}
