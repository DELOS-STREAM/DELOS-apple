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

/// Why a pairing did not happen (`PcSetup.PairFailure` of DELOS for Android, as far as it applies here).
enum PairFailure: Equatable {
    case offline, pinWrong, busy, gameRunning, notFound, unsupported, failed

    /// The failure of an attempt that ended with [outcome]; nil when it paired. [runningAppID] is the app the PC had
    /// running: a PC that refuses while an app runs wants it quit first.
    init?(_ outcome: PairingOutcome, runningAppID: Int) {
        switch outcome {
        case .paired: return nil
        case .pinWrong: self = .pinWrong
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
        case .busy: "pairing_failed_busy"
        case .gameRunning: "pairing_failed_game_running"
        case .notFound: "pairing_failed_not_found"
        case .unsupported: "pairing_failed_unsupported"
        case .failed: "pairing_failed"
        }
    }

    func text(pcName: String) -> String {
        self == .pinWrong ? L(key) : L(key, pcName)
    }
}

// MARK: Screens

/// A row of circles in the middle of the stage; it scrolls sideways when they do not fit.
struct CircleRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.stage) private var stage

    var body: some View {
        let row = HStack(alignment: .top, spacing: stage.px(56)) { content() }.padding(stage.px(40))
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }.scrollClipDisabled()
        }
    }
}

/// `#scr-pair`: the PCs DELOS knows in circles (found ones to pair, paired ones open their library), then entering an
/// address and searching again. Showing it starts looking for PCs.
struct PairPCScreen: View {
    let focus: FocusModel
    let onHost: @MainActor (HostRecord) -> Void
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

    var body: some View {
        let shown = PairList.shown(hosts.hosts)
        VStack(spacing: stage.px(48)) {
            Heading(
                title: L("pairing_pc_title"),
                sub: searching ? L("pairing_pc_searching")
                    : shown.isEmpty ? L("pairing_pc_none") : L("pairing_pc_found", shown.count)
            )
            CircleRow {
                ForEach(shown, id: \.id) { host in
                    FocusItem(id: Self.hostFocusID(host.id), model: focus, action: { onHost(host) }) { focused in
                        CircleItem(
                            icon: Symbols.desktopWindows, label: host.name, meta: L(PairList.status(host)),
                            metaDot: host.reachability == .online ? .onlineGreen : nil, selected: host.pin != nil, focused: focused
                        )
                    }
                }
                FocusItem(id: "address", model: focus, action: onAddress) { focused in
                    CircleItem(icon: Symbols.addAddress, label: L("pairing_pc_address"), meta: L("pairing_pc_address_hint"), focused: focused)
                }
                FocusItem(id: "search", model: focus, action: searchAgain) { focused in
                    CircleItem(icon: Symbols.refresh, label: L("pairing_pc_search_again"), meta: L("pairing_pc_network"), focused: focused)
                }
            }
        }
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

/// Entering a PC's address (the address dialog of DELOS for Android): the field and "Add PC".
struct PairAddressScreen: View {
    let focus: FocusModel
    let navigator: Navigator
    let onSubmit: @MainActor (String) -> Void
    @Environment(\.stage) private var stage
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: stage.px(48)) {
            Heading(title: L("devices_address_title"), sub: L("devices_address_note"))
            FocusItem(id: "field", model: focus, moves: [.down: "add"], action: { typing = true }) { focused in
                TextPill(
                    label: L("pairing_pc_address_hint"), icon: Symbols.mapPin, placeholder: "192.168.1.20", text: $text,
                    editing: $typing, focused: focused, address: true, onSubmit: { focus.focus("add") }
                )
            }
            FocusItem(id: "add", model: focus, moves: [.up: "field"], action: { onSubmit(text) }) { focused in
                PillButton(label: L("devices_address_action"), icon: Symbols.addLink, primary: true, focused: focused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: typing) { _, now in navigator.isEditingText = now }
        .onChange(of: navigator.isEditingText) { _, now in if !now { typing = false } }
        .onAppear { typing = true }
    }
}

/// `#scr-pin`: pairing with a PC. Shows the PIN to type in the PC's web UI, waits for the PC and moves on when it
/// accepts. Leaving the screen cancels the attempt (and the PC is asked to forget it).
struct PinScreen: View {
    let hostID: String
    let focus: FocusModel
    let feedback: Feedback?
    let onPaired: @MainActor () -> Void
    let onFailed: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @State private var pin = HostStore.newPIN()
    @State private var accepted = false

    var body: some View {
        let name = hosts.host(hostID)?.name ?? ""
        VStack(spacing: stage.px(44)) {
            Heading(title: L("pairing_pin_title", name), sub: L("pairing_pin_note"))
            PinDigits(pin: pin)
            HStack(spacing: stage.px(16)) {
                if !accepted { Spinner() }
                Text(accepted ? L("pairing_pin_accepted") : L("pairing_pin_waiting"))
                    .font(DelosFonts.figtree(stage.px(26)))
                    .foregroundStyle(accepted ? RGBA.onlineGreen.color : colors.text2.color)
            }
            FocusItem(id: "cancel", model: focus, action: onCancel) { focused in
                PillButton(label: L("pairing_cancel"), icon: Symbols.close, focused: focused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await pair() }
    }

    private func pair() async {
        guard let host = hosts.host(hostID) else {
            onFailed(PairFailure.notFound.text(pcName: ""))
            return
        }
        guard host.reachability == .online else {
            onFailed(PairFailure.offline.text(pcName: host.name))
            return
        }
        let failure: PairFailure?
        do {
            failure = PairFailure(try await hosts.pair(hostID, pin: pin), runningAppID: host.runningAppID)
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
        HStack(spacing: stage.px(26)) {
            ForEach(Array(pin.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(DelosFonts.unbounded(stage.px(92)))
                    .foregroundStyle(colors.text.color)
                    .frame(width: stage.px(148), height: stage.px(176))
                    .background {
                        GlassShape(RoundedRectangle(cornerRadius: stage.px(32)), tint: colors.surface2, role: .panel)
                            .overlay(RoundedRectangle(cornerRadius: stage.px(32)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                    }
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.8)
                    .offset(y: shown ? 0 : stage.px(30))
                    .animation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.08 * Double(index)), value: shown)
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
