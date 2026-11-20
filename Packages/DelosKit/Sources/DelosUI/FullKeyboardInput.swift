import DelosInput
import Foundation

/*
 * The pure logic of the Delos full keyboard (`FullKeyboardInput.kt` of DELOS for Android): where the D-pad moves the
 * focus, what a modifier does when it is touched or pressed with a controller, which controller buttons mean what, and how
 * big the keys are. No SwiftUI in here, so it is unit tested (FullKeyboardInputTests); ``FullKeyboardState`` puts it to work.
 */

/// A direction of the controller's focus.
enum KeyDirection: Sendable {
    case up, down, left, right
}

/// A key in the grid: its row and its place in that row.
struct KeyPos: Hashable, Sendable {
    let row: Int
    let col: Int
}

/// The part of a row a key covers, in the units of ``KeyGrid/navWidth``.
struct KeySpan: Equatable, Sendable {
    let start: Double
    let end: Double
    var center: Double { (start + end) / 2 }
}

/// Where the focus went and the horizontal position [anchorX] that later up and down moves aim for.
struct NavMove: Equatable, Sendable {
    let pos: KeyPos
    let anchorX: Double
}

/// The key grid the controller moves through. A move left or right stays in its row and stops at the ends; up and down go
/// to the key of the next row that lies under the *anchor* (the center of the last key reached by a horizontal move), or
/// else to the nearest one, so a column of the keyboard is followed even though the rows are not aligned. Spans come from
/// the weights, gaps and margins of the rows, laid out at ``navWidth``: only their proportions matter.
struct KeyGrid: Sendable {
    let rows: [[KeyDef]]
    private let rowSpans: [[KeySpan]]

    init(rows: [[KeyDef]]) {
        self.rows = rows
        rowSpans = rows.map { Self.layoutSpans($0) }
    }

    /// The width the grid is laid out at for navigation, in stage pixels (the widest keyboard).
    static let navWidth = KeyboardMetrics.maxBodyWidth
    /// The key at which the controller focus starts (and the one it falls back to): Q.
    static let firstKey = KeyCode.character("Q")
    static let standard = KeyGrid(rows: FullKeyboardKeys.rows)

    func key(_ pos: KeyPos) -> KeyDef { rows[pos.row][pos.col] }

    func span(_ pos: KeyPos) -> KeySpan { rowSpans[pos.row][pos.col] }

    func find(_ code: Int) -> KeyPos? {
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(where: { $0.code == code }) { return KeyPos(row: r, col: c) }
        }
        return nil
    }

    /// The focus after a step in [direction] from [from], nil at the edge of the keyboard (the ring nudges there).
    func move(_ from: KeyPos, anchorX: Double, _ direction: KeyDirection) -> NavMove? {
        let row = from.row
        switch direction {
        case .left: return from.col > 0 ? land(KeyPos(row: row, col: from.col - 1)) : nil
        case .right: return from.col < rows[row].count - 1 ? land(KeyPos(row: row, col: from.col + 1)) : nil
        case .up: return row > 0 ? NavMove(pos: KeyPos(row: row - 1, col: nearest(row - 1, anchorX)), anchorX: anchorX) : nil
        case .down: return row < rows.count - 1 ? NavMove(pos: KeyPos(row: row + 1, col: nearest(row + 1, anchorX)), anchorX: anchorX) : nil
        }
    }

    /// A focus that lands on [pos] directly (the first key, a horizontal step): its center is the anchor.
    func land(_ pos: KeyPos) -> NavMove { NavMove(pos: pos, anchorX: span(pos).center) }

    /// The column of [row] that lies under [x], the nearest one when none does (the first of two equally near ones).
    private func nearest(_ row: Int, _ x: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (col, span) in rowSpans[row].enumerated() {
            let distance = x >= span.start && x <= span.end ? 0 : min(abs(x - span.start), abs(x - span.end))
            if distance < bestDistance {
                bestDistance = distance
                best = col
            }
        }
        return best
    }

    /// Where the keys of [row] lie in a row [width] wide with [gap] between keys and [sep] for every margin: the weights
    /// share what the gaps leave, a margin takes from its own key only (like CSS grid tracks with margins on the items).
    static func layoutSpans(_ row: [KeyDef], width: Double = navWidth, gap: Double = KeyboardMetrics.gap, sep: Double = KeyboardMetrics.sep) -> [KeySpan] {
        let free = width - gap * Double(row.count - 1)
        let total = row.reduce(0) { $0 + $1.weight }
        var x = 0.0
        return row.map { key in
            let track = free * key.weight / total
            let span = KeySpan(start: x + (key.marginStart ? sep : 0), end: x + track - (key.marginEnd ? sep : 0))
            x += track + gap
            return span
        }
    }
}

