/// The spacing rule of every focusable element (docs/ENGINEERING_RULES.md, "Focus never touches the neighbour"): a focused
/// element's growth and ring never touch or overlap the next element. Between two focusable siblings, on the axis they
/// are neighbours on, there is at least twice the reach of a focused one (the one leaving and the one arriving both
/// show it while the focus moves) and ``clearance`` of clear space. Stage pixels.
enum FocusSpacing {
    /// The clear space that stays between the two reaches.
    static let clearance = 8.0

    /// How far a focused element reaches beyond its layout edge on one side: its growth on that side ([size] is its
    /// extent on the axis; an element that grows from the opposite edge, [oneSided], grows on this side by all of it),
    /// then the band between it and its ring ([outset]) and the ring ([ring] wide). A ring drawn inside the element's
    /// scale ([ringScales], ``View/focusLook(_:scale:ring:glowBlur:glowY:corner:anchor:sweep:glowSpread:gap:)``) grows
    /// with it.
    static func reach(size: Double, scale: Double, outset: Double, ring: Double, ringScales: Bool, oneSided: Bool = false) -> Double {
        let growth = size * (scale - 1) * (oneSided ? 1 : 0.5)
        return growth + (outset + ring) * (ringScales ? scale : 1)
    }

    /// The least gap between two siblings that each reach [reach] when focused.
    static func gap(reach: Double) -> Double { 2 * reach + clearance }

    /// The least gap between two ``View/focusLook(_:scale:ring:glowBlur:glowY:corner:anchor:sweep:glowSpread:gap:)``
    /// siblings [size] long on the axis, with their [scale], [ring] and band [outset] (the default band is the ring's width).
    static func focusLookGap(size: Double, scale: Double, ring: Double, outset: Double? = nil) -> Double {
        gap(reach: reach(size: size, scale: scale, outset: outset ?? ring, ring: ring, ringScales: true))
    }

    /// ``PillButton``s side by side ([pillGap]) or one above the other ([pillLineGap]): 76 px pills up to ``pillMaxWidth``
    /// wide in any language that grow by 8 % with a 4 px ring 4 px out, inside their scale.
    static let pillScale = 1.08, pillRing = 4.0, pillHeight = 76.0, pillMaxWidth = 400.0
    static let pillGap = 58.0, pillLineGap = 32.0
}

/// The gaps between the overview's focusable siblings (``FocusSpacing``), stage pixels. The overview's ring
/// (``View/overviewRingTarget(focused:corner:pad:scale:)``) is 4 px wide around the grown element and does not grow
/// itself; Play and App settings carry their own ring, 4 px wide 2–6 px out, and Play's sweep band 4 px wide 7–11 px out,
/// both inside the pill's scale.
enum OverviewSpacing {
    /// The overview ring's width.
    static let ring = 4.0

    /// Noninteractive tags and age badges share their group's spacing across and between wrapped rows.
    static let tagGap = 10.0, badgeGap = 28.0

    /// Screenshots and videos: 520 px thumbnails that grow by 6 %.
    static let mediaWidth = 520.0, mediaScale = 1.06, mediaGap = 48.0
    /// Similar games: 260 px covers that grow by 6 %.
    static let similarScale = 1.06, similarGap = 32.0
    /// Links: 64 px pills, up to ``linkMaxWidth`` wide in any language, that grow by 5 %.
    static let linkHeight = 64.0, linkMaxWidth = 480.0, linkScale = 1.05, linkGap = 40.0
    /// Play and App settings: 86 px pills that grow by 6 % with their ring's outer edge ``buttonRingOut`` out; Play, up
    /// to ``playMaxWidth`` wide, also has its sweep band reaching ``playReachOut`` out; App settings is up to
    /// ``settingsMaxWidth`` wide.
    static let buttonScale = 1.06, buttonRingOut = 6.0, playMaxWidth = 300.0, playReachOut = 11.0, settingsMaxWidth = 440.0
    static let buttonGap = 50.0
    /// The summary's ring stands 14 px out (it does not grow); Read the story, a 52 px pill growing by 6 %, keeps this
    /// far below it.
    static let summaryPad = 14.0, storyHeight = 52.0, storyScale = 1.06, storyGap = 44.0
}
