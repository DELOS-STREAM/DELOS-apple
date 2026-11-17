import DelosData
import DelosHost
import SwiftUI

// MARK: What the pairing screens show

/// The PCs on the pairing screen and their status lines (`PairPcScreen` of DELOS for Android). Status lines are string
/// names of the catalog.
enum PairList {
    /// Every known PC: found ones first (online before offline), paired ones after them, each group by name.
    static func shown(_ hosts: [HostRecord]) -> [HostRecord] {
        hosts.sorted {
            ($0.pin != nil ? 1 : 0, $0.reachability == .online ? 0 : 1, $0.name.lowercased())
                < ($1.pin != nil ? 1 : 0, $1.reachability == .online ? 0 : 1, $1.name.lowercased())
        }
    }

    /// The line under a PC on the pairing screen.
    static func status(_ host: HostRecord) -> String {
        let online = host.reachability == .online
        if host.pin != nil { return online ? "pairing_pc_paired_online" : "pairing_pc_paired_offline" }
        return online ? "pairing_pc_ready" : "pairing_pc_offline"
    }
}

/// What "Enter address" makes of the typed text.
enum AddressEntry: Equatable {
    case address(HostAddress)
    /// Nothing typed (`devices_address_required`).
    case empty
    /// Not an address (`devices_add_not_an_address`).
    case invalid

    init(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else if let typed = HostAddress.parse(text) {
            self = .address(typed.address())
        } else {
            self = .invalid
        }
    }
}

/// A one-time code from the PC's web UI (Android's `Otp`): its PIN and the passphrase it was made with.
public struct OneTimeCode: Hashable, Sendable {
    public let pin: String
    public let passphrase: String

    public init(pin: String, passphrase: String) {
        self.pin = pin
        self.passphrase = passphrase
    }

    static let pinLength = 4
    static let minPassphraseLength = 4
    static let maxPassphraseLength = 64

    /// What the dialog's two fields make of what was typed.
    enum Entry: Equatable {
        case code(OneTimeCode)
        /// The PIN is not four digits (`pairing_otp_pin_error`).
        case pinInvalid
        /// The passphrase is shorter than four characters (`pairing_otp_passphrase_error`).
        case passphraseTooShort

        init(pin: String, passphrase: String) {
            if pin.count != OneTimeCode.pinLength {
                self = .pinInvalid
            } else if passphrase.count < OneTimeCode.minPassphraseLength {
                self = .passphraseTooShort
            } else {
                self = .code(OneTimeCode(pin: pin, passphrase: passphrase))
            }
        }

        /// The string name of what is wrong; nil for a code.
        var errorKey: String? {
            switch self {
            case .code: nil
            case .pinInvalid: "pairing_otp_pin_error"
            case .passphraseTooShort: "pairing_otp_passphrase_error"
            }
        }
    }
}

/// Why a pairing did not happen (`PcSetup.PairFailure` of DELOS for Android, as far as it applies here).
enum PairFailure: Equatable {
    case offline, pinWrong, codeWrong, busy, gameRunning, notFound, unsupported, failed

    /// The failure of an attempt that ended with [outcome]; nil when it paired. [runningAppID] is the app the PC had
    /// running: a PC that refuses while an app runs wants it quit first. [oneTime]: the attempt used a one-time code, so a
    /// refused proof means the code or passphrase was wrong, not a PIN.
    init?(_ outcome: PairingOutcome, runningAppID: Int, oneTime: Bool = false) {
        switch outcome {
        case .paired: return nil
        case .pinWrong: self = oneTime ? .codeWrong : .pinWrong
        case .alreadyInProgress: self = .busy
        case .failed: self = runningAppID != 0 ? .gameRunning : .failed
        }
    }

    /// The failure of an attempt that threw [error].
    init(_ error: any Error) {
        switch error as? HostError {
        case .unreachable, .timedOut: self = .offline
        case .httpStatus(404): self = .unsupported
        default: self = .failed
        }
    }

    /// The string name of the message.
    var key: String {
        switch self {
        case .offline: "pairing_failed_offline"
        case .pinWrong: "pairing_failed_pin_wrong"
        case .codeWrong: "pairing_failed_code_wrong"
        case .busy: "pairing_failed_busy"
        case .gameRunning: "pairing_failed_game_running"
        case .notFound: "pairing_failed_not_found"
        case .unsupported: "pairing_failed_unsupported"
        case .failed: "pairing_failed"
        }
    }

