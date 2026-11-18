import DelosData
import DelosHost
import DelosInput
import SwiftUI

/*
 * The PC and library pages of the companion screen (`CompanionPcData.kt`, `CompanionPcPage.kt` and
 * `CompanionPcPublisher.kt` of DELOS for Android, docs/DUAL_SCREEN.md §8 "PC and library pages"): the focused PC as a card
 * with its facts and touch buttons (Start, Devices, Pair a PC, an offline library), a found PC that is not paired, the
 * pairing steps (the PIN in huge digits, the one-time code, the result) and the library states without games. The data
 * and its decisions are pure (``CompanionPcCard``); the buttons run the same ``ShellActions`` paths as the controller's
 * menus.
 */

// MARK: - Data

/// How a PC is doing (`PcStatus`): online, asleep (offline with a MAC address, so it can be woken) or offline.
enum CompanionPcStatus: Hashable, Sendable { case online, asleep, offline }

/// The streaming host software as far as the host's answers tell it (`HostSoftware`).
enum CompanionHostSoftware: Hashable, Sendable { case vibepollo, geforce, sunshine }

/// The screen a PC card is published for (`PcContext`): it decides the buttons.
enum CompanionPcContext: Hashable, Sendable { case start, devices, pair, home }

/// What the card of one PC knows (`PcCardData`, CompanionPcData.kt:27-55), taken from what the shell already has; what the
/// app does not know stays nil and is shown as unavailable.
struct CompanionPcData: Hashable, Sendable {
    let id: String
    let name: String
    /// The name the PC reports itself.
    let serverName: String
    let status: CompanionPcStatus
    /// A MAC address is saved: Wake-on-LAN is possible.
    let canWake: Bool
    /// Whether this is the default PC; nil where the screen does not know (the library).
    let isDefault: Bool?
    let connected: Bool
    let software: CompanionHostSoftware?
    /// The applications of the library the shell holds of this PC, nil when it holds none.
    let apps: Int?
    /// The count comes from the stored app list of a PC that does not answer now.
    let appsCached: Bool
    /// The host says a game runs.
    let busy: Bool
    let runningGame: String?

    var online: Bool { status == .online }
}

/// The facts of a PC card (`PcFactKind`).
enum CompanionPcFact: Hashable, Sendable { case flags, host, version, hostName, library, session, wake, lastSeen }

/// The touch buttons of the first row (`PcActionKind`).
enum CompanionPcAction: Hashable, Sendable { case library, wake, search, rename, defaultOn, defaultOff }

/// The destructive buttons, set apart below a rule (`PcDangerKind`).
enum CompanionPcDanger: Hashable, Sendable { case unpair, remove }

struct CompanionPcActionSet: Equatable, Sendable {
    let primary: [CompanionPcAction]
    let separated: [CompanionPcDanger]
}

/// The pure decisions of a PC card (`PcCard`, CompanionPcData.kt:66-170).
enum CompanionPcCard {
    static func status(online: Bool, canWake: Bool) -> CompanionPcStatus { online ? .online : canWake ? .asleep : .offline }

    static func status(_ host: HostRecord) -> CompanionPcStatus { status(online: host.reachability == .online, canWake: host.macAddress != nil) }

    /// The host software (`software`): GeForce Experience announces itself, anything else that answered is Sunshine or built
    /// on it; nil for a PC that does not answer. DELOS for Apple does not read the PyroWave fields Android tells a
    /// Vibepollo by, so it never claims Vibepollo.
    static func software(online: Bool, nvidia: Bool) -> CompanionHostSoftware? {
        guard online else { return nil }
        return nvidia ? .geforce : .sunshine
    }

    /// The card of one PC (`of`): [libraryHostID] is the PC whose library the shell holds and [apps] the app list stored
    /// for this PC, the source of the count and of the running game's name.
    static func make(
        id: String, name: String, serverName: String, online: Bool, canWake: Bool, nvidia: Bool, runningAppID: Int, defaultID: String?,
        libraryHostID: String?, apps: [HostApp]?, defaultKnown: Bool = true
    ) -> CompanionPcData {
        let ready = libraryHostID == id ? apps : nil
        return CompanionPcData(
            id: id, name: name, serverName: serverName, status: status(online: online, canWake: canWake), canWake: canWake,
            isDefault: defaultKnown ? id == defaultID : nil, connected: online && libraryHostID == id, software: software(online: online, nvidia: nvidia),
            apps: ready?.count, appsCached: ready != nil && !online, busy: online && runningAppID != 0,
            runningGame: online && runningAppID != 0 ? ready?.first { $0.id == runningAppID }?.title : nil)
    }

