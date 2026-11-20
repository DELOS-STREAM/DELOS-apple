import CoreGraphics
import Foundation

/// The rules of touch on a settings row and the arithmetic of the row popovers, which need no SwiftUI (`RowTouch`,
/// `SliderEdit`, `HoldRepeat` and `PickerLayout` of DELOS for Android, issue #92). Sizes are stage pixels. The views are
/// in `RowPopover.swift`.

/// What a touch tap does on a settings row; the controller and the keyboard keep A's activation.
enum RowTouch: Equatable {
    /// Only focus the row, so its help shows before anything changes.
    case focusOnly
    /// The same as A: flip a switch, open a screen or a dialog.
    case activate
    /// Open the choice's options as a popover list with the current value checked.
    case pick
    /// Open the slider's popover: ◀ ▶, the slider and the value to type.
    case adjust
    /// Nothing more (an info row has no action; where no popover can open a slider's value is set on its track).
    case none
    /// The row is unavailable: the error cue.
    case error

    /// The first tap on a row focuses it and shows its help; a tap on the focused row changes it. A row that only opens
    /// something (a screen, a dialog) opens on the first tap. [canPopup]: a popover can be shown for the row.
    static func of(_ value: SettingValue, wasFocused: Bool, enabled: Bool, canPopup: Bool = true) -> RowTouch {
        switch value {
        case .info: return .none
        case .action, .text, .appSettings: return enabled ? .activate : .error
        case .toggle, .choice, .slider: break
        }
        guard wasFocused else { return .focusOnly }
        guard enabled else { return .error }
        switch value {
        case .slider: return canPopup ? .adjust : .none
        case .choice: return canPopup ? .pick : .activate
        default: return .activate
        }
    }
}

/// Which popover a row opens on its second tap.
enum RowPopupKind: Equatable {
    case options, slider

    /// A choice with something to list opens its options, a slider its popover; nothing else has one.
    static func of(_ row: SettingRow) -> RowPopupKind? {
        switch row.value {
        case .choice(_, let options, _): options.isEmpty ? nil : .options
        case .slider: .slider
        case .toggle, .action, .text, .appSettings, .info: nil
        }
    }
}

/// What the Options command (the right menu button, X) does on the focused settings row: the same popover a second tap opens,
/// so a controller can see every value at once. In the app settings a custom row also resets: its choice list gets "Reset to
/// profile value" as the last item, while a custom slider (whose popover has no list) or a row without a popover opens its
/// context menu.
enum RowOptions: Equatable {
    case popup(RowPopupKind)
    case menu
    /// The row has a popover but is unavailable: the error sound.
    case refuse
    case none

    /// [custom]: the row overrides the profile's value (app settings only).
    static func of(_ row: SettingRow?, custom: Bool = false) -> RowOptions {
        guard let row else { return .none }
        let kind = RowPopupKind.of(row)
        guard let kind, row.enabled else { return custom ? .menu : kind == nil ? .none : .refuse }
        return kind == .slider && custom ? .menu : .popup(kind)
    }

    /// Options opens something here (its hint is shown).
    var opens: Bool {
        switch self {
        case .popup, .menu: true
        case .refuse, .none: false
        }
    }
}

/// A slider row's numbers in its own unit (the bitrate in kbit/s); [divisor] makes them readable (Mbit/s).
struct SliderSpec: Equatable {
    var value: Int
    var min: Int
    var max: Int
    var step: Int
    var divisor: Int
    var unit: String
    /// Shown instead of the number at the lowest value ("Off"), if any.
    var minText: String?

    init(value: Int, min: Int, max: Int, step: Int, divisor: Int = 1, unit: String, minText: String? = nil) {
        self.value = value
        self.min = min
        self.max = max
        self.step = step
        self.divisor = divisor
        self.unit = unit
        self.minText = minText
    }

    init?(_ value: SettingValue) {
        guard case let .slider(value, range, step, divisor, unit) = value else { return nil }
        self.init(value: value, min: range.lowerBound, max: range.upperBound, step: step, divisor: divisor, unit: unit)
    }

    private var grid: Int { Swift.max(step, 1) }

    /// [raw] moved to the nearest point of the grid (`min + n * step`), then into `min...max`.
    func snap(_ raw: Int) -> Int {
        let n = ((Double(raw) - Double(min)) / Double(grid) + 0.5).rounded(.down)
        let snapped = Double(min) + n * Double(grid)
        return Int(Swift.min(Swift.max(snapped, Double(min)), Double(max)))
    }

