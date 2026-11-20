import DelosData
import Foundation
import Network
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import IOKit.ps
#endif

// MARK: Device state

/// What the system says about the battery's charging (`UIDevice.BatteryState` without UIKit, so the rules are testable
/// on the Mac).
enum PowerState: Sendable {
    case unknown, unplugged, charging, full
}

/// The battery of the device (`BatteryStatus` of DELOS for Android): [level] 0...1.
struct BatteryStatus: Equatable, Sendable {
    let level: Double
    let charging: Bool

    /// At or below this level the charge shows red while not charging, as on iOS.
    static let lowLevel = 0.2

    /// nil where the system does not know the battery (a simulator, a Mac without one): the bar then shows none.
    init?(level: Double, state: PowerState) {
        guard level >= 0, state != .unknown else { return nil }
        self.init(level: level, charging: state == .charging || state == .full)
    }

    init(level: Double, charging: Bool) {
        self.level = min(level, 1)
        self.charging = charging
    }

    /// The charge is red (low and not charging), else green.
    var low: Bool { !charging && level <= Self.lowLevel }
    /// How much of the inside the charge fills: never less than a sliver, so an almost empty battery still shows red.
    var fill: Double { min(max(level, 0.04), 1) }
    /// The percentage beside the battery.
    var percent: String { "\(Int((level * 100).rounded()))%" }
}

/// The Wi-Fi of the default network (`WifiStatus` of DELOS for Android). iOS gives apps no signal strength, so it is
/// connected (full bars) or not; another network (cellular, Ethernet) shows as no Wi-Fi, as on Android. Except on Apple
/// TV, which is often wired: a connection by cable shows no icon at all instead of a Wi-Fi that is off.
enum WifiStatus: Equatable, Sendable {
    case connected, none, wired

    /// - Parameter wired: the network is Ethernet (read on Apple TV only).
    init(satisfied: Bool, usesWifi: Bool, wired: Bool = false) {
        self = satisfied && usesWifi ? .connected : satisfied && wired ? .wired : .none
    }

    /// The glyph of the status; nil when there is nothing to show.
    var icon: String? {
        switch self {
        case .connected: Symbols.wifi
        case .none: Symbols.wifiOff
        case .wired: nil
        }
    }
}

extension BatteryStatus {
    /// The battery of one power source as `IOPSGetPowerSourceDescription` describes it (the Mac); nil for anything but
    /// the internal battery. A Mac on the charger shows the bolt, charging or holding its charge, as an iPhone does.
    init?(powerSource info: [String: Any]) {
        guard info["Type"] as? String == "InternalBattery",
              let current = info["Current Capacity"] as? Int, let maximum = info["Max Capacity"] as? Int, maximum > 0
        else { return nil }
        let charging = info["Is Charging"] as? Bool == true || info["Power Source State"] as? String == "AC Power"
        self.init(level: Double(current) / Double(maximum), state: charging ? .charging : .unplugged)
    }
}

/// Follows the battery (`UIDevice` battery monitoring) and the network (`NWPathMonitor`) for the status bar.
@MainActor @Observable final class DeviceStatus {
    private(set) var battery: BatteryStatus?
    private(set) var wifi = WifiStatus.none
    @ObservationIgnored private var monitor: NWPathMonitor?
    #if os(macOS)
    @ObservationIgnored private var batteryTask: Task<Void, Never>?
    #endif
    #if DEBUG
    /// Screenshots: `-DelosBattery <percent>` (`c` after it: charging) stands in for the battery a simulator lacks.
    @ObservationIgnored private let debugBattery: BatteryStatus? = UserDefaults.standard.string(forKey: "DelosBattery").flatMap { text in
        Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "c"))).map { level in
            BatteryStatus(level: level / 100, charging: text.hasSuffix("c"))
        }
    }
    #endif

    /// Starts following both; a second call does nothing.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            #if os(tvOS)
            let wired = path.usesInterfaceType(.wiredEthernet)
            #else
            let wired = false
            #endif
            let wifi = WifiStatus(satisfied: path.status == .satisfied, usesWifi: path.usesInterfaceType(.wifi), wired: wired)
            Task { @MainActor in self?.wifi = wifi }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBattery() }
            }
        }
        readBattery()
        #elseif os(macOS)
        startBatteryPolling()
        #endif
        #if DEBUG
        if let debugBattery { battery = debugBattery }
        #endif
    }

    #if os(iOS)
    private func readBattery() {
        #if DEBUG
        if debugBattery != nil { return }
        #endif
        let state: PowerState = switch UIDevice.current.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        case .unknown: .unknown
        @unknown default: .unknown
        }
        battery = BatteryStatus(level: Double(UIDevice.current.batteryLevel), state: state)
    }
    #elseif os(macOS)
    /// A Mac's internal battery is read once a minute; a Mac without one shows none, as a simulator does.
    private func startBatteryPolling() {
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readBattery()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func readBattery() {
        #if DEBUG
        if debugBattery != nil { return }
        #endif
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .compactMap(BatteryStatus.init(powerSource:))
            .first
    }
    #endif
}