    static func of(_ host: HostRecord, defaultID: String?, libraryHostID: String?, apps: [HostApp]?, defaultKnown: Bool = true) -> CompanionPcData {
        make(
            id: host.id, name: host.name, serverName: host.serverName, online: host.reachability == .online, canWake: host.macAddress != nil,
            nvidia: host.isNvidiaServer, runningAppID: host.runningAppID, defaultID: defaultID, libraryHostID: libraryHostID, apps: apps,
            defaultKnown: defaultKnown)
    }

    /// The facts in display order (`facts`): the known ones first, the unknown after them; the host name only when the user
    /// named the PC differently.
    static func facts(_ d: CompanionPcData) -> [CompanionPcFact] {
        let order: [CompanionPcFact] = d.online
            ? [.flags, .host, .library, .session, .hostName, .lastSeen, .version]
            : [.flags, .library, .wake, .hostName, .lastSeen, .host, .session, .version]
        let shown = order.filter { $0 != .hostName || (!d.serverName.trimmingCharacters(in: .whitespaces).isEmpty && d.serverName != d.name) }
        return shown.filter { known(d, $0) } + shown.filter { !known(d, $0) }
    }

    /// Whether the app has a value for [kind] (`known`).
    static func known(_ d: CompanionPcData, _ kind: CompanionPcFact) -> Bool {
        switch kind {
        case .flags: d.isDefault != nil || d.connected
        case .hostName, .wake: true
        case .host: d.software != nil
        case .library: d.apps != nil
        case .session, .lastSeen: d.online
        case .version: false
        }
    }

    /// The first [max] facts that [fits] (`select`); a fact that does not fit is left out, never cut.
    static func select(_ facts: [CompanionPcFact], max: Int, fits: (CompanionPcFact) -> Bool) -> [CompanionPcFact] {
        Array(facts.filter(fits).prefix(max))
    }

    /// The buttons of a card (`actions`): the way in (Library online, Wake with a MAC, else Search), Rename and, outside the
    /// library, Set/Clear default; apart: Unpair on Devices for an online PC, Remove on Start and Devices.
    static func actions(_ d: CompanionPcData, context: CompanionPcContext) -> CompanionPcActionSet {
        var primary: [CompanionPcAction] = [d.online ? .library : d.canWake ? .wake : .search, .rename]
        if context != .home { primary.append(d.isDefault == true ? .defaultOff : .defaultOn) }
        let separated: [CompanionPcDanger] = switch context {
        case .start: [.remove]
        case .devices: d.online ? [.unpair, .remove] : [.remove]
        case .pair, .home: []
        }
        return CompanionPcActionSet(primary: primary, separated: separated)
    }

    /// How many buttons share a row (`buttonsPerRow`): as many as fit with the widest label on one line, at least one.
    static func buttonsPerRow(_ widths: [Double], available: Double, gap: Double, padding: Double) -> Int {
        guard let widest = widths.max().map({ $0 + padding }) else { return 1 }
        var n = widths.count
        while n >= 2 {
            if (available - gap * Double(n - 1)) / Double(n) >= widest { return n }
            n -= 1
        }
        return 1
    }

    /// The one hint of the main screen the card quotes (the first with a button letter; [keys] holds each hint's letter)
    /// and how many more there are (`mainHint`).
    static func mainHint(_ hints: [CompanionHint], keys: [String?]) -> (hint: CompanionHint, key: String, rest: Int)? {
        for (hint, key) in zip(hints, keys) {
            if let key { return (hint, key, hints.count - 1) }
        }
        return nil
    }

    /// The letter of a controller button of the hint bar; nil for touch and keys.
    @MainActor
    static func buttonLetter(_ hint: CompanionHint) -> String? {
        if case .pad(let role) = hint.button { return ControllerGlyphs.shared.mark(role).text }
        return nil
    }

