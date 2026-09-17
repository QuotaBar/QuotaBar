import XCTest
@testable import QuotaCore

/// The island footer's sync note and the refresh button's feedback: what a
/// click on refresh ends in, and what the note says the rest of the time.
final class SyncNoteTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Refresh outcome

    func testTheOutcomeCountsWhatIsStillFailing() {
        XCTAssertEqual(RefreshOutcome(failing: 0), .allUpToDate)
        XCTAssertEqual(RefreshOutcome(failing: 3), .notUpdating(3))
    }

    /// A refresh whose reads come straight back still spins for 0.8s; one
    /// that took longer stops when it is done.
    func testTheSpinnerStaysUpForTheMinimum() {
        XCTAssertEqual(RefreshOutcome.remainingSpin(elapsed: 0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(RefreshOutcome.remainingSpin(elapsed: 0.05), 0.75, accuracy: 0.0001)
        XCTAssertEqual(RefreshOutcome.remainingSpin(elapsed: 0.8), 0, accuracy: 0.0001)
        XCTAssertEqual(RefreshOutcome.remainingSpin(elapsed: 12), 0)
        XCTAssertEqual(RefreshOutcome.remainingSpin(elapsed: -1), 0.8, accuracy: 0.0001, "a clock that went back")
        XCTAssertGreaterThanOrEqual(RefreshOutcome.holdSeconds, 1.5)
    }

    // MARK: Which note

    func testARefreshUnderWaySaysSoFirst() {
        XCTAssertEqual(SyncNote.make(refreshing: true, outcome: .allUpToDate, failing: 3, latest: now), .refreshing)
    }

    func testTheOutcomeIsHeldOverTheFailingCount() {
        XCTAssertEqual(
            SyncNote.make(refreshing: false, outcome: .notUpdating(3), failing: 3, latest: now),
            .finished(.notUpdating(3)))
        XCTAssertEqual(
            SyncNote.make(refreshing: false, outcome: .allUpToDate, failing: 0, latest: now),
            .finished(.allUpToDate))
    }

    func testFailingProvidersComeBeforeTheSyncAge() {
        XCTAssertEqual(SyncNote.make(refreshing: false, outcome: nil, failing: 2, latest: now), .notUpdating(2))
        XCTAssertEqual(SyncNote.make(refreshing: false, outcome: nil, failing: 0, latest: now), .synced(now))
        XCTAssertEqual(SyncNote.make(refreshing: false, outcome: nil, failing: 0, latest: nil), .syncing)
    }

    // MARK: Words

    func testTheNoteInEnglish() {
        XCTAssertEqual(SyncNote.refreshing.text(now: now), "Refreshing…")
        XCTAssertEqual(SyncNote.finished(.allUpToDate).text(now: now), "All up to date")
        XCTAssertEqual(SyncNote.finished(.notUpdating(3)).text(now: now), "Refreshed · 3 not updating")
        XCTAssertEqual(SyncNote.notUpdating(3).text(now: now), "3 not updating")
        XCTAssertEqual(SyncNote.synced(now.addingTimeInterval(-180)).text(now: now), "Synced 3m ago")
        XCTAssertEqual(SyncNote.syncing.text(now: now), "Syncing…")
    }

    func testTheNoteInChinese() {
        L10n.override = .zhHans
        XCTAssertEqual(SyncNote.refreshing.text(now: now), "正在刷新…")
        XCTAssertEqual(SyncNote.finished(.allUpToDate).text(now: now), "已全部更新")
        XCTAssertEqual(SyncNote.finished(.notUpdating(3)).text(now: now), "已刷新 · 3 个未能更新")
        XCTAssertEqual(SyncNote.notUpdating(3).text(now: now), "3 个未能更新")
        XCTAssertEqual(SyncNote.synced(now.addingTimeInterval(-180)).text(now: now), "已同步 3 分钟前")
    }

    func testOnlyNotUpdatingIsAmber() {
        XCTAssertTrue(SyncNote.notUpdating(1).isWarning)
        XCTAssertTrue(SyncNote.finished(.notUpdating(1)).isWarning)
        XCTAssertFalse(SyncNote.finished(.allUpToDate).isWarning)
        XCTAssertFalse(SyncNote.refreshing.isWarning)
        XCTAssertFalse(SyncNote.synced(now).isWarning)
        XCTAssertFalse(SyncNote.syncing.isWarning)
    }

    // MARK: Stale readings

    /// A stale window whose reset has come and gone holds the figure of the
    /// window that ended; one still ahead, or with no reset, does not.
    func testAResetInThePastHasLapsed() {
        XCTAssertTrue(StaleReading.resetLapsed(now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(StaleReading.resetLapsed(now, now: now))
        XCTAssertFalse(StaleReading.resetLapsed(now.addingTimeInterval(60), now: now))
        XCTAssertFalse(StaleReading.resetLapsed(nil, now: now))
    }

    func testTheStaleWordsSayHowOldAndWhy() {
        let read = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(StaleReading.label, "Not updating")
        XCTAssertEqual(StaleReading.note(fetchedAt: read, now: now), "Showing numbers from 3h ago")
        XCTAssertEqual(
            StaleReading.help(reason: "Claude Code is signed out on this Mac.", fetchedAt: read, now: now),
            "Claude Code is signed out on this Mac.\nThe numbers shown are from 3h ago.")
        XCTAssertEqual(StaleReading.help(reason: "  ", fetchedAt: read, now: now), "The numbers shown are from 3h ago.")

        L10n.override = .zhHans
        XCTAssertEqual(StaleReading.label, "未能更新")
        XCTAssertEqual(StaleReading.note(fetchedAt: read, now: now), "显示的是 3 小时前的数据")
    }
}