    func text(pcName: String) -> String {
        self == .pinWrong || self == .codeWrong ? L(key) : L(key, pcName)
    }
}

// MARK: Screens

/// A row of circles in the middle of the stage; it scrolls sideways when they do not fit.
struct CircleRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage

    var body: some View {
        // The 40 px around the circles keep the ring and glow of the first and last from being cut where the row scrolls; they
        // take no room in the layout (Android's scroll area gives them back: `bleed`), so the heading keeps its distance
        let row = HStack(alignment: .top, spacing: stage.px(56)) { content() }.padding(stage.px(40)).padding(-stage.px(40))
            // One focus ring glides between the circles (`GlideRingHost(FocusRing(5, 5), focusScale = 1.16)`)
            .glideRingHost(focusScale: 1.16)
        ViewThatFits(in: .horizontal) {
            row
            FocusScroll(axis: .horizontal) { row }.scrollClipDisabled().focusable(false)
        }
    }
}

/// `#scr-pair`: the PCs DELOS knows in circles (found ones to pair, paired ones open their library), then entering an
/// address and searching again. Showing it starts looking for PCs.
struct PairPCScreen: View {
    let focus: FocusModel
    let onHost: @MainActor (HostRecord) -> Void
    /// "Pair with a one-time code" in the menu of a PC that is not paired yet.
    let onCode: @MainActor (HostRecord) -> Void
    let onAddress: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage
    @State private var searching = false

    /// The focus id of a PC's circle.
    static func hostFocusID(_ hostID: String) -> String { "host-\(hostID)" }

    /// The first focus when the screen opens: the first PC shown, else "Enter address".
    static func firstFocus(_ hosts: [HostRecord]) -> String {
        PairList.shown(hosts).first.map { hostFocusID($0.id) } ?? "address"
    }

    /// The menu of a PC that is not paired (`contextMenu` of Android's `PairPcScreen`): pair with the PIN or with a one-time
    /// code. A paired PC has none, A opens its library.
    static func menu(
        _ host: HostRecord, onPin: @escaping @MainActor (HostRecord) -> Void, onCode: @escaping @MainActor (HostRecord) -> Void
    ) -> ContextMenu? {
        guard host.pin == nil else { return nil }
        return ContextMenu(title: host.name, items: [
            MenuItem(icon: Symbols.dialpad, label: L("pairing_pc_with_pin")) { onPin(host) },
            MenuItem(icon: Symbols.password, label: L("pairing_pc_with_code")) { onCode(host) },
        ], below: true)
    }

    var body: some View {
        let shown = PairList.shown(hosts.hosts)
        VStack(spacing: stage.px(48)) {
            Heading(
                title: L("pairing_pc_title"),
                sub: searching ? L("pairing_pc_searching")
                    : shown.isEmpty ? L("pairing_pc_none") : L("pairing_pc_found", shown.count)
            )
            .staggerEntrance()
            CircleRow {
                ForEach(shown, id: \.id) { host in
                    FocusItem(
                        id: Self.hostFocusID(host.id), model: focus, menu: { Self.menu(host, onPin: onHost, onCode: onCode) },
                        action: { onHost(host) }
                    ) { focused in
                        CircleItem(
                            icon: Symbols.desktopWindows, label: host.name, meta: L(PairList.status(host)),
                            metaDot: host.reachability == .online ? .onlineGreen : nil, selected: host.pin != nil,
                            pulse: host.reachability == .online && host.pin == nil, focused: focused
                        )
                    }
                    .staggerEntrance()
                }
                FocusItem(id: "address", model: focus, action: onAddress) { focused in
                    CircleItem(icon: Symbols.addAddress, label: L("pairing_pc_address"), meta: L("pairing_pc_address_hint"), focused: focused)
                }
                .staggerEntrance()
                FocusItem(id: "search", model: focus, action: searchAgain) { focused in
                    CircleItem(icon: Symbols.refresh, label: L("pairing_pc_search_again"), meta: L("pairing_pc_network"), focused: focused)
                }
                .staggerEntrance()
            }
        }
        .entranceScope()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { hosts.startDiscovery() }
        .task(id: searching) {
            guard searching else { return }
            try? await Task.sleep(for: .seconds(3))
            searching = false
        }
    }