    /// The id after [prefix] of a focus id ("pc-<id>", "host-<id>"); nil when something else is focused.
    static func focusedID(_ focused: AnyHashable?, prefix: String) -> String? {
        guard let id = focused?.base as? String, id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}

/// The size of a pairing PIN's digits (`PinFit`): as large as the box allows by width and height, never wider.
enum CompanionPinFit {
    static func fontSize(boxWidth: Double, boxHeight: Double, widthAtRef: Double, ref: Double, lineRatio: Double = 1.2) -> Double {
        guard widthAtRef > 0, boxWidth > 0, boxHeight > 0 else { return 0 }
        return min(boxWidth * ref / widthAtRef, boxHeight / lineRatio)
    }
}

// MARK: - Shared drawing

/// The side padding of a button, the gap between buttons and the slack for the semi-bold face (CompanionPcPage.kt:154-157).
private enum PcButtons {
    static let padding = 44.0
    static let gap = 8.0
    static let slack = 1.12

    /// [actions] in rows of as many as fit (`chunked(perRow)`).
    static func rows(_ actions: [PageAction], fit: CompanionFitContext) -> [[PageAction]] {
        let perRow = CompanionPcCard.buttonsPerRow(
            actions.map { fit.metrics.width($0.label) * slack }, available: fit.budget.innerWidth, gap: gap, padding: padding)
        return stride(from: 0, to: actions.count, by: perRow).map { Array(actions[$0..<min($0 + perRow, actions.count)]) }
    }
}

/// [full] when it fits one line of [width], else [short] (`oneLine`).
private func oneLine(_ full: String, _ short: String, width: Double, fit: CompanionFitContext) -> String {
    fit.metrics.width(full) <= width ? full : short
}

/// The title of a card: the PC's name when it fits one line, else "PC · 7C2A" (`pcTitle`).
private func pcTitle(_ name: String, id: String, fit: CompanionFitContext) -> String {
    CompanionFit.title(name, alias: CompanionFit.alias(L("pc_alias_prefix"), id: id), width: fit.budget.innerWidth - PageHeading.chrome, metrics: fit.metrics)
}

private func statusLabel(_ status: CompanionPcStatus) -> String {
    switch status {
    case .online: L("devices_status_online")
    case .asleep: L("devices_status_asleep_wakes")
    case .offline: L("devices_status_offline")
    }
}

private func softwareName(_ software: CompanionHostSoftware) -> String {
    switch software {
    case .vibepollo: L("pc_host_vibepollo")
    case .geforce: L("pc_host_geforce")
    case .sunshine: L("pc_host_sunshine")
    }
}

/// The hints of the main hint bar as the shell publishes them for the fallback card.
@MainActor
private var mainHints: [CompanionHint] { CompanionHub.shared.context?.hints ?? [] }

// MARK: - PC card

/// What the buttons of a PC card run (`PcCallbacks`): the ``ShellActions`` paths of the controller's menus, on this PC.
struct CompanionPcCalls {
    let connect: @MainActor () -> Void
    let wake: @MainActor () -> Void
    let rescan: @MainActor () -> Void
    let rename: @MainActor () -> Void
    let setDefault: @MainActor () -> Void
    let clearDefault: @MainActor () -> Void
    let unpair: @MainActor () -> Void
    let remove: @MainActor () -> Void

    @MainActor
    static func of(_ hostID: String, actions: ShellActions) -> CompanionPcCalls {
        CompanionPcCalls(
            connect: { actions.connect(hostID) }, wake: { actions.wake(hostID) },
            rescan: {
                actions.hosts.stopDiscovery()
                actions.hosts.startDiscovery()
            },
            rename: { actions.rename(hostID) }, setDefault: { actions.setDefault(actions.hosts.host(hostID)) }, clearDefault: { actions.setDefault(nil) },
            unpair: { actions.unpair(hostID) }, remove: { actions.remove(hostID) })
    }
}

/// The card of one PC (`PcPage`, CompanionPcPage.kt:70-152): name, status, facts, the buttons for its status, the
/// destructive ones apart and the hint of the main screen.
enum CompanionPcPage {
    struct Shown: Hashable {
        let data: CompanionPcData
        let context: CompanionPcContext
        let hints: [CompanionHint]
    }

