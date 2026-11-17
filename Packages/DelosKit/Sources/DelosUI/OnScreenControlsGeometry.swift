import DelosData

// The geometry of the on-screen controls on any screen shape (`OscGeometry`, `OscDefaultLayout` and the pixel half of
// `OscPlacement` of DELOS for Android, docs/gui/SCREEN_SHAPES.md §9.1 and §9.2 there). Pure (pixels in, pixels out) and in
// Java's float and integer arithmetic, so a layout comes out on Apple to the pixel as on Android for the same panel.

/// The on-screen controls, by Android's element ids (`VirtualControllerElement.EID_*`): the ids of a stored layout.
enum OscElementID: Int, CaseIterable, Sendable {
    case dpad = 1, leftTrigger = 2, rightTrigger = 3, leftBumper = 4, rightBumper = 5
    case a = 6, b = 7, x = 8, y = 9, back = 10, start = 11
    case leftStick = 12, rightStick = 13, leftStickButton = 14, rightStickButton = 15, guide = 16
    case touchpad = 65
}

/// One element's rectangle in pixels of the panel.
struct OscSlot: Equatable, Sendable {
    var left: Int
    var top: Int
    var width: Int
    var height: Int

    var right: Int { left + width }
    var bottom: Int { top + height }

    func contains(x: Float, y: Float) -> Bool {
        Float(left) < x && Float(left + width) > x && Float(top) < y && Float(top + height) > y
    }
}

/// The default layout's measures on one panel (`OscGeometry.Panel`). The default controls are drawn on a grid of 128 x 72
/// units, a 16:9 screen: one unit is `height / 72` pixels. A panel at least as wide as 3:2 (108 units) takes that grid as it
/// is, the left controls against the left edge, the right ones against the right edge and the middle ones centred, so a
/// wider panel only leaves more room in the middle. A squarer panel (4:3, 5:4, 1:1, a portrait one) shrinks the whole layout
/// by `width / 108 units` until the clusters and the Back / Guide / Start row between them fit; the controls of the upper
/// half keep to the top edge, those of the lower half to the bottom edge.
struct OscPanel: Equatable, Sendable {
    static let gridWidth = 128
    static let gridHeight = 72
    /// Width in grid units that the left cluster (34), the right cluster (30) and the Back / Guide / Start row (40) need side
    /// by side; narrower than this the layout shrinks.
    static let fitWidthUnits = 108

    let width: Int
    let height: Int
    /// 1 from 3:2 up; below that, the factor the layout is shrunk by.
    let scale: Float
    /// One layout unit in pixels: a 72nd of the height, times ``scale``.
    let unit: Float
    private let rightDisplacement: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        // 2 * width >= 3 * height is "108 units wide or more", without a float comparison
        scale = 2 * Int64(width) >= 3 * Int64(height) ? 1 : 2 * Float(width) / (3 * Float(height))
        unit = (Float(height) / Float(Self.gridHeight)) * scale
        rightDisplacement = width - height * 16 / 9
    }

    /// [units] grid units in pixels.
    func size(_ units: Int) -> Int { Int(unit * Float(units)) }

    /// The x of an element whose left edge is [units] from the grid's left edge, kept to the panel's left edge.
    func left(_ units: Int) -> Int { size(units) }

    /// The x of an element [widthUnits] wide whose left edge is at [units] on the grid, kept to the panel's right edge: its
    /// distance to that edge is the grid's.
    func right(_ units: Int, _ widthUnits: Int) -> Int {
        if scale == 1 { return size(units) + rightDisplacement }
        return width - size(Self.gridWidth - units - widthUnits) - size(widthUnits)
    }

    /// The y of an element whose top edge is [units] from the grid's top, kept to the panel's top edge.
    func top(_ units: Int) -> Int { size(units) }

    /// The y of an element [heightUnits] high whose top edge is at [units] on the grid, kept to the panel's bottom edge.
    func bottom(_ units: Int, _ heightUnits: Int) -> Int {
        if scale == 1 { return size(units) }
        return height - size(Self.gridHeight - units - heightUnits) - size(heightUnits)
    }

    /// The y of a horizontal line [units] down the grid, kept to the panel's bottom edge.
    func bottomLine(_ units: Int) -> Int { scale == 1 ? size(units) : height - size(Self.gridHeight - units) }

    var centerX: Int { width / 2 }

    /// [slot] moved onto the panel, and shrunk when it is larger than the panel (`OscGeometry.clamp`).
    func clamp(_ slot: OscSlot) -> OscSlot {
        let w = max(1, min(slot.width, width))
        let h = max(1, min(slot.height, height))
        return OscSlot(left: max(0, min(slot.left, width - w)), top: max(0, min(slot.top, height - h)), width: w, height: h)
    }
}