// MARK: Clock

/// The status bar's clock (`rememberClock` of DELOS for Android): hours and minutes in the app's language, 12- or
/// 24-hour as Settings → Appearance → Clock says; System follows the device's 24-Hour Time setting.
enum StatusClock {
    static func uses24Hours(_ format: ClockFormat, locale: Locale) -> Bool {
        switch format {
        case .system:
            switch locale.hourCycle {
            case .zeroToTwentyThree, .oneToTwentyFour: true
            case .zeroToEleven, .oneToTwelve: false
            @unknown default: true
            }
        case .h12: false
        case .h24: true
        }
    }

    /// The locale's pattern for hours and minutes. ICU puts a narrow no-break space (U+202F) before AM / PM, which the
    /// bundled fonts lack: it becomes a space, as on Android.
    static func pattern(_ format: ClockFormat, locale: Locale) -> String {
        let h24 = uses24Hours(format, locale: locale)
        let pattern = DateFormatter.dateFormat(fromTemplate: h24 ? "Hm" : "hm", options: 0, locale: locale) ?? (h24 ? "HH:mm" : "h:mm a")
        return pattern.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func text(_ date: Date, format: ClockFormat, locale: Locale, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern(format, locale: locale)
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

// MARK: Layout

/// The compact status bar's arithmetic (`StatusBarLayout` of DELOS for Android, issue #9): where the top navigation
/// sits between the brand cluster on the left and the status cluster on the right, and what the bar gives up when they
/// do not all fit. Sizes in stage pixels.
enum StatusBarLayout {
    /// The bar's height, its side margin (the safe area comes on top) and the least air between the navigation and
    /// either cluster.
    static let height = 104.0
    static let side = 72.0
    static let minGap = 24.0
    /// A navigation button on a compact stage (64 elsewhere) and the pill's padding.
    static let navButton = 56.0
    static let navPadding = 8.0
    /// The gap between the navigation's buttons, also on a tight compact bar (``FocusSpacing``): a focused 64 px button
    /// grows by 12 % (3.84 px a side) and has no ring, so two neighbours need 2 × 3.84 + 8 = 15.68.
    static let navGap = 16.0
    /// The gap between Wi-Fi, battery and clock and the one between the battery and its percentage (normal, tight).
    static let statusGap = 28.0
    static let statusGapTight = 16.0
    static let batteryGap = 10.0
    static let batteryGapTight = 6.0
    /// A compact bar narrower than this has no wordmark (`Compact.NARROW_STAGE`).
    static let narrowStage = 1280.0

    /// The width of a navigation pill of [buttons] buttons [button] wide and [gap] apart.
    static func navWidth(buttons: Int, button: Double, gap: Double) -> Double {
        buttons <= 0 ? 0 : Double(buttons) * button + Double(buttons - 1) * gap + 2 * navPadding
    }

    /// Where something [width] wide goes between [start] and [end]: on [centre] when it fits there, else in the middle
    /// of the free space; nil when the free space is narrower than it.
    static func placeBetween(start: Double, end: Double, width: Double, centre: Double) -> Double? {
        if end - start < width { return nil }
        let centred = centre - width / 2
        return centred >= start && centred + width <= end ? centred : start + (end - start - width) / 2
    }

    /// Lays the compact bar out on [width] with the side margins (safe area included): tries the steps in order and
    /// takes the first whose navigation keeps [minGap] to both clusters, centred on the bar when that leaves the gap,
    /// else in the middle of the free space. A cluster that is not shown (width 0) needs no gap.
    static func fit(width: Double, sideLeft: Double, sideRight: Double, minGap: Double = minGap,
                    widths: (StatusBarStep) -> StatusBarWidths) -> StatusBarFit {
        let centre = sideLeft + (width - sideLeft - sideRight) / 2
        var last = StatusBarWidths(left: 0, nav: 0, right: 0)
        for step in StatusBarStep.allCases {
            let w = widths(step)
            last = w
            let start = sideLeft + w.left + (w.left > 0 ? minGap : 0)
            let end = width - sideRight - w.right - (w.right > 0 ? minGap : 0)
            guard let x = placeBetween(start: start, end: end, width: w.nav, centre: centre) else { continue }
            return StatusBarFit(step: step, navX: x, centred: x == centre - w.nav / 2, fits: true)
        }
        let start = sideLeft + last.left
        let end = width - sideRight - last.right
        return StatusBarFit(step: .noPercent, navX: start + (end - start - last.nav) / 2, centred: false, fits: false)
    }
}

/// What the compact status bar gives up, in this order: nothing, the status cluster's inner gaps, then also the battery's
/// percentage. The navigation's gap never tightens (``StatusBarLayout/navGap``).
enum StatusBarStep: CaseIterable, Sendable {
    case full, tight, noPercent

    var tight: Bool { self != .full }
    var percent: Bool { self != .noPercent }
}

/// The widths of the bar's three parts for one step; 0 for a part that is not shown.
struct StatusBarWidths: Equatable {
    let left: Double
    let nav: Double
    let right: Double
}

/// The step drawn, the navigation's left edge (from the bar's left edge), whether it is on the bar's middle, and
/// whether even the last step keeps the gap.
struct StatusBarFit: Equatable {
    let step: StatusBarStep
    let navX: Double
    let centred: Bool
    let fits: Bool
}

// MARK: Views

/// The status bar (`StatusBar` of DELOS for Android, inside its `ZoomedBar`): the brand at the top left with the
/// connected PC, the top navigation in the middle, Wi-Fi, the battery and the clock at the right, in a 104 px bar 72 px
/// from the sides. A compact stage gets ``CompactStatusBar``. The start screen leaves the brand out: the profile chip
/// is at the top there.
struct TopBar: View {
    /// The buttons of the top navigation and the focus they belong to.
    struct Navigation {
        let buttons: [NavButton]
        let focus: FocusModel
    }

    var brand = true
    var navigation: Navigation?
    /// The PC whose library is open, beside the brand on the screens of the top navigation.
    var pc: (name: String, online: Bool)?
    var wifi = WifiStatus.none
    var battery: BatteryStatus?
    var clock = ClockFormat.system
    /// Shown on iPhone, iPad and Mac when the screen can go back: a touch or mouse user has no B button and the system has
    /// no back gesture of its own (on Android the system's back does it, so DELOS for Android has no such button).
    var onBack: (() -> Void)?
    @Environment(\.stage) private var stage

    var body: some View {
        VStack {
            Group {
                if stage.compact {
                    CompactStatusBar(bar: self)
                } else {
                    ZStack {
                        HStack(spacing: 0) {
                            BackButton(onBack: onBack)
                            if brand {
                                HStack(spacing: stage.px(18)) {
                                    Brand()
                                    if let pc { PcPill(name: pc.name, online: pc.online) }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        if let navigation { TopNav(buttons: navigation.buttons, focus: navigation.focus).tvFocusSection() }
                        StatusCluster(wifi: wifi, battery: battery, clock: clock)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.leading, stage.px(StatusBarLayout.side + stage.safe.leading))
                    .padding(.trailing, stage.px(StatusBarLayout.side + stage.safe.trailing))
                }
            }
            .frame(height: stage.px(StatusBarLayout.height))
            .padding(.top, stage.px(stage.safe.top))
            Spacer()
        }
    }
}

/// The back button at the start of the bar (iPhone, iPad and Mac), shown while no controller is the input.
private struct BackButton: View {
    let onBack: (() -> Void)?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        #if os(iOS) || os(macOS)
        if let onBack {
            Button(action: onBack) {
                SymbolView(symbol: Symbols.arrowBack, size: 34, color: colors.text)
                    .frame(width: stage.px(68), height: stage.px(68))
                    .background(GlassShape(Circle(), tint: colors.surface))
                    .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
            .pressButton()
            .accessibilityLabel(L("shell_hint_back"))
            // A controller's B goes back: the arrow is for fingers, pointers and keyboards (the gap after it goes with it)
            .inputKindVisibility(.withoutController, gap: 24)
        }
        #endif
    }
}

/// The status bar of a compact stage (`CompactStatusBar` of DELOS for Android): the navigation's buttons are 56 px, the
/// connected PC is only its dot with the PC glyph, there is no wordmark under 1280 px, and ``StatusBarLayout/fit``
/// places the navigation and says what the status cluster gives up. The clusters are measured by hidden copies.
private struct CompactStatusBar: View {
    let bar: TopBar
    @State private var widths: [String: Double] = [:]
    @Environment(\.stage) private var stage
    @Environment(\.statusBarEdges) private var edges

    private static func key(_ step: StatusBarStep) -> String { "\(step)" }

    var body: some View {
        let sideLeft = StatusBarLayout.side + stage.safe.leading
        let sideRight = StatusBarLayout.side + stage.safe.trailing
        let buttons = bar.navigation?.buttons.count ?? 0
        let fit = StatusBarLayout.fit(width: stage.width, sideLeft: sideLeft, sideRight: sideRight) { step in
            StatusBarWidths(
                left: widths["left"] ?? 0,
                nav: StatusBarLayout.navWidth(buttons: buttons, button: StatusBarLayout.navButton, gap: StatusBarLayout.navGap),
                right: widths[Self.key(step)] ?? 0)
        }
        ZStack {
            left.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, stage.px(sideLeft))
            if let navigation = bar.navigation {
                TopNav(buttons: navigation.buttons, focus: navigation.focus, buttonSize: StatusBarLayout.navButton)
                    .padding(.leading, stage.px(fit.navX))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            cluster(fit.step)
                .onGeometryChange(for: Double.self) { stage.px(stage.width - sideRight) - $0.size.width } action: {
                    edges?.rightStart = $0
                }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, stage.px(sideRight))
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                measured(left, "left")
                ForEach(StatusBarStep.allCases, id: \.self) { step in measured(cluster(step), Self.key(step)) }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private var left: some View {
        HStack(spacing: 0) {
            BackButton(onBack: bar.onBack)
            if bar.brand {
                HStack(spacing: stage.px(18)) {
                    LogoMark()
                    if stage.width >= StatusBarLayout.narrowStage { Wordmark() }
                    if let pc = bar.pc { PcDot(name: pc.name, online: pc.online) }
                }
            }
        }
    }

    private func cluster(_ step: StatusBarStep) -> some View {
        StatusCluster(
            wifi: bar.wifi, battery: bar.battery, clock: bar.clock,
            gap: step.tight ? StatusBarLayout.statusGapTight : StatusBarLayout.statusGap,
            batteryGap: step.tight ? StatusBarLayout.batteryGapTight : StatusBarLayout.batteryGap, percent: step.percent)
    }

    private func measured(_ view: some View, _ key: String) -> some View {
        view.fixedSize()
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { widths[key] = $0 / stage.scale }
    }
}

/// Wi-Fi, the battery with its percentage and the clock, all in the text color, [gap] apart ([batteryGap] between the
/// battery and its percentage). The digits are of equal width, so the bar does not shift as the values change.
private struct StatusCluster: View {
    let wifi: WifiStatus
    let battery: BatteryStatus?
    let clock: ClockFormat
    var gap = StatusBarLayout.statusGap
    var batteryGap = StatusBarLayout.batteryGap
    var percent = true
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(gap)) {
            if let icon = wifi.icon { SymbolView(symbol: icon, size: 30, color: colors.text) }
            if let battery {
                HStack(spacing: stage.px(batteryGap)) {
                    BatteryIndicator(battery: battery)
                    if percent {
                        Text(verbatim: battery.percent)
                            .font(DelosFonts.figtree(stage.tpx(22), .semibold).monospacedDigit())
                            .foregroundStyle(colors.text.color)
                    }
                }
            }
            TimelineView(.everyMinute) { context in
                Text(verbatim: StatusClock.text(context.date, format: clock, locale: .autoupdatingCurrent))
                    .font(DelosFonts.figtree(stage.tpx(24), .semibold).monospacedDigit())
                    .foregroundStyle(colors.text.color)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The battery in the style of iOS (`BatteryIndicator` of DELOS for Android): a light outline with a small cap, filled
/// green to the charge level (red when low). While charging a bolt sits inside, the green pulses, and once a cycle a
/// ring goes out from the outline.
private struct BatteryIndicator: View {
    let battery: BatteryStatus
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// One charging cycle.
    static let period = 1.8
    /// `EaseOut` of DELOS for Android's motion: cubic-bezier(0.16, 1, 0.3, 1).
    static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let lowRed = RGBA(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    var body: some View {
        ZStack {
            if battery.charging {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                    canvas(phase: phase)
                }
                SymbolView(symbol: Symbols.bolt, size: 20, color: colors.text, filled: true)
                    .offset(x: -stage.px(2))
            } else {
                canvas(phase: nil)
            }
        }
        .frame(width: stage.px(48), height: stage.px(24))
    }

    /// [phase] 0...1 of the charging cycle; nil while not charging.
    private func canvas(phase: Double?) -> some View {
        let fill = battery.low ? Self.lowRed : RGBA.onlineGreen
        let pulse = phase.map { 0.55 + 0.45 * Self.easeOut.value(at: $0 < 0.5 ? $0 * 2 : (1 - $0) * 2) } ?? 1
        let wave = phase.map { Self.easeOut.value(at: ($0 + 0.5).truncatingRemainder(dividingBy: 1)) }
        // The ring of the pulse reaches 12 px outside the battery: the canvas has that margin on every side (it is
        // centered in the 48 × 24 box, which does not clip), else the ring was cut off at the box's edges
        let margin = 12 * stage.scale
        return Canvas { context, full in
            context.translateBy(x: margin, y: margin)
            let size = CGSize(width: full.width - 2 * margin, height: full.height - 2 * margin)
            let k = stage.scale
            let stroke = 2 * k
            let cap = 3 * k
            let body = CGSize(width: size.width - cap - 1.5 * k, height: size.height)
            func rounded(_ rect: CGRect, _ radius: Double) -> Path { Path(roundedRect: rect, cornerRadius: radius) }
            if let wave {
                let reach = (2 + 10 * wave) * k
                context.stroke(
                    rounded(CGRect(x: stroke / 2 - reach, y: stroke / 2 - reach, width: body.width - stroke + reach * 2,
                                   height: body.height - stroke + reach * 2), 7 * k + reach),
                    with: .color(RGBA.onlineGreen.opacity(0.7 * (1 - wave)).color), lineWidth: 1.5 * k)
            }
            // The outline and the cap on the right
            context.stroke(
                rounded(CGRect(x: stroke / 2, y: stroke / 2, width: body.width - stroke, height: body.height - stroke), 7 * k),
                with: .color(colors.text.opacity(colors.text.alpha * 0.9).color), lineWidth: stroke)
            context.fill(
                rounded(CGRect(x: body.width + 1.5 * k, y: size.height * 0.32, width: cap, height: size.height * 0.36), 1.5 * k),
                with: .color(colors.text.opacity(colors.text.alpha * 0.6).color))
            // The charge, inset from the outline
            let inset = stroke + 2 * k
            let inner = CGSize(width: body.width - inset * 2, height: body.height - inset * 2)
            context.fill(
                rounded(CGRect(x: inset, y: inset, width: inner.width * battery.fill, height: inner.height), 4 * k),
                with: .color(fill.opacity(pulse).color))
        }
        .frame(width: stage.px(48) + 2 * margin, height: stage.px(24) + 2 * margin)
    }
}

/// The connected PC beside the brand (`PcPill` of DELOS for Android); the dot is green while the PC is online.
private struct PcPill: View {
    let name: String
    let online: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(10)) {
            Circle().fill((online ? RGBA.onlineGreen : colors.text3).color).frame(width: stage.px(10), height: stage.px(10))
            Text(name)
                .font(DelosFonts.figtree(stage.tpx(20)))
                .foregroundStyle(colors.text2.color)
                .lineLimit(1)
        }
        .padding(.horizontal, stage.px(18))
        .padding(.vertical, stage.px(8))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// The connected PC on a compact stage (`PcDot` of DELOS for Android): its dot and the PC glyph in the pill of
/// ``PcPill``, without the name, which is what a screen reader says.
private struct PcDot: View {
    let name: String
    let online: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(9)) {
            Circle().fill((online ? RGBA.onlineGreen : colors.text3).color).frame(width: stage.px(10), height: stage.px(10))
            SymbolView(symbol: Symbols.desktopWindows, size: 24, color: colors.text2)
        }
        .padding(.horizontal, stage.px(14))
        .padding(.vertical, stage.px(8))
        .background {
            GlassShape(Capsule(), tint: colors.surface)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .accessibilityElement()
        .accessibilityLabel(online ? L("shell_side_connected", name) : L("shell_side_offline", name))
    }
}