    static func page(_ data: CompanionPcData, context: CompanionPcContext, hints: [CompanionHint], calls: CompanionPcCalls) -> CompanionPage {
        CompanionPage(key: "pc/\(data.id)", revision: Shown(data: data, context: context, hints: hints)) {
            CompanionPcCardView(data: data, context: context, hints: hints, calls: calls)
        }
    }

    /// The card of [host] for [context] with [actions]' paths (`rememberPcPage`); the library's card has no hint line and
    /// does not know the default PC.
    @MainActor
    static func page(_ host: HostRecord, context: CompanionPcContext, actions: ShellActions) -> CompanionPage {
        let data = CompanionPcCard.of(
            host, defaultID: actions.profiles.startup.defaultPC, libraryHostID: actions.libraryHostID, apps: actions.hosts.apps[host.id],
            defaultKnown: context != .home)
        return page(data, context: context, hints: context == .home ? [] : mainHints, calls: .of(host.id, actions: actions))
    }
}

private struct CompanionPcCardView: View {
    let data: CompanionPcData
    let context: CompanionPcContext
    let hints: [CompanionHint]
    let calls: CompanionPcCalls
    @Environment(\.delosColors) private var colors

    var body: some View {
        let status = statusLabel(data.status)
        let eyebrow = switch context {
        case .devices: L("pc_eyebrow_devices", status)
        case .home: L("pc_eyebrow_library", status)
        case .start, .pair: L("pc_eyebrow_focused", status)
        }
        let facts = CompanionPcCard.facts(data).map { ($0, Self.fact($0, data)) }
        let set = CompanionPcCard.actions(data, context: context)
        let primary = set.primary.map { primaryAction($0) }
        let separated = set.separated.map { dangerAction($0) }
        let hint = CompanionPcCard.mainHint(hints, keys: hints.map { CompanionPcCard.buttonLetter($0) }).map { found -> (String, String) in
            let bare = L("pc_main_hint", found.key, found.hint.label)
            return (found.rest > 0 ? pluralFormat("pc_main_hint_more", found.key, found.hint.label, found.rest) : bare, bare)
        }
        PageCard { fit in
            let b = fit.budget
            let width = b.innerWidth
            PageHeading(icon: Symbols.desktopWindows, title: pcTitle(data.name, id: data.id, fit: fit), subtitle: oneLine(eyebrow, status, width: width - PageHeading.chrome, fit: fit))
            let column = (width - 24) / 2
            let shown = CompanionPcCard.select(facts.map(\.0), max: b.facts) { kind in
                facts.first { $0.0 == kind }.map { fit.metrics.width($0.1.value) <= column } ?? false
            }
            if !shown.isEmpty {
                FactsGrid(facts: shown.compactMap { kind in facts.first { $0.0 == kind }?.1 }, roomy: b.roomy).optional(40)
            }
            Filler()
            if !data.online, !data.canWake {
                BodyText(
                    CompanionFit.summary(
                        L("pc_no_mac_note"), short: L("pc_no_mac_short"), maxLines: b.bodyLines, width: width, metrics: fit.metrics,
                        last: L("companion_see_main")), color: colors.text2)
                    .optional(55)
            }
            ForEach(Array(PcButtons.rows(primary, fit: fit).enumerated()), id: \.offset) { _, row in ActionRow(actions: row) }
            if !separated.isEmpty {
                let together = separated.reduce(0) { $0 + fit.metrics.width($1.label) * PcButtons.slack + PcButtons.padding }
                    + PcButtons.gap * Double(separated.count - 1) <= width
                if together {
                    SeparatedActions(actions: separated)
                } else {
                    SeparatedActions(actions: Array(separated.prefix(1)))
                    ActionRow(actions: Array(separated.dropFirst()))
                }
            }
            if let hint { BodyText(oneLine(hint.0, hint.1, width: width, fit: fit), color: colors.text3, maxLines: 1).optional(30) }
        }
    }

    private func primaryAction(_ kind: CompanionPcAction) -> PageAction {
        switch kind {
        case .library: PageAction(label: L("pc_action_library"), style: .primary, run: calls.connect)
        case .wake: PageAction(label: L("pc_action_wake"), style: .primary, run: calls.wake)
        case .search: PageAction(label: L("pc_action_search"), style: .primary, run: calls.rescan)
        case .rename: PageAction(label: L("devices_menu_rename"), run: calls.rename)
        case .defaultOn: PageAction(label: L("pc_action_default_on"), run: calls.setDefault)
        case .defaultOff: PageAction(label: L("pc_action_default_off"), run: calls.clearDefault)
        }
    }

