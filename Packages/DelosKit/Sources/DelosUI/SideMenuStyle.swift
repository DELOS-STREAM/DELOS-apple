import SwiftUI

/// How the side menu is presented, decided in one place. Android has the full-height panel on the left edge (``edge``);
/// on iPad and Apple TV the Apple app floats a rounded glass box with the same inset from the left, top and bottom
/// (``box``): an Apple-only presentation decision (owner, 2026-11-17), the content, width and motion are the same.
/// iPhone and Mac keep the edge panel.
struct SideMenuStyle: Equatable, Sendable {
    enum Device: Sendable { case phone, pad, tv, mac }
    enum Kind: Sendable { case edge, box }

    let kind: Kind

    /// The panel's width in stage pixels (the safe area on its left comes on top for the edge panel).
    static let width = 680.0
    /// The floating box's gap to the left, top and bottom edges (plus the safe area), and its corner radius, in stage pixels.
    static let inset = 32.0, radius = 40.0

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
    /// clear of it, ``contentInsets(_:)``); the box keeps ``inset`` away from the safe area on three sides.
    func frame(_ stage: Stage) -> CGRect {
        switch kind {
        case .edge:
            CGRect(x: 0, y: 0, width: Self.width + stage.safe.leading, height: stage.height)
        case .box:
            CGRect(x: stage.safe.leading + Self.inset, y: stage.safe.top + Self.inset, width: Self.width,
                   height: stage.height - stage.safe.top - stage.safe.bottom - 2 * Self.inset)
        }
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