/// What the keyboard sends to the PC for a touch or a press.
enum KeySend: Sendable {
    case none, down, up
}

/// Which modifiers are latched, and what touching or pressing one sends. A latched modifier is *down* on the PC until it
/// is released, so the keys typed meanwhile carry it.
///
/// Touch (sticky modifier setting on): a press sends Down; holding it for 300 ms latches it and the release is not sent;
/// touching a latched modifier unlatches it (that touch sends nothing, its release sends Up). With the setting off a
/// modifier is an ordinary key. A controller cannot hold one key while pressing another, so A on a modifier toggles the
/// latch whatever the setting says: Down (latched) or Up (unlatched). Hiding the keyboard releases every latched modifier.
struct ModifierLatch: Sendable {
    /// In the order they were latched.
    private var latched: [Int] = []

    func isLatched(_ code: Int) -> Bool { latched.contains(code) }

    var codes: Set<Int> { Set(latched) }

    mutating func touchDown(_ code: Int, sticky: Bool) -> KeySend {
        if sticky, KeyCode.isModifier(code), let index = latched.firstIndex(of: code) {
            latched.remove(at: index)
            return .none
        }
        return .down
    }

    func touchUp(_ code: Int, sticky: Bool) -> KeySend {
        sticky && KeyCode.isModifier(code) && latched.contains(code) ? .none : .up
    }

    /// The touch has been held long enough: the modifier stays down.
    mutating func latchHeld(_ code: Int) {
        if !latched.contains(code) { latched.append(code) }
    }

    /// The keyboard is hidden: every latched modifier is let go. Returns the ones that were down, in the order they were
    /// latched, so the PC gets their Up.
    mutating func releaseAll() -> [Int] {
        defer { latched.removeAll() }
        return latched
    }

    mutating func padPress(_ code: Int) -> KeySend {
        if let index = latched.firstIndex(of: code) {
            latched.remove(at: index)
            return .up
        }
        latched.append(code)
        return .down
    }
}

/// The controller's key repeat: the D-pad and the held X / Y keys repeat after the delay, then every interval (ms).
enum PadRepeat {
    static let delay: Int64 = 350
    static let interval: Int64 = 100
}

/// What a controller button does while the keyboard is up.
enum PadAction: Equatable, Sendable {
    case move(KeyDirection)
    case pressDown
    case pressUp
    case close
    /// L3: Shift on or off as a latch.
    case toggleShift
    /// X or Y went down: the key [code] (Backspace, Space) goes down and repeats while the button is held.
    case boundDown(Int)
    case boundUp(Int)

    /// The key a face button types while the keyboard is up: X is Backspace, Y is Space.
    static let xKey = KeyCode.backspace
    static let yKey = KeyCode.space

    /// The keyboard actions of one controller's buttons that changed from [old] to [new] (`padKeyAction` of DELOS for
    /// Android, whose key events are the edges of the snapshots here): A holds the focused key down and lets it go, B
    /// closes on release, L3 (the left stick click) toggles Shift on its press, X types Backspace and Y Space (down on
    /// press, up on release; the keyboard repeats them itself). The other buttons do nothing for the keyboard (it still
    /// swallows them, so nothing reaches the game). The D-pad and the stick are not here: see ``DpadTracker`` and
    /// ``analogDirection(x:y:)``.
    static func buttons(from old: GamepadSnapshot, to new: GamepadSnapshot) -> [PadAction] {
        var actions: [PadAction] = []
        if new.a != old.a { actions.append(new.a ? .pressDown : .pressUp) }
        if old.b, !new.b { actions.append(.close) }
        if new.leftStickButton, !old.leftStickButton { actions.append(.toggleShift) }
        if new.x != old.x { actions.append(new.x ? .boundDown(xKey) : .boundUp(xKey)) }
        if new.y != old.y { actions.append(new.y ? .boundDown(yKey) : .boundUp(yKey)) }
        return actions
    }
}