    private func dangerAction(_ kind: CompanionPcDanger) -> PageAction {
        switch kind {
        case .unpair: PageAction(label: L("devices_menu_unpair"), style: .danger, run: calls.unpair)
        case .remove: PageAction(label: L("pc_action_remove"), style: .danger, run: calls.remove)
        }
    }

    /// Label and value of one fact (`pcFacts`).
    static func fact(_ kind: CompanionPcFact, _ d: CompanionPcData) -> (label: String, value: String) {
        switch kind {
        case .flags:
            let value = if d.isDefault == nil && !d.connected {
                L("pc_unknown_flags")
            } else if d.isDefault == true && d.connected {
                L("devices_status_with_default", L("devices_status_connected"), L("devices_status_default"))
            } else if d.connected {
                L("devices_status_connected")
            } else if d.isDefault == true {
                L("pc_flags_default")
            } else {
                L("pc_flags_none")
            }
            return (L("pc_fact_flags"), value)
        case .host: return (L("pc_fact_host"), d.software.map(softwareName) ?? L("pc_unknown_host"))
        case .version: return (L("pc_fact_version"), L("pc_unknown_version"))
        case .hostName: return (L("pc_fact_host_name"), d.serverName)
        case .library:
            let value = d.apps.map { d.appsCached ? LPlural("pc_apps_cached", $0) : LPlural("pc_apps", $0) } ?? L("pc_unknown_library")
            return (L("pc_fact_library"), value)
        case .session:
            let value = !d.online ? L("pc_unknown_session")
                : d.runningGame.map { L("companion_host_running", $0) } ?? (d.busy ? L("pc_session_busy") : L("pc_session_idle"))
            return (L("pc_fact_session"), value)
        case .wake: return (L("pc_fact_wake"), d.canWake ? L("pc_wake_saved") : L("pc_wake_none"))
        case .lastSeen: return (L("pc_fact_last_seen"), d.online ? L("pc_value_now") : L("pc_unknown_last_seen"))
        }
    }
}

/// A plural string whose count is not its first argument ("Main: %1$@ %2$@ · %3$d more hints"): ``LPlural`` puts the count
/// first, so the arguments go in as they are and the count among them picks the plural form.
private func pluralFormat(_ name: String, _ arguments: any CVarArg...) -> String {
    return String(format: Bundle.module.localizedString(forKey: name, value: nil, table: nil), locale: .current, arguments: arguments)
}

// MARK: - Pairing

/// A found PC that is not paired (`PairHostPage`, CompanionPcPage.kt:200-226): its status, its software and the two ways
/// to pair, running the screen's own menu entries.
enum CompanionPairHostPage {
    struct Shown: Hashable {
        let id: String
        let name: String
        let online: Bool
        let software: CompanionHostSoftware?
    }

    static func page(_ shown: Shown, onPin: @escaping @MainActor () -> Void, onCode: @escaping @MainActor () -> Void) -> CompanionPage {
        CompanionPage(key: "pair/host/\(shown.id)", revision: shown) { CompanionPairHostCard(shown: shown, onPin: onPin, onCode: onCode) }
    }
}

private struct CompanionPairHostCard: View {
    let shown: CompanionPairHostPage.Shown
    let onPin: @MainActor () -> Void
    let onCode: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            PageHeading(
                icon: Symbols.addLink, title: pcTitle(shown.name, id: shown.id, fit: fit),
                subtitle: oneLine(L("pair_eyebrow_host"), L("pairing_pc_title"), width: fit.budget.innerWidth - PageHeading.chrome, fit: fit))
            BodyText(L(shown.online ? "pair_host_online" : "pair_host_offline"))
            if let software = shown.software { BodyText(L("pair_host_software", softwareName(software)), color: colors.text2).optional(50) }
            Filler()
            let actions = [
                PageAction(label: L("pairing_pc_with_pin"), style: .primary, run: onPin), PageAction(label: L("pair_action_code"), run: onCode),
            ]
            ForEach(Array(PcButtons.rows(actions, fit: fit).enumerated()), id: \.offset) { _, row in ActionRow(actions: row) }
        }
    }
}

