import CoreGraphics
import XCTest
@testable import QuotaCore

/// The dock's reveal stuttered because two sources drive the panel's frame and
/// the second one interrupted the first. These pin the rule that fixed it.
final class DockSlideTests: XCTestCase {
    private let collapsed = CGRect(x: 2038, y: 586, width: 18, height: 92)
    private let expanded = CGRect(x: 1982, y: 400, width: 74, height: 332)

    /// The one that mattered: the strip's `GeometryReader` reports its height
    /// one layout pass into the reveal and re-lands the frame the slide is
    /// already animating toward. Re-applying it cuts the animation off partway.
    func testRepeatingThePendingFrameIsIgnored() {
        XCTAssertEqual(
            DockSlide.decide(
                target: expanded, pending: expanded, animated: false, sliding: true),
            .skip)
    }

    func testRepeatingThePendingFrameIsIgnoredWhenIdleToo() {
        XCTAssertEqual(
            DockSlide.decide(
                target: collapsed, pending: collapsed, animated: false, sliding: false),
            .skip)
    }

    func testHoverTransitionAnimates() {
        XCTAssertEqual(
            DockSlide.decide(
                target: expanded, pending: collapsed, animated: true, sliding: false),
            .animate(expanded))
    }

    /// The first reveal only learns the strip's real height once the animation
    /// is already running. Snapping there would be the same visible break as
    /// the bug, so a genuine change mid-slide joins the slide.
    func testAContentResizeArrivingMidSlideJoinsIt() {
        let taller = CGRect(x: 1982, y: 380, width: 74, height: 352)
        XCTAssertEqual(
            DockSlide.decide(
                target: taller, pending: expanded, animated: false, sliding: true),
            .animate(taller))
    }

    /// Enabling a provider while the dock sits open should resize it at once.
    /// A panel that eases into every content change reads as drift.
    func testAContentResizeWhileIdleSnaps() {
        let taller = CGRect(x: 1982, y: 380, width: 74, height: 352)
        XCTAssertEqual(
            DockSlide.decide(
                target: taller, pending: expanded, animated: false, sliding: false),
            .snap(taller))
    }

    func testNothingPendingYetStillResolves() {
        XCTAssertEqual(
            DockSlide.decide(
                target: collapsed, pending: nil, animated: false, sliding: false),
            .snap(collapsed))
    }
}
