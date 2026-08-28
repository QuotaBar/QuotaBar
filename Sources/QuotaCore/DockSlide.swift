import CoreGraphics

/// What to do with a requested dock-panel frame.
///
/// Split out of `EdgeDockCoordinator` because getting it wrong is invisible in
/// a log and obvious on screen: the animation still runs to completion, it just
/// gets cut off partway and restarted. Two separate sources drive the panel's
/// frame — the hover transition, and the strip's measured height — and the
/// second used to land an un-animated `setFrame` one layout pass into the
/// first.
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
    ///
    /// There is deliberately no "mid-slide" case. A slide is never re-aimed:
    /// the caller holds content-driven resizes until it finishes, because
    /// re-aiming four milliseconds in is a second animation, not a correction,
    /// and the panel changes course where the user can see it.
    public static func decide(
        target: CGRect,
        pending: CGRect?,
        animated: Bool
    ) -> Decision {
        if target == pending { return .skip }
        return animated ? .animate(target) : .snap(target)
    }
}