/// What the "Enter address" and "Search again" circles do (`PairInfoPage`, CompanionPcPage.kt:228-262).
enum CompanionPairInfoPage {
    static func page(address: Bool, onSearch: @escaping @MainActor () -> Void) -> CompanionPage {
        let hints = [CompanionHint(button: .pad(.south), label: L("pairing_pc_address"))]
        return CompanionPage(key: "pair/info/\(address ? "address" : "search")", revision: [AnyHashable(address), AnyHashable(hints)]) {
            CompanionPairInfoCard(address: address, hints: hints, onSearch: onSearch)
        }
    }
}

private struct CompanionPairInfoCard: View {
    let address: Bool
    let hints: [CompanionHint]
    let onSearch: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            PageHeading(
                icon: address ? Symbols.addAddress : Symbols.refresh, title: L(address ? "pairing_pc_address" : "pairing_pc_search_again"),
                subtitle: L("pairing_pc_title"))
            let full = L(address ? "pair_address_note" : "pair_search_note")
            BodyText(
                CompanionFit.summary(
                    full, short: address ? L("pair_address_short") : full, maxLines: b.bodyLines, width: b.innerWidth, metrics: fit.metrics,
                    last: L("companion_see_main")), color: colors.text2)
            Filler()
            if address {
                let top = CompanionFit.top(hints, 1)
                if !top.shown.isEmpty { HintList(hints: top.shown, rest: top.rest).optional(50) }
            } else {
                ActionRow(actions: [PageAction(label: L("pairing_pc_search_again"), style: .primary, icon: Symbols.refresh, run: onSearch)])
            }
        }
    }
}

/// The PIN of a pairing in digits as large as the card allows, the instruction and Cancel, the screen's own cancel
/// (`PinPage`, CompanionPcPage.kt:264-292). The PIN is on the page only while the pairing screen shows it.
enum CompanionPinPage {
    static func page(id: String, pcName: String, pin: String, onCancel: @escaping @MainActor () -> Void) -> CompanionPage {
        CompanionPage(key: "pair/pin/\(id)", revision: [id, pcName, pin]) { CompanionPinCard(id: id, pcName: pcName, pin: pin, onCancel: onCancel) }
    }
}

private struct CompanionPinCard: View {
    let id: String
    let pcName: String
    let pin: String
    let onCancel: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            let alias = CompanionFit.alias(L("pc_alias_prefix"), id: id)
            PageHeading(
                icon: Symbols.dialpad,
                title: CompanionFit.title(
                    L("pair_pin_title", pcName), alias: L("pair_pin_title", alias), width: b.innerWidth - PageHeading.chrome, metrics: fit.metrics),
                subtitle: L("pair_pin_eyebrow"))
            BodyText(
                CompanionFit.summary(
                    L("pairing_pin_note"), short: L("pair_pin_short"), maxLines: 2, width: b.innerWidth, metrics: fit.metrics,
                    last: L("companion_see_main")), color: colors.text2)
            CompanionPinDigits(pin: pin, widthAtRef: fit.metrics.width(pin, kind: .title) * Self.tracking)
                .fills(minHeight: stage.px(120))
            ActionRow(actions: [PageAction(label: L("pair_cancel_action"), icon: Symbols.close, run: onCancel)])
        }
    }

    /// The digits are set with 0.12 em of tracking, which the measured width of the title face does not have.
    static let tracking = 1.12
}

