import XCTest
@testable import QuotaModel

final class ProviderPhaseTests: XCTestCase {
    private var snapshot: UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(title: "Grok Bot", usedPercent: 31.9)])
    }

    func testMovedAllowanceReplacesLoadedAndStaleReadingsWithoutAnError() {
        for previous in [ProviderPhase.loaded(snapshot), .stale(snapshot, error: "earlier failure"), .loading] {
            let phase = ProviderPhase.failure(
                ProviderError.usageOnOtherProvider(provider: .cursor, hint: "View Cursor"), previous: previous)
            guard case let .redirected(provider, message) = phase else { return XCTFail("Expected a redirect") }
            XCTAssertEqual(provider, .cursor)
            XCTAssertEqual(message, "View Cursor")
            XCTAssertNil(phase.snapshot)
            XCTAssertNil(phase.errorMessage)
        }
    }

    func testNetworkAndLoginFailuresStillKeepTheLastQuota() {
        for error in [ProviderError.network("offline"), .unauthorized, .sessionExpired("renew sign-in"),
                      .rateLimited, .badResponse, .http(503), .unavailable("renewing"),
                      .needsAuthorization(hint: "allow access")] {
            let phase = ProviderPhase.failure(error, previous: .loaded(snapshot))
            guard case .stale = phase else { return XCTFail("Expected a stale reading") }
            XCTAssertEqual(phase.snapshot?.windows.first?.usedPercent, 31.9)
            XCTAssertNotNil(phase.errorMessage)
            XCTAssertFalse(phase.discardsCachedReading)
        }
    }

    func testFailureAfterRedirectDoesNotResurrectOldQuota() {
        let previous = ProviderPhase.redirected(provider: .cursor, message: "View Cursor")
        let phase = ProviderPhase.failure(ProviderError.unauthorized, previous: previous)
        guard case .failed = phase else { return XCTFail("Expected a failure without old numbers") }
        XCTAssertNil(phase.snapshot)
        XCTAssertNotNil(phase.errorMessage)
    }

    func testConfirmedMissingAccountOrPlanDiscardsOldQuotaWithoutUpdateFailure() {
        for error in [ProviderError.notConfigured(hint: "sign in"), .noPlan("No plan"), .signedOut("Signed out")] {
            for previous in [ProviderPhase.loaded(snapshot), .stale(snapshot, error: "old failure")] {
                let phase = ProviderPhase.failure(error, previous: previous)
                guard case let .notice(message) = phase else { return XCTFail("Expected a setup/plan notice") }
                XCTAssertEqual(message, error.localizedDescription)
                XCTAssertNil(phase.snapshot)
                XCTAssertNil(phase.errorMessage)
                XCTAssertTrue(phase.discardsCachedReading)
                XCTAssertEqual(phase.explanation, error.localizedDescription)
            }
        }
    }

    func testRequestAfterCredentialChangeCannotUsePreviousAccountNumbers() {
        let phase = ProviderPhase.failure(ProviderError.unauthorized, previous: nil)
        XCTAssertNil(phase.snapshot)
        XCTAssertNotNil(phase.errorMessage)
    }
}
