import XCTest
@testable import QuotaModel

final class ProviderReadTrackerTests: XCTestCase {
    func testSlowerOlderRefreshCannotOverwriteNewerQuota() {
        var tracker = ProviderReadTracker()
        let old = tracker.begin(.cursor)
        let fresh = tracker.begin(.cursor)
        XCTAssertFalse(tracker.accepts(old, for: .cursor, isEnabled: true))
        XCTAssertTrue(tracker.accepts(fresh, for: .cursor, isEnabled: true))
    }

    func testDisableThenReenableDoesNotResurrectEarlierRead() {
        var tracker = ProviderReadTracker()
        let old = tracker.begin(.deepseek)
        XCTAssertFalse(tracker.accepts(old, for: .deepseek, isEnabled: false))
        tracker.invalidate(.deepseek)
        tracker.invalidate(.deepseek)
        let fresh = tracker.begin(.deepseek)
        XCTAssertFalse(tracker.accepts(old, for: .deepseek, isEnabled: true))
        XCTAssertTrue(tracker.accepts(fresh, for: .deepseek, isEnabled: true))
    }

    func testCredentialOrProfileChangeInvalidatesOnlyTheAffectedProvider() {
        var tracker = ProviderReadTracker()
        let before = tracker.begin(.claude)
        let other = tracker.begin(.codex)
        tracker.invalidate(.claude)
        XCTAssertFalse(tracker.accepts(before, for: .claude, isEnabled: true))
        XCTAssertTrue(tracker.accepts(other, for: .codex, isEnabled: true))
        let after = tracker.begin(.claude)
        XCTAssertTrue(tracker.accepts(after, for: .claude, isEnabled: true))
    }

    func testTheSameProtectionAppliesToEveryProvider() {
        for provider in ProviderID.allCases {
            var tracker = ProviderReadTracker()
            let old = tracker.begin(provider)
            tracker.invalidate(provider)
            XCTAssertFalse(tracker.accepts(old, for: provider, isEnabled: true))
        }
    }
}
