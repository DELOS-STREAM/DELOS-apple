import SwiftUI

/// How the side menu is presented, decided in one place: the full-height panel on the left edge (``edge``) or, on iPad
/// and Apple TV, a rounded glass box floating with the same gap to the left, top and bottom edges of the screen
/// (``box``): the content, width and touch drag are the same. iPhone and Mac keep the edge panel.
struct SideMenuStyle: Equatable, Sendable {
    enum Device: Sendable { case phone, pad, tv, mac }
    enum Kind: Sendable { case edge, box }

    let kind: Kind

    /// The panel's width in stage pixels (the safe area on its left comes on top for the edge panel).
    static let width = 680.0
    /// The floating box's gap to the left, top and bottom edges beyond the deepest of their safe areas, and its corner radius,
    /// in stage pixels.
    static let inset = 48.0, radius = 40.0

    /// The device this build runs on.
    static var device: Device {
        #if os(tvOS)
        .tv
        #elseif os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    /// The style for a [device] on [stage]: the box on tvOS and on an iPad whose stage is at least ``Stage/compactWidth`` wide, in either orientation (a narrow Split View
    /// or Slide Over window has no room for a floating box and gets the edge panel), the edge panel everywhere else.
    init(device: Device = Self.device, stage: Stage) {
        switch device {
        case .tv: kind = .box
        case .pad: kind = stage.width < Stage.compactWidth ? .edge : .box
        case .phone, .mac: kind = .edge
        }
    }

    /// The panel's frame in stage pixels in the stage's coordinates (the origin at the top left of the window).
    /// The edge panel is flush with the left, top and bottom edges and reaches under the safe area (its content keeps
    /// clear of it, ``contentInsets(_:)``); the box keeps ``gap(_:)`` away from the left, top and bottom edges of the
    /// screen, the same on all three as the eye measures it.
    func frame(_ stage: Stage) -> CGRect {
        switch kind {
        case .edge:
            CGRect(x: 0, y: 0, width: Self.width + stage.safe.leading, height: stage.height)
        case .box:
            CGRect(x: Self.gap(stage), y: Self.gap(stage), width: Self.width, height: stage.height - 2 * Self.gap(stage))
        }
    }

    /// The box's gap to the left, top and bottom edges of the screen: ``inset`` beyond the deepest safe area of the three, so
    /// a status bar, a home indicator or a TV's title-safe margin on one edge does not make that gap larger than the others.
    static func gap(_ stage: Stage) -> Double {
        inset + max(stage.safe.leading, stage.safe.top, stage.safe.bottom)
    }

    /// The gap in stage pixels between the panel's edge and its content: the edge panel's content keeps clear of the
    /// safe area, the box is inside it already.
    func contentInsets(_ stage: Stage) -> EdgeInsets {
        switch kind {
        case .edge: EdgeInsets(top: 48 + stage.safe.top, leading: 40 + stage.safe.leading, bottom: 48, trailing: 40)
        case .box: EdgeInsets(top: 40, leading: 40, bottom: 40, trailing: 40)
        }
    }

    /// The corner radius in stage pixels (0: square).
    var cornerRadius: Double { kind == .box ? Self.radius : 0 }
}