    private func searchAgain() {
        hosts.stopDiscovery()
        hosts.startDiscovery()
        searching = true
    }
}

/// `#scr-pin`: pairing with a PC. Shows the PIN to type in the PC's web UI (with a one-time [code]: no PIN is shown, the
/// code is sent), waits for the PC and moves on when it accepts. Leaving the screen cancels the attempt (and the PC is asked to forget it).
struct PinScreen: View {
    let hostID: String
    var code: OneTimeCode?
    let focus: FocusModel
    let feedback: Feedback?
    let onPaired: @MainActor () -> Void
    let onFailed: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var generatedPIN = HostStore.newPIN()
    @State private var accepted = false

    var body: some View {
        let name = hosts.host(hostID)?.name ?? ""
        VStack(spacing: stage.px(44)) {
            if code == nil {
                Heading(title: L("pairing_pin_title", name), sub: L("pairing_pin_note"))
                    .staggerEntrance()
                PinDigits(pin: generatedPIN)
            } else {
                Heading(title: L("pairing_code_title", name), sub: L("pairing_code_note"))
                    .staggerEntrance()
            }
            HStack(spacing: stage.px(16)) {
                if !accepted { Spinner() }
                Text(accepted ? L(code == nil ? "pairing_pin_accepted" : "pairing_code_accepted") : L("pairing_pin_waiting"))
                    .font(DelosFonts.figtree(stage.tpx(26)))
                    .foregroundStyle(accepted ? RGBA.onlineGreen.color : colors.text2.color)
            }
            FocusItem(id: "cancel", model: focus, action: onCancel) { focused in
                PillButton(label: L("pairing_cancel"), icon: Symbols.close, focused: focused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .entranceScope()
        .task { await pair() }
    }

    private func pair() async {
        // A PC that was just added may take a moment to show up (`awaitPc(…, 5_000)` of Android's `PinScreen`)
        var known = hosts.host(hostID)
        for _ in 0..<50 where known == nil {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            known = hosts.host(hostID)
        }
        guard let host = known else {
            onFailed(PairFailure.notFound.text(pcName: ""))
            return
        }
        guard host.reachability == .online else {
            onFailed(PairFailure.offline.text(pcName: host.name))
            return
        }
        let failure: PairFailure?
        do {
            let outcome = try await hosts.pair(hostID, pin: code?.pin ?? generatedPIN, passphrase: code?.passphrase)
            failure = PairFailure(outcome, runningAppID: host.runningAppID, oneTime: code != nil)
        } catch {
            failure = PairFailure(error)
        }
        // Left the screen: the attempt was cancelled, nothing to report
        guard !Task.isCancelled else { return }
        if let failure {
            onFailed(failure.text(pcName: host.name))
            return
        }
        accepted = true
        feedback?.play(.select)
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        onPaired()
    }
}

/// `.pin`: the four digits, each springing in a little after the one before.
private struct PinDigits: View {
    let pin: String
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var shown = false

    var body: some View {
        // A compact stage makes the digit boxes up to 20 % smaller (the digits keep their size)
        let ds = stage.compact ? max(stage.compactScale, 0.8) : 1
        HStack(spacing: stage.px(26 * ds)) {
            ForEach(Array(pin.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(DelosFonts.unbounded(stage.tpx(92)))
                    .foregroundStyle(colors.text.color)
                    .frame(width: stage.px(148 * ds), height: stage.px(176 * ds))
                    .background {
                        GlassShape(RoundedRectangle(cornerRadius: stage.px(32)), tint: colors.surface2, role: .panel)
                            .overlay(RoundedRectangle(cornerRadius: stage.px(32)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                    }
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.8)
                    .offset(y: shown ? 0 : stage.px(30))
                    .animation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.7).delay(0.08 * Double(index)), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

/// `.spinner`: a 30 px ring with an accent quarter, a turn every 0.9 s.
struct Spinner: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().stroke(colors.line.color, lineWidth: stage.px(4))
                Circle().trim(from: 0, to: 0.25)
                    .stroke(colors.accent.color, lineWidth: stage.px(4))
                    .rotationEffect(.degrees(turn - 135))
            }
            .padding(stage.px(2))
            .frame(width: stage.px(30), height: stage.px(30))
        }
    }
}