/// The D-pad of a controller as the hat of a joystick (`DpadTracker` of DELOS for Android: GameController reports the
/// D-pad's state, not key events, like the hat axes of a handheld there): sent only when it changes, so nothing repeats
/// unless a timer does. A direction that is newly pressed moves at once, and ``repeatAt`` / ``repeat(now:)`` then repeat
/// the most recent one after [initialDelay] every [repeatInterval] until the hat returns to the center (or that direction
/// is let go). A diagonal is the direction pressed last; rolling the thumb from Right to Up-right moves Up, and releasing
/// Up afterwards stops the repeat (the thumb makes no new press) until the next one.
struct DpadTracker: Sendable {
    private let initialDelay: Int64
    private let repeatInterval: Int64
    private var hatX = 0
    private var hatY = 0
    private var hatDirection: KeyDirection?
    private var nextRepeat: Int64?

    init(initialDelay: Int64 = PadRepeat.delay, repeatInterval: Int64 = PadRepeat.interval) {
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
    }

    /// When ``repeat(now:)`` is next due (ms), nil while nothing repeats.
    var repeatAt: Int64? { nextRepeat }

    /// The hat ([x] right, [y] down, −1…1) changed or was re-sent at [now]; the direction to move to right now, if any.
    mutating func onHat(x: Double, y: Double, now: Int64) -> KeyDirection? {
        let sx = Self.sign(x), sy = Self.sign(y)
        let pressedX = sx != 0 && sx != hatX
        let pressedY = sy != 0 && sy != hatY
        hatX = sx
        hatY = sy
        if sx == 0 && sy == 0 {
            hatDirection = nil
            nextRepeat = nil
            return nil
        }
        let horizontal: KeyDirection = sx < 0 ? .left : .right
        let vertical: KeyDirection = sy < 0 ? .up : .down
        if !pressedX && !pressedY {
            // Nothing new was pressed: a diagonal let go of one side keeps repeating the side that is still the one pressed last
            let stillHeld = hatDirection.map { (sx != 0 && $0 == horizontal) || (sy != 0 && $0 == vertical) } ?? false
            if !stillHeld {
                hatDirection = sx != 0 ? horizontal : vertical
                nextRepeat = nil
            }
            return nil
        }
        let direction = pressedX ? horizontal : vertical
        hatDirection = direction
        nextRepeat = now + initialDelay
        return direction
    }

    /// The repeat timer fired at [now]: the direction to move to again, or nil when none is due.
    mutating func `repeat`(now: Int64) -> KeyDirection? {
        guard let direction = hatDirection, let next = nextRepeat, now >= next else { return nil }
        nextRepeat = now + repeatInterval
        return direction
    }

    mutating func reset() {
        hatX = 0
        hatY = 0
        hatDirection = nil
        nextRepeat = nil
    }

    private static func sign(_ value: Double) -> Int {
        value <= -hatThreshold ? -1 : value >= hatThreshold ? 1 : 0
    }

    static let hatThreshold = 0.5
}

/// The left stick's moves of the focus (`DirectionalRepeater` of DELOS for Android): a new direction moves at once, the same
/// one again after [initialDelay], then every [repeatInterval]; the center stops it. GameController reports the stick only
/// when it moves, so the keyboard asks again at ``repeatAt`` while it is held still.
struct DirectionalRepeater: Sendable {
    private let initialDelay: Int64
    private let repeatInterval: Int64
    private var direction: KeyDirection?
    private var nextRepeatAt: Int64 = 0

    init(initialDelay: Int64 = PadRepeat.delay, repeatInterval: Int64 = PadRepeat.interval) {
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
    }

    /// When the held direction is next due, nil while the stick is centered.
    var repeatAt: Int64? { direction == nil ? nil : nextRepeatAt }

    mutating func shouldMove(_ next: KeyDirection?, now: Int64) -> Bool {
        guard let next else {
            reset()
            return false
        }
        if next != direction {
            direction = next
            nextRepeatAt = now + initialDelay
            return true
        }
        guard now >= nextRepeatAt else { return false }
        nextRepeatAt = now + repeatInterval
        return true
    }

