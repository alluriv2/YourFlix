import Foundation
import SwiftUI

/// One photo's randomly-picked Ken Burns motion -- rolled once, the
/// instant that photo appears (see KenBurnsImageView's `@State private
/// var motion`), then held fixed for that photo's whole display so the
/// zoom/pan/easing stays consistent as `progress` ticks forward from 0
/// to 1 rather than re-randomizing every tick.
///
/// Picked independently across a few axes so photos don't all move the
/// same way:
/// - Zoom magnitude: no zoom at all, a normal ~18% push, or (rarer) a
///   bigger ~32% push.
/// - Zoom direction: in (grows across the display) or out (shrinks) --
///   irrelevant when magnitude is "none."
/// - Pan: a small random drift (up to ~24pt in x and y), either settling
///   TOWARD center by the end (the original behavior) or drifting AWAY
///   from center instead.
/// - Easing: which curve the zoom/pan follows over the display -- the
///   original symmetric smoothstep, or a slow-start/fast-finish or
///   fast-start/slow-finish curve instead.
/// - Hold: rarely, none of the above -- the photo just sits perfectly
///   still for its whole display, the way a real edited slideshow
///   doesn't move every single frame.
struct KenBurnsMotion {
    enum ZoomMagnitude {
        case none
        case normal
        case big

        var amount: Double {
            switch self {
            case .none: return 0
            case .normal: return 0.18
            case .big: return 0.32
            }
        }
    }

    enum PanConvergence {
        case towardCenter
        case awayFromCenter
    }

    enum Easing: CaseIterable {
        case smoothstep
        case slowStart
        case fastStart

        /// Maps raw progress `t` (0...1) to eased progress (0...1).
        func apply(to t: Double) -> Double {
            let c = min(1, max(0, t))
            switch self {
            case .smoothstep:
                // Symmetric ease-in-out -- the original curve.
                return c * c * (3 - 2 * c)
            case .slowStart:
                // Slow to get going, then finishes quickly.
                return c * c * c
            case .fastStart:
                // Moves quickly at first, then eases into a slow finish.
                return 1 - pow(1 - c, 3)
            }
        }
    }

    let isHold: Bool
    let zoomMagnitude: ZoomMagnitude
    let zoomIn: Bool
    let panConvergence: PanConvergence
    let dx: Double
    let dy: Double
    let easing: Easing

    /// Rolls a fresh, independently-randomized motion for one photo --
    /// see the type's own doc comment above for what each axis does.
    /// Odds: ~10% hold (no motion at all); of the rest, ~25% no zoom
    /// (pan only), ~60% a normal zoom, ~15% a bigger zoom -- direction,
    /// pan convergence, and easing are each an even random pick.
    static func random() -> KenBurnsMotion {
        let isHold = Double.random(in: 0..<1) < 0.10

        let magnitudeRoll = Double.random(in: 0..<1)
        let zoomMagnitude: ZoomMagnitude
        if magnitudeRoll < 0.25 {
            zoomMagnitude = .none
        } else if magnitudeRoll < 0.85 {
            zoomMagnitude = .normal
        } else {
            zoomMagnitude = .big
        }

        return KenBurnsMotion(
            isHold: isHold,
            zoomMagnitude: zoomMagnitude,
            zoomIn: Bool.random(),
            panConvergence: Bool.random() ? .towardCenter : .awayFromCenter,
            dx: Double.random(in: -24...24),
            dy: Double.random(in: -24...24),
            easing: Easing.allCases.randomElement() ?? .smoothstep
        )
    }

    /// The view's scaleEffect at eased progress `eased` (0...1).
    func scale(at eased: Double) -> Double {
        guard !isHold, zoomMagnitude.amount > 0 else { return 1.0 }
        let amount = zoomMagnitude.amount
        return zoomIn ? 1.0 + amount * eased : (1.0 + amount) - amount * eased
    }

    /// The view's offset at eased progress `eased` (0...1).
    func offset(at eased: Double) -> CGSize {
        guard !isHold else { return .zero }
        switch panConvergence {
        case .towardCenter:
            // Starts offset by (dx, dy), settles to center by the end --
            // the original behavior.
            return CGSize(width: dx * (1 - eased), height: dy * (1 - eased))
        case .awayFromCenter:
            // Starts centered, drifts out to (dx, dy) by the end.
            return CGSize(width: dx * eased, height: dy * eased)
        }
    }
}