    /// [steps] grid steps from [current] (negative: down), landing on the grid and inside the range; a value between two
    /// steps snaps to the grid.
    func stepped(from current: Int, by steps: Int) -> Int {
        let delta = steps.multipliedReportingOverflow(by: grid)
        let moved = delta.overflow
            ? (steps < 0 ? Int.min : Int.max)
            : { let sum = current.addingReportingOverflow(delta.partialValue); return sum.overflow ? (delta.partialValue < 0 ? Int.min : Int.max) : sum.partialValue }()
        return snap(moved)
    }

    /// The number of [value] as the player reads it: whole in the readable unit when it is, else one decimal.
    func numberText(_ value: Int, locale: Locale = .current) -> String {
        value % divisor == 0 ? String(value / divisor) : String(format: "%.1f", locale: locale, Double(value) / Double(divisor))
    }

    /// The row's text: the number with its unit, or [minText] at the lowest value.
    func label(_ value: Int, locale: Locale = .current) -> String {
        if value == min, let minText { return minText }
        return numberText(value, locale: locale) + unit
    }

    /// What the player typed ([text], in the readable unit: Mbit/s for the bitrate, a comma or a point for decimals) as the
    /// slider's value: validated, rounded to the grid and clamped to the range, so typing 400 on a slider that ends at 150
    /// applies 150. Nil for text that is no number (empty, letters, a lone separator).
    func parse(_ text: String) -> Int? {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        var negative = false
        if let sign = body.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            body = body.dropFirst()
        }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.contains(where: { !$0.isEmpty }) else { return nil }
        // More digits than a Decimal holds is far outside every range
        let digits = parts.reduce(0) { $0 + $1.count }
        guard digits <= 30, var number = Decimal(string: String(body), locale: Locale(identifier: "en_US_POSIX")) else {
            return snap(negative ? min : max)
        }
        if negative { number.negate() }
        var scaled = number * Decimal(divisor)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let inRange = Swift.min(Swift.max(rounded, Decimal(min)), Decimal(max))
        return snap(NSDecimalNumber(decimal: inRange).intValue)
    }

    /// True while [text] can still become a number by typing more: only digits and one decimal separator.
    static func typable(_ text: String) -> Bool {
        text.filter { $0 == "." || $0 == "," }.count <= 1 && text.allSatisfy { $0.isASCII && $0.isNumber || $0 == "." || $0 == "," }
    }
}

/// Holding a ◀ or ▶ button of the slider popover repeats it, faster the longer it is held (the acceleration of a held key).
enum HoldRepeat {
    /// The pause before the first repeat, and between repeats, in seconds.
    static let firstDelay = 0.38
    static let interval = 0.055

    /// The steps of the [repeatCount]th repeat (counted from 1): the acceleration of the key repeat with the same count.
    static func steps(_ slider: SliderSpec, repeatCount: Int) -> Int {
        StreamSettingsForm.sliderAcceleration(steps: (slider.max - slider.min) / Swift.max(slider.step, 1), repeatCount: repeatCount)
    }
}

/// A row popover's card and its caret, stage pixels.
struct RowPopoverPlacement: Equatable {
    /// The card without its caret.
    var card: CGRect
    /// The caret's center from the card's top.
    var caretY: Double
    /// The caret's tip: it lies in the row's value area, level with its middle.
    var tip: CGPoint
    /// The caret is on the card's right edge (the card lies left of the tip): only when the right side has no room.
    var flipped = false
}

/// The geometry of the popover of a settings row (the same as DELOS for Android's). The card is vertically centered on the row and
/// kept inside the margins of the stage; its caret on the card's left edge points left into the row, ``valueInset`` left of the
/// row's right edge (left of the value text), or further left so that the card ends ``sideMargin`` before the stage's right edge, but
/// never closer than ``minTipInset`` to the row's left edge; the card extends to the right of the caret, as if it grew out of the
/// arrow. Only when the right side has no room does it flip: the caret on the right edge with its tip ``flipTipInset`` inside the
/// row's right edge and the card to the left. When neither side has room the card is narrowed, as the last resort.
enum RowPopoverLayout {
    /// The options list card.
    static let optionsWidth = 560.0
    static let pad = 20.0, title = 36.0, option = 64.0, gap = 4.0, listRoom = 3.0
    /// The slider card: 1040 × 300, its parts sized for a finger (96 high buttons and track, an 88 high field).
    static let sliderWidth = 1040.0
    static let sliderPad = 28.0, sliderTitle = 36.0, sliderGap = 12.0, touch = 96.0, fieldHeight = 88.0, controlGap = 20.0
    static let numberSize = 52.0, unitSize = 32.0, knob = 30.0
    static let sliderHeight = 2 * sliderPad + sliderTitle + sliderGap + fieldHeight + sliderGap + touch