    mutating func reset() {
        direction = nil
        nextRepeatAt = 0
    }
}

/// The direction a stick pushed to ([x] right, [y] down) means: the stronger axis, once it is past the threshold; nil near
/// the center. Equal strength goes vertical, like the stream menu.
func analogDirection(x: Double, y: Double) -> KeyDirection? {
    let threshold = 0.55
    if abs(x) > abs(y), x <= -threshold { return .left }
    if abs(x) > abs(y), x >= threshold { return .right }
    if y <= -threshold { return .up }
    if y >= threshold { return .down }
    return nil
}

/// How the size settings lay the keyboard out: see ``KeyboardMetrics/metrics(screenWidth:prefs:dpPerPx:)``.
struct KeyboardPrefs: Equatable, Sendable {
    /// `onscreen_keyboard_autofit` is the setting that turns the automatic fit *off*.
    var autoFitDisabled = false
    /// `seekbar_onscreen_keyboard_height`, dp (points here).
    var heightDp = 200
    /// `seekbar_onscreen_keyboard_width`, dp; 1000 means the full width.
    var widthDp = 1000
    var align = KeyboardAlign.center
    /// `seekbar_keyboard_axi_opacity`, percent.
    var opacityPercent = 90
}

enum KeyboardAlign: Sendable {
    case left, center, right

    /// The stored `list_onscreen_keyboard_align_mode` value; anything unknown is the center.
    static func parse(_ value: String?) -> KeyboardAlign {
        switch value {
        case "left": .left
        case "right": .right
        default: .center
        }
    }
}

/// The measures of the keyboard in stage pixels (1080 high).
struct KeyboardMetrics: Equatable, Sendable {
    let bodyWidth: Double
    let keyHeight: Double

    static let rows = 6.0
    /// The gap between two keys, across and down (``FocusSpacing``, dense key grid): a key does not grow and its ring is
    /// drawn inside it, so the clearance is enough.
    static let gap = FocusSpacing.clearance
    static let sep = 12.0
    static let side = 24.0
    static let topPad = 22.0
    /// Under the rows: the hint strip (48 + 14) and the space above it.
    static let bottomPad = 78.0
    static let maxBodyWidth = 1840.0
    static let fontPerKey = 0.38
    static let minKey = 44.0
    static let maxKey = 68.0
    static let widthPerKey = 0.0365
    static let minCustomKey = 24.0
    static let maxCustomKey = 130.0
    static let fullWidthDp = 1000

    var fontSize: Double { keyHeight * Self.fontPerKey }
    var barHeight: Double { Self.topPad + Self.rows * keyHeight + (Self.rows - 1) * Self.gap + Self.bottomPad }
    /// Room above the bar for the popup of the top row.
    var popupRoom: Double { keyHeight * 1.2 }

    /// The size of the keys and of the keyboard: by default the keys span the width of the screen less 24 on each side, at
    /// most 1840, and are 3.65 % of that tall (44 to 68), so a 21:9 screen centers a keyboard of the same width and a 4:3
    /// one gets smaller keys instead of a taller keyboard. With the automatic fit off the settings apply: the width (1000 =
    /// the full width) and the height of the whole bar in points, from which the key height follows. [screenWidth] is in
    /// stage pixels, [dpPerPx] the points one stage pixel is.
    static func metrics(screenWidth: Double, prefs: KeyboardPrefs, dpPerPx: Double) -> KeyboardMetrics {
        let widest = max(min(screenWidth - 2 * side, maxBodyWidth), 1)
        guard prefs.autoFitDisabled else {
            return KeyboardMetrics(bodyWidth: widest, keyHeight: min(max(widest * widthPerKey, minKey), maxKey))
        }
        let width = prefs.widthDp >= fullWidthDp ? widest : min(Double(prefs.widthDp) / dpPerPx, widest)
        let chrome = topPad + (rows - 1) * gap + bottomPad
        let key = min(max((Double(prefs.heightDp) / dpPerPx - chrome) / rows, minCustomKey), maxCustomKey)
        return KeyboardMetrics(bodyWidth: width, keyHeight: key)
    }
}