/// The digits on one line, scaled to the box they get (`PinDigits`): never wrapped, never wider than the box.
private struct CompanionPinDigits: View {
    let pin: String
    /// The PIN's width at ``CompanionFit/titleSize`` in fit pixels.
    let widthAtRef: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(28), style: .continuous)
        GeometryReader { proxy in
            let unit = stage.scale * stage.textScale
            let size = CompanionPinFit.fontSize(
                boxWidth: proxy.size.width / unit - 48, boxHeight: proxy.size.height / unit - 48, widthAtRef: widthAtRef, ref: CompanionFit.titleSize)
            ZStack {
                if size > 0 {
                    Text(verbatim: pin)
                        .font(DelosFonts.unbounded(CGFloat(size * unit)).monospacedDigit())
                        .tracking(CGFloat(size * unit * 0.12))
                        .foregroundStyle(colors.accent.color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(shape.fill(colors.surface3.color))
        .overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
    }
}

/// A one-time-code pairing (`CodePage`, CompanionPcPage.kt:318-341): the instruction and the promise that the passphrase is
/// never shown here; the hints are the main screen's own.
enum CompanionCodePage {
    static func page(id: String, pcName: String, hints: [CompanionHint]) -> CompanionPage {
        CompanionPage(key: "pair/code/\(id)", revision: [AnyHashable(id), AnyHashable(pcName), AnyHashable(hints)]) {
            CompanionCodeCard(id: id, pcName: pcName, hints: hints)
        }
    }
}

private struct CompanionCodeCard: View {
    let id: String
    let pcName: String
    let hints: [CompanionHint]
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            PageHeading(
                icon: Symbols.password, title: L("pair_code_title"),
                subtitle: CompanionFit.title(
                    pcName, alias: CompanionFit.alias(L("pc_alias_prefix"), id: id), width: b.innerWidth - PageHeading.chrome, metrics: fit.metrics))
            BodyText(
                CompanionFit.summary(
                    L("pair_code_text"), short: L("pair_code_short"), maxLines: b.bodyLines, width: b.innerWidth, metrics: fit.metrics,
                    last: L("companion_see_main")), color: colors.text2)
            BodyText(L("pair_code_privacy"), color: colors.accent)
            Filler()
            let top = CompanionFit.top(hints, min(b.hints, 2))
            if !top.shown.isEmpty { HintList(hints: top.shown, rest: top.rest).optional(50) }
        }
    }
}

/// The PC accepted the pairing (`PairResultPage`, CompanionPcPage.kt:343-361): the moment before the screen moves on, and
/// its two ways on (open the library, back).
enum CompanionPairResultPage {
    static func page(id: String, pcName: String, onOpen: @escaping @MainActor () -> Void, onBack: @escaping @MainActor () -> Void) -> CompanionPage {
        CompanionPage(key: "pair/result/\(id)", revision: [id, pcName]) { CompanionPairResultCard(id: id, pcName: pcName, onOpen: onOpen, onBack: onBack) }
    }
}

private struct CompanionPairResultCard: View {
    let id: String
    let pcName: String
    let onOpen: @MainActor () -> Void
    let onBack: @MainActor () -> Void

    var body: some View {
        PageCard { fit in
            PageHeading(icon: Symbols.checkCircle, title: pcTitle(pcName, id: id, fit: fit), subtitle: L("pair_result_eyebrow"))
            BodyText(L("pair_result_text"))
            Filler()
            let actions = [PageAction(label: L("pair_open_library"), style: .primary, run: onOpen), PageAction(label: L("pair_back_hosts"), run: onBack)]
            ForEach(Array(PcButtons.rows(actions, fit: fit).enumerated()), id: \.offset) { _, row in ActionRow(actions: row) }
        }
    }
}

// MARK: - Library states

/// The library states without a game to focus or a PC card (`LibraryNotice`).
enum CompanionLibraryNotice: Hashable, Sendable { case empty, loading, noPC }

/// "No applications", "Reading the library" or "No PC" (`LibraryNoticePage`, CompanionPcPage.kt:366-380).
enum CompanionLibraryNoticePage {
    struct Shown: Hashable {
        let notice: CompanionLibraryNotice
        let pcName: String?
        let status: CompanionPcStatus?
    }

    /// [onReconnect] runs Reconnect (empty library); [onDetails] PC details (empty library) or Back to PCs.
    static func page(_ shown: Shown, onReconnect: @escaping @MainActor () -> Void, onDetails: @escaping @MainActor () -> Void) -> CompanionPage {
        CompanionPage(key: "library/\(shown.notice)", revision: shown) {
            CompanionLibraryNoticeCard(shown: shown, onReconnect: onReconnect, onDetails: onDetails)
        }
    }
}

private struct CompanionLibraryNoticeCard: View {
    let shown: CompanionLibraryNoticePage.Shown
    let onReconnect: @MainActor () -> Void
    let onDetails: @MainActor () -> Void
    @Environment(\.delosColors) private var colors