/// Java's `Math.round(float)`: the nearest integer, halves up (towards positive infinity).
func javaRound(_ value: Float) -> Int { Int((value + 0.5).rounded(.down)) }

/// Where the default on-screen controls go on a panel (`OscDefaultLayout`): the numbers of the classic 128 x 72 grid,
/// placed by ``OscPanel``.
enum OscDefaultLayout {
    // Left and right clusters, triggers: the grid numbers of the classic layout
    static let triggerLeftX = 1
    static let triggerRightX = 92
    static let triggerDistance = 23
    static let triggerY = 31
    static let triggerWidth = 12
    static let triggerHeight = 9

    // Face buttons are defined from the Y button
    static let buttonX = 106
    static let buttonY = 1
    static let buttonSize = 10

    static let dpadX = 4
    static let dpadY = 41
    static let dpadSize = 30

    static let analogLeftX = 6
    static let analogLeftY = 4
    static let analogRightX = 98
    static let analogRightY = 42
    static let analogSize = 26

    static let l3r3Y = 60

    static let startBackY = 64
    static let startBackWidth = 12
    static let startBackHeight = 7

    // Delos: the gap between the middle buttons, and the trackpad above them
    static let middleGap = 2
    static let trackpadWidth = 20
    static let trackpadHeight = 10
    static let guideY = startBackY

    /// The slots of the default layout for the buttons the settings turn on, in the order the controls are added (a later
    /// one is drawn and touched on top of an earlier one): everything but Guide when [onlyL3R3] is off, only L3 and R3 when it
    /// is on, and Guide when [showGuide] is on.
    static func compute(_ p: OscPanel, onlyL3R3: Bool, showGuide: Bool) -> [(id: OscElementID, slot: OscSlot)] {
        var slots: [(id: OscElementID, slot: OscSlot)] = []
        // Back, Guide and Start in a row centred at the bottom (Guide in the middle, also when it is hidden, so Back and Start
        // stay symmetric), the trackpad centred above them
        let center = p.centerX
        let middleWidth = p.size(startBackWidth)
        let gap = p.size(middleGap)
        let guideX = center - middleWidth / 2
        let backX = guideX - gap - middleWidth
        let startX = guideX + middleWidth + gap
        let padWidth = p.size(trackpadWidth)
        let padHeight = p.size(trackpadHeight)
        let padY = p.bottomLine(startBackY - middleGap) - padHeight

        if !onlyL3R3 {
            slots.append((.dpad, OscSlot(left: p.left(dpadX), top: p.bottom(dpadY, dpadSize), width: p.size(dpadSize), height: p.size(dpadSize))))
            slots.append((.a, face(p, buttonX, buttonY + 2 * buttonSize)))
            slots.append((.b, face(p, buttonX + buttonSize, buttonY + buttonSize)))
            slots.append((.x, face(p, buttonX - buttonSize, buttonY + buttonSize)))
            slots.append((.y, face(p, buttonX, buttonY)))
            slots.append((.leftTrigger, trigger(p, rightSide: false, triggerLeftX, triggerY)))
            slots.append((.rightTrigger, trigger(p, rightSide: true, triggerRightX + triggerDistance, triggerY)))
            slots.append((.leftBumper, trigger(p, rightSide: false, triggerLeftX + triggerDistance, triggerY)))
            slots.append((.rightBumper, trigger(p, rightSide: true, triggerRightX, triggerY)))
            slots.append((.leftStick, OscSlot(
                left: p.left(analogLeftX), top: p.top(analogLeftY), width: p.size(analogSize), height: p.size(analogSize))))
            slots.append((.rightStick, OscSlot(
                left: p.right(analogRightX, analogSize), top: p.bottom(analogRightY, analogSize), width: p.size(analogSize), height: p.size(analogSize))))
            slots.append((.back, OscSlot(
                left: backX, top: p.bottom(startBackY, startBackHeight), width: p.size(startBackWidth), height: p.size(startBackHeight))))
            slots.append((.start, OscSlot(
                left: startX, top: p.bottom(startBackY, startBackHeight), width: p.size(startBackWidth), height: p.size(startBackHeight))))
            slots.append((.leftStickButton, shoulderClick(p, rightSide: false, triggerLeftX)))
            slots.append((.rightStickButton, shoulderClick(p, rightSide: true, triggerRightX + triggerDistance)))
            slots.append((.touchpad, OscSlot(left: center - padWidth / 2, top: padY, width: padWidth, height: padHeight)))
        } else {
            slots.append((.leftStickButton, shoulderClick(p, rightSide: false, triggerLeftX)))
            slots.append((.rightStickButton, shoulderClick(p, rightSide: true, triggerRightX + triggerDistance)))
        }
        if showGuide {
            slots.append((.guide, OscSlot(
                left: guideX, top: p.bottom(guideY, startBackHeight), width: p.size(startBackWidth), height: p.size(startBackHeight))))
        }
        return slots
    }

