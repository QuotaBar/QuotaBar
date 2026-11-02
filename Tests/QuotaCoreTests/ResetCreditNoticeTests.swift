import XCTest
@testable import QuotaCore

final class ResetCreditNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ available: Int?) -> UsageSnapshot {
        UsageSnapshot(windows: [], resetCredits: available.map { ResetCredits(available: $0) })
    }

    func testAResetGivenSinceTheReadingBefore() {
        let notices = ResetCreditCheck.notices(
            provider: .codex, previous: reading(1), current: ResetCredits(available: 3), notified: [], now: now)
        XCTAssertEqual(notices.map(\.kind), [.given(2)])
        XCTAssertEqual(notices.first?.available, 3)
    }

    /// Before the count was kept at zero a reading carried none at all.
    func testAReadingWithoutACountHadNoneToSpend() {
        let notices = ResetCreditCheck.notices(
            provider: .codex, previous: reading(nil), current: ResetCredits(available: 1), notified: [], now: now)
        XCTAssertEqual(notices.map(\.kind), [.given(1)])
    }

    func testTheFirstReadingEverSetsTheBaseline() {
        XCTAssertTrue(ResetCreditCheck.notices(
            provider: .codex, previous: nil, current: ResetCredits(available: 3), notified: [], now: now).isEmpty)
    }

    func testSpendingOneSaysNothing() {
        XCTAssertTrue(ResetCreditCheck.notices(
            provider: .codex, previous: reading(3), current: ResetCredits(available: 2), notified: [], now: now).isEmpty)
    }

    /// Within a day of running out, once per credit; a credit further off,
    /// or one that never expires, waits.
    func testAReminderComesADayBeforeAndOnce() {
        let credits = ResetCredits(available: 3, credits: [
            ResetCredit(id: "soon", title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(20 * 3600)),
            ResetCredit(id: "later", expiresAt: now.addingTimeInterval(3 * 86_400)),
            ResetCredit(id: "never"),
        ])
        let first = ResetCreditCheck.notices(provider: .codex, previous: reading(3), current: credits, notified: [], now: now)
        XCTAssertEqual(first.map(\.key), ["codex|expiring|soon"])
        guard case let .expiring(credit)? = first.first?.kind else { return XCTFail("\(first)") }
        XCTAssertEqual(credit.title, "Full reset (Weekly + 5 hr)")

        let again = ResetCreditCheck.notices(
            provider: .codex, previous: reading(3), current: credits, notified: first.map(\.key), now: now.addingTimeInterval(3600))
        XCTAssertTrue(again.isEmpty)
    }

    func testTheSwitchSurvivesCoding() throws {
        var prefs = ExperiencePrefs()
        XCTAssertTrue(prefs.resetCreditNotify, "on unless turned off")
        XCTAssertFalse(prefs.resetCreditLastCall, "the last-hour reminder is asked for")
        prefs.resetCreditNotify = false
        prefs.resetCreditLastCall = true
        prefs.resetCreditNotified = ["codex|expiring|soon"]
        let back = try JSONDecoder().decode(ExperiencePrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertFalse(back.resetCreditNotify)
        XCTAssertTrue(back.resetCreditLastCall)
        XCTAssertEqual(back.resetCreditNotified, ["codex|expiring|soon"])
    }

    // MARK: Credit balances

    private func creditRow(_ name: String = "Credits", amount: String = "12,300 credits", expiresIn: TimeInterval?) -> UsageWindow {
        var window = UsageWindow(title: name)
        window.credit = CreditAmount(amount: amount, expiresAt: expiresIn.map { now.addingTimeInterval($0) })
        return window
    }

    /// A balance running out within the day speaks once, with no early
    /// resets beside it; one further off, or with no deadline, waits.
    func testACreditBalanceIsRemindedADayBeforeAndOnce() {
        let rows = [
            creditRow("Cloud session credit", amount: "$225.00", expiresIn: 23 * 3600),
            creditRow(expiresIn: 3 * 86_400),
            creditRow("Bought", expiresIn: nil),
        ]
        let first = ResetCreditCheck.notices(
            provider: .claude, previous: nil, current: nil, credits: rows, account: "you@example.com", notified: [], now: now)
        XCTAssertEqual(first.count, 1)
        guard case let .creditExpiring(name, credit)? = first.first?.kind else { return XCTFail("\(first)") }
        XCTAssertEqual(name, "Cloud session credit")
        XCTAssertEqual(credit.amount, "$225.00")
        XCTAssertTrue(first[0].key.hasPrefix("claude|credit|"))
        XCTAssertFalse(first[0].key.contains("example.com"), "the address stays out of the settings file")

        let again = ResetCreditCheck.notices(
            provider: .claude, previous: nil, current: nil, credits: rows, account: "you@example.com",
            notified: first.map(\.key), now: now.addingTimeInterval(3600))
        XCTAssertTrue(again.isEmpty)
    }

    /// Promotions end at one instant for everyone: two accounts' credits
    /// with the same deadline are two reminders.
    func testCreditKeysTellAccountsApart() {
        let row = [creditRow(expiresIn: 20 * 3600)]
        let one = ResetCreditCheck.notices(provider: .codex, previous: nil, current: nil, credits: row, account: "a@example.com", notified: [], now: now)
        let two = ResetCreditCheck.notices(provider: .codex, previous: nil, current: nil, credits: row, account: "b@example.com", notified: [], now: now)
        XCTAssertNotEqual(one.first?.key, two.first?.key)
        XCTAssertEqual(one.first?.key, ResetCreditCheck.notices(
            provider: .codex, previous: nil, current: nil, credits: row, account: "A@example.com", notified: [], now: now).first?.key)
    }

    func testUrgencyByTimeLeft() {
        XCTAssertEqual(CreditUrgency(expiresAt: now.addingTimeInterval(25 * 3600), now: now), .none)
        XCTAssertEqual(CreditUrgency(expiresAt: now.addingTimeInterval(24 * 3600), now: now), .day)
        XCTAssertEqual(CreditUrgency(expiresAt: now.addingTimeInterval(3600), now: now), .lastHour)
        XCTAssertEqual(CreditUrgency(expiresAt: now.addingTimeInterval(-60), now: now), .none, "passed")
        XCTAssertEqual(CreditUrgency(expiresAt: nil, now: now), .none, "never expires")
    }

    func testDeadlinesListResetsAndCreditsSoonestFirst() {
        var snapshot = UsageSnapshot(
            windows: [creditRow(expiresIn: 5 * 3600), UsageWindow(title: "Weekly", usedPercent: 40)],
            resetCredits: ResetCredits(available: 2, credits: [
                ResetCredit(id: "later", expiresAt: now.addingTimeInterval(9 * 86_400)),
                ResetCredit(id: "passed", expiresAt: now.addingTimeInterval(-60)),
                ResetCredit(id: "never"),
            ]))
        XCTAssertEqual(snapshot.givenDeadlines(now: now).map(\.name), ["Credits", L10n.t("Full reset", "完整重置")])
        snapshot.resetCredits?.credits.append(ResetCredit(id: "soon", title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(3600)))
        XCTAssertEqual(snapshot.givenDeadlines(now: now).first?.name, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(snapshot.givenDeadlines(now: now).first?.urgency(now: now), .lastHour)
    }

    /// An hour before each deadline within the day, while that hour is still
    /// ahead; keyed by provider and account so a reading takes back only its own.
    func testLastCallsComeAnHourBefore() {
        let snapshot = UsageSnapshot(
            account: "you@example.com",
            windows: [creditRow(expiresIn: 20 * 3600), creditRow("Other", expiresIn: 30 * 60)],
            resetCredits: ResetCredits(available: 2, credits: [
                ResetCredit(id: "soon", expiresAt: now.addingTimeInterval(6 * 3600)),
                ResetCredit(id: "later", expiresAt: now.addingTimeInterval(3 * 86_400)),
            ]))
        let calls = ResetCreditCheck.lastCalls(provider: .codex, snapshot: snapshot, now: now)
        XCTAssertEqual(calls.map(\.fireAt), [now.addingTimeInterval(5 * 3600), now.addingTimeInterval(19 * 3600)])
        let prefix = ResetCreditCheck.lastCallPrefix(provider: .codex, account: "you@example.com")
        XCTAssertTrue(calls.allSatisfy { $0.key.hasPrefix(prefix) })
        XCTAssertEqual(calls.first?.key, prefix + "soon")
        XCTAssertNotEqual(prefix, ResetCreditCheck.lastCallPrefix(provider: .codex, account: "other@example.com"))
    }

    func testTheBadgeSaysWholeHoursThenMinutes() {
        XCTAssertEqual(QuotaFormat.shortExpiry(now.addingTimeInterval(21 * 3600 + 1800), now: now), L10n.t("expires in 21h", "21 小时后到期"))
        XCTAssertEqual(QuotaFormat.shortExpiry(now.addingTimeInterval(47 * 60 + 20), now: now), L10n.t("expires in 47m", "47 分钟后到期"))
        XCTAssertEqual(QuotaFormat.shortExpiry(now.addingTimeInterval(20), now: now), L10n.t("expires in 1m", "1 分钟后到期"))
    }
}