    var body: some View {
        let eyebrow: String? = switch shown.notice {
        case .empty: shown.pcName.flatMap { name in shown.status.map { L("pc_name_status", name, statusLabel($0)) } }
        case .loading: L("pc_loading_eyebrow")
        case .noPC: nil
        }
        let (icon, title) = switch shown.notice {
        case .empty: (Symbols.sportsEsports, L("pc_empty_title"))
        case .loading: (Symbols.loading, L("pc_loading_title"))
        case .noPC: (Symbols.devices, L("pc_nopc_title"))
        }
        let actions = shown.notice == .empty
            ? [PageAction(label: L("pc_action_reconnect"), style: .primary, run: onReconnect), PageAction(label: L("pc_action_details"), run: onDetails)]
            : [PageAction(label: L("pc_action_back_pcs"), style: .primary, run: onDetails)]
        PageCard { fit in
            let b = fit.budget
            // The PC and its status when it fits one line, else the status alone
            let subtitle: String? = if shown.notice == .empty, let eyebrow, let status = shown.status {
                oneLine(eyebrow, statusLabel(status), width: b.innerWidth - PageHeading.chrome, fit: fit)
            } else {
                eyebrow
            }
            PageHeading(icon: icon, title: title, subtitle: subtitle)
            switch shown.notice {
            case .empty:
                BodyText(
                    CompanionFit.summary(
                        L("pc_empty_text"), short: L("pc_empty_short"), maxLines: b.bodyLines, width: b.innerWidth, metrics: fit.metrics,
                        last: L("companion_see_main")), color: colors.text2)
            case .loading:
                BodyText(L("pc_loading_text"), color: colors.text2)
                BodyText(L("pc_loading_note"), color: colors.text3).optional(50)
            case .noPC:
                BodyText(L("pc_nopc_text"), color: colors.text2)
            }
            Filler()
            ForEach(Array(PcButtons.rows(actions, fit: fit).enumerated()), id: \.offset) { _, row in ActionRow(actions: row) }
        }
    }
}

// MARK: - Publishers

extension View {
    /// Start and Devices: the focused PC's card (`PublishCompanionPc`, CompanionPcPublisher.kt:56-60); nothing while the
    /// focus is not on a PC (the welcome or fallback card shows then).
    func companionPc(_ hostID: @escaping @MainActor () -> String?, context: CompanionPcContext, actions: ShellActions) -> some View {
        companionPage {
            guard let id = hostID(), let host = actions.hosts.host(id) else { return nil }
            return CompanionPcPage.page(host, context: context, actions: actions)
        }
    }
}

/// Home without a game to focus (`PublishCompanionLibraryState`, CompanionPcPublisher.kt:105-139): an offline PC gets its
/// card (Wake, else Search, and Rename), an empty library "No applications" with Reconnect and the PC's details, a library
/// still being read and no PC at all say so with a way back to the PCs. A library with games publishes nothing here (the
/// focused game does). Every game hidden reads "No applications" on the main screen, so it gets the same page here.
@MainActor
enum CompanionLibraryPublisher {
    static func page(content: HomeContent, allHidden: Bool, hostID: String, actions: ShellActions, navigator: Navigator) -> CompanionPage? {
        let back: @MainActor () -> Void = { _ = navigator.back() }
        switch content {
        case .noPC:
            return CompanionLibraryNoticePage.page(.init(notice: .noPC, pcName: nil, status: nil), onReconnect: {}, onDetails: back)
        case .loading:
            return CompanionLibraryNoticePage.page(.init(notice: .loading, pcName: nil, status: nil), onReconnect: {}, onDetails: back)
        case .offline:
            return actions.hosts.host(hostID).map { CompanionPcPage.page($0, context: .home, actions: actions) }
        case .empty, .apps:
            if case .apps = content, !allHidden { return nil }
            let host = actions.hosts.host(hostID)
            return CompanionLibraryNoticePage.page(
                .init(notice: .empty, pcName: host?.name, status: host.map { CompanionPcCard.status($0) }),
                onReconnect: { actions.connect(hostID) },
                onDetails: { navigator.openFromNavigation(.devices, focus: StartScreen.pcID(hostID)) })
        }
    }
}