    /// The default slot of [id] on [panel]: where it goes does not depend on which others the settings turn on.
    static func slot(_ id: OscElementID, on panel: OscPanel) -> OscSlot? {
        compute(panel, onlyL3R3: false, showGuide: true).first { $0.id == id }?.slot
    }

    /// Whether [slot] is where the default layout puts [id] on [panel]: such a control has nothing to store.
    static func isDefault(_ id: OscElementID, _ slot: OscSlot, on panel: OscPanel) -> Bool {
        panel.width > 0 && panel.height > 0 && Self.slot(id, on: panel) == slot
    }

    /// The default layout on the 16:9 grid itself, where the anchors are read from.
    private static let grid = compute(OscPanel(width: OscPanel.gridWidth * 10, height: OscPanel.gridHeight * 10), onlyL3R3: false, showGuide: true)

    /// The side [id] keeps to horizontally: where the default layout puts it on the 16:9 grid, by thirds of the width (the left
    /// cluster, Back / Guide / Start and the trackpad in the middle, the right cluster).
    static func anchorX(_ id: OscElementID) -> OscPlacement.AnchorX {
        guard let s = grid.first(where: { $0.id == id })?.slot else { return .left }
        let center = Float(s.left) + Float(s.width) / 2
        let third = Float(OscPanel.gridWidth * 10) / 3
        return center < third ? .left : center > 2 * third ? .right : .center
    }

    /// The edge [id] keeps to vertically: the top for the upper half of the default layout, else the bottom.
    static func anchorY(_ id: OscElementID) -> OscPlacement.AnchorY {
        guard let s = grid.first(where: { $0.id == id })?.slot else { return .top }
        return Float(s.top) + Float(s.height) / 2 < Float(OscPanel.gridHeight * 10) / 2 ? .top : .bottom
    }

    /// A face button, the right cluster against the right edge, the top row against the top.
    private static func face(_ p: OscPanel, _ x: Int, _ y: Int) -> OscSlot {
        OscSlot(left: p.right(x, buttonSize), top: p.top(y), width: p.size(buttonSize), height: p.size(buttonSize))
    }

    /// A trigger or bumper: the upper half, against the top edge.
    private static func trigger(_ p: OscPanel, rightSide: Bool, _ x: Int, _ y: Int) -> OscSlot {
        OscSlot(left: rightSide ? p.right(x, triggerWidth) : p.left(x), top: p.top(y), width: p.size(triggerWidth), height: p.size(triggerHeight))
    }

    /// L3 or R3: the lower half, against the bottom edge.
    private static func shoulderClick(_ p: OscPanel, rightSide: Bool, _ x: Int) -> OscSlot {
        OscSlot(
            left: rightSide ? p.right(x, triggerWidth) : p.left(x), top: p.bottom(l3r3Y, triggerHeight),
            width: p.size(triggerWidth), height: p.size(triggerHeight))
    }
}

extension OscPlacement {
    /// Element [id] at [slot] on [panel], against its anchor (`OscPlacement.fromRect`).
    init(_ id: OscElementID, slot: OscSlot, enabled: Bool, panel: OscPanel) {
        let ax = OscDefaultLayout.anchorX(id)
        let ay = OscDefaultLayout.anchorY(id)
        let u = panel.unit
        let left = Float(slot.left), top = Float(slot.top), width = Float(slot.width), height = Float(slot.height)
        let x: Float = switch ax {
        case .left: left / u
        case .center: (left + width / 2 - Float(panel.width) / 2) / u
        case .right: (Float(panel.width) - left - width) / u
        }
        let y: Float = ay == .top ? top / u : (Float(panel.height) - top - height) / u
        self.init(anchorX: ax, anchorY: ay, x: x, y: y, width: width / u, height: height / u, enabled: enabled)
    }

    /// The rectangle in pixels on [panel], moved onto it (and shrunk when it is larger than the panel) (`OscPlacement.toRect`).
    func slot(on panel: OscPanel) -> OscSlot {
        let u = panel.unit
        let w = max(1, javaRound(width * u))
        let h = max(1, javaRound(height * u))
        let left = switch anchorX {
        case .left: javaRound(x * u)
        case .center: javaRound(Float(panel.width) / 2 + x * u - Float(w) / 2)
        case .right: panel.width - javaRound(x * u) - w
        }
        let top = anchorY == .top ? javaRound(y * u) : panel.height - javaRound(y * u) - h
        return panel.clamp(OscSlot(left: left, top: top, width: w, height: h))
    }
}
