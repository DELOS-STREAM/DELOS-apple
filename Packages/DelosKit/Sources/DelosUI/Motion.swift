import Foundation
import SwiftUI

/// A CSS `cubic-bezier` timing curve (`CubicBezierEasing` of Compose): the time is solved for x, the progress is y.
struct CubicBezier: Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// The eased progress at the linear [fraction] (0…1).
    func callAsFunction(_ fraction: Double) -> Double {
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return 1 }
        // Bisection on x(t): monotonic for x1, x2 in 0…1, exact to well below a pixel in 24 steps
        var low = 0.0, high = 1.0, t = fraction
        for _ in 0..<24 {
            t = (low + high) / 2
            if Self.curve(t, x1, x2) < fraction { low = t } else { high = t }
        }
        return Self.curve(t, y1, y2)
    }

    private static func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
}

/// The motion language of DELOS for Android (`Motion` in `shell/ui/Motion.kt`), as far as the ported screens use it:
/// durations in milliseconds, the easings and the arithmetic of a staggered entrance.
enum Motion {
    /// The prototype's `--ease-out`: entrances.
    static let easeOut = CubicBezier(0.16, 1, 0.3, 1)
    /// The prototype's `--ease-spring`: a little overshoot (focus, pops).
    static let easeSpring = CubicBezier(0.34, 1.56, 0.64, 1)
    /// `--ease-in`: everything that leaves.
    static let easeIn = CubicBezier(0.5, 0, 0.75, 0)
    /// CSS `ease`: colors and opacities.
    static let ease = CubicBezier(0.25, 0.1, 0.25, 1)

    static let exit = 240.0
    /// A scrim fading in (`Motion.SCRIM`).
    static let scrim = 420.0
    /// Focus: the spring of a scale, a ring, a lifted element (`Motion.FOCUS`).
    static let focus = 420.0
    /// The focus ring's alpha arriving and leaving.
    /// The focus ring gliding to the next element (`Motion.RING`).
    static let ring = 560.0
    static let ringIn = 140.0
    static let ringOut = 110.0
    /// Regular and Fill glyphs of an icon cross-fade this long.
    static let iconFill = 350.0
    /// A choice value slides out of the way of the next one, and the chevron on that side nudges.
    static let valueSlide = 300.0
    static let chevronBump = 320.0
    static let valueSlideDistance = 22.0
    static let chevronBumpDistance = 7.0
    static let press = 120.0
    static let pressHold = 130.0
    static let fade = 280.0
    static let rowFocus = 520.0
    static let popIn = 560.0
    static let cardFadeIn = popIn * 0.6
    /// The rows of a page or a menu rise one after the other: the first after ``rowDelay``, then ``staggerRow`` apart.
    static let rowDelay = 120.0
    static let staggerRow = 46.0
    static let rowIn = 420.0
    /// A menu's rows start sooner than a page's.
    static let menuDelay = 60.0
    static let pillPop = 460.0
    static let staggerCap = 8

    /// How far an entering element rises (stage pixels).
    static let rise = 18.0
    static let pressScale = 0.97
    static let popFromScale = 0.86
    static let popFromPill = 0.6
    static let dialogFromScale = 0.96

    /// The eased progress of an animation of [duration] ms that starts [delay] ms after 0, at [time] ms.
    static func progress(_ time: Double, delay: Double, duration: Double, _ easing: CubicBezier) -> Double {
        easing(min(max((time - delay) / duration, 0), 1))
    }

    /// The prototype's `--ease-spring` over [ms] milliseconds, as a SwiftUI animation (overshoots a little).
    static func spring(_ ms: Double) -> Animation { .timingCurve(0.34, 1.56, 0.64, 1, duration: ms / 1000) }
    /// Compose's default `tween(ms)` easing, FastOutSlowIn (`CubicBezierEasing(.4, 0, .2, 1)`), over [ms] milliseconds.
    static func fastOutSlowIn(_ ms: Double) -> Animation { .timingCurve(0.4, 0, 0.2, 1, duration: ms / 1000) }
    /// The prototype's `--ease-out` over [ms] milliseconds.
    static func out(_ ms: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: ms / 1000) }

    static func lerp(_ from: Double, _ to: Double, _ fraction: Double) -> Double { from + (to - from) * fraction }
}
