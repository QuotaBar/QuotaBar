import CoreGraphics

/// What to do with a requested dock-panel frame.
///
/// Split out of `EdgeDockCoordinator` because getting it wrong is invisible in
/// a log and obvious on screen: the animation still runs to completion, it just
/// gets cut off partway and restarted. Two separate sources drive the panel's
/// frame — the hover transition, and a `GeometryReader` reporting the strip's
/// measured height — and the second used to land an un-animated `setFrame` one
/// layout pass into the first.
public enum DockSlide {
    public enum Decision: Equatable, Sendable {
        /// Already heading there. Doing nothing is the whole point: re-applying
        /// the same frame mid-slide is what aborts the animation.
        case skip
        case snap(CGRect)
        case animate(CGRect)
    }

    /// - Parameters:
    ///   - target: the frame the panel should end up at.
    ///   - pending: the frame the panel is already heading to, if any. Not the
    ///     panel's current frame — mid-slide that reports an in-between value
    ///     and would never compare equal.
    ///   - animated: true for a hover transition, false for a content-driven
    ///     resize such as a provider being enabled.
    ///   - sliding: true while a hover transition is still running.
    public static func decide(
        target: CGRect,
        pending: CGRect?,
        animated: Bool,
        sliding: Bool
    ) -> Decision {
        if target == pending { return .skip }
        // A content-driven resize that arrives mid-slide joins the slide rather
        // than snapping: on the first reveal the strip has never been measured,
        // so its real height only turns up once the animation is under way.
        return animated || sliding ? .animate(target) : .snap(target)
    }
}