    /// The caret is the shared ``CardCaret``.
    static let caretWidth = CardCaret.width
    static let caretHeight = CardCaret.depth
    static let radius = 44.0
    /// The caret keeps this far from the card's corners.
    static let caretMinInset = radius + caretWidth / 2
    /// The tip lies this far left of the row's right edge: just left of the value text.
    static let valueInset = 360.0
    /// The tip never comes closer than this to the row's left edge, and a flipped card's tip lies this far inside the row's right edge.
    static let minTipInset = 120.0, flipTipInset = 120.0
    /// The gap the card keeps to the stage's sides and bottom; at the top it stays below the top bar (104) and the name that
    /// hangs under its focused button (to about 136), so a long list starts under them and scrolls (Android's 104 clears only
    /// the bar).
    static let sideMargin = 24.0, topMargin = 148.0, bottomMargin = 24.0

    /// What the options card has besides its list: padding, the title and its gap.
    static let chrome = 2 * pad + title + 2 * gap

    static func listHeight(count: Int) -> Double { count <= 0 ? 0 : Double(count) * (option + gap) + 2 * listRoom }

    /// The card of an options list: [count] options, the card as tall as they need within the room.
    static func options(row: CGRect, count: Int, stage: CGSize, top: Double = topMargin, bottom: Double = bottomMargin, side: Double = sideMargin)
        -> (placement: RowPopoverPlacement, list: Double) {
        let room = Swift.max(stage.height - top - bottom - chrome, option)
        let list = Swift.min(listHeight(count: count), room)
        return (place(row: row, width: optionsWidth, height: chrome + list, stage: stage, top: top, bottom: bottom, side: side), list)
    }

    /// The card of the slider popover.
    static func slider(row: CGRect, stage: CGSize, top: Double = topMargin, bottom: Double = bottomMargin, side: Double = sideMargin) -> RowPopoverPlacement {
        place(row: row, width: sliderWidth, height: sliderHeight, stage: stage, top: top, bottom: bottom, side: side)
    }

    /// A card of [width] × [height] centered on [row]'s middle, inside the margins; its caret at the row's middle, the tip in the
    /// row's value area. See the type's comment for the sides.
    static func place(row: CGRect, width: Double, height: Double, stage: CGSize, top: Double, bottom: Double, side: Double) -> RowPopoverPlacement {
        let h = Swift.min(height, Swift.max(stage.height - top - bottom, option))
        let y = Swift.min(Swift.max(row.midY - h / 2, top), Swift.max(stage.height - bottom - h, top))
        // Right of the tip: left of the value text, pulled left until the card ends before the stage's edge
        let rightLimit = stage.width - side - caretHeight - width
        var tipX = Swift.max(Swift.min(row.maxX - valueInset, rightLimit), row.minX + minTipInset)
        var w = width
        var flipped = false
        if tipX + caretHeight + width > stage.width + 0.0001 - side {
            let rightRoom = stage.width - side - (tipX + caretHeight)
            let flipTip = row.maxX - flipTipInset
            let leftRoom = flipTip - caretHeight - side
            if leftRoom >= width {
                flipped = true
                tipX = flipTip
            } else {
                // Neither side has room: the one with more, narrowed to it
                flipped = leftRoom > rightRoom
                if flipped { tipX = flipTip }
                w = Swift.min(width, Swift.max(flipped ? leftRoom : rightRoom, option))
            }
        }
        let x = flipped ? tipX - caretHeight - w : tipX + caretHeight
        let inset = Swift.min(caretMinInset, h / 2)
        let caretY = Swift.min(Swift.max(row.midY - y, inset), Swift.max(h - inset, inset))
        let tip = CGPoint(x: flipped ? x + w + caretHeight : x - caretHeight, y: y + caretY)
        return RowPopoverPlacement(card: CGRect(x: x, y: y, width: w, height: h), caretY: caretY, tip: tip, flipped: flipped)
    }
}
