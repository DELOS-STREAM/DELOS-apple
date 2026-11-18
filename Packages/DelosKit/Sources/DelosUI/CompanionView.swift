import DelosData
import SwiftUI

/// The companion screen (`CompanionContent`, CompanionContent.kt:70-160 of DELOS for Android), the one view of the
/// companion window on the screen the display host chose: in the shell the one page of the highest priority the shell's
/// screens published (else the fallback or the welcome card), in a stream the statistics and the stream menu as touch
/// tiles or the keyboard, and the loader page while the stream is still starting. It runs on its own ``Stage``, planned
/// from its own window, in the current profile's colors. Nothing in it scrolls, ever.
///
/// Burn-in: everything drifts by a few points every two minutes (``CompanionBurnIn``), always; in the shell the screen dims
/// after the delay of Settings → Display → Dim the second screen when idle without a touch, unless the page is waited at
/// (``CompanionPage/keepsAwake``) or dimming is off. The touch that wakes it is not passed on. A new page counts as a touch.
public struct CompanionRoot: View {
    public init() {}

    public var body: some View {
        let hub = CompanionHub.shared
        StageReader(textScale: hub.look.textScale) {
            CompanionContent(hub: hub)
        }
        .environment(\.delosColors, hub.look.colors)
        .environment(\.reducedMotion, hub.look.reducedMotion)
        .preferredColorScheme(hub.look.colors.dark ? .dark : .light)
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }
}

struct CompanionContent: View {
    let hub: CompanionHub
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.stage) private var stage
    @State private var lastTouch = Date.now
    @State private var dimmed = false
    @State private var dim = CompanionDim.load()
    @State private var shift = CompanionBurnIn.Shift(x: 0, y: 0)

    /// What the window shows: the shell's page, or in a stream the loader page while it starts and a result or problem
    /// over it (nil: the stream content).
    private var page: CompanionPage? {
        if let stream = hub.stream { return stream.loaderPage ?? hub.overlayPage }
        return hub.shellPage
    }

    var body: some View {
        let page = self.page
        // Armed from the last touch, so no polling; a stream is never dimmed (someone is looking at the menu)
        let delay = page.flatMap { $0.keepsAwake ? nil : dim.delay }
        ZStack {
            colors.bg.color.ignoresSafeArea()
            VStack(spacing: 0) {
                CompanionHeader(pcName: headerPC)
                ZStack {
                    if let page {
                        CompanionPageHost(page: page, hub: hub)
                    } else if let stream = hub.stream {
                        CompanionStreamContent(stream: stream)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .offset(x: Double(shift.x) * CompanionBurnIn.step, y: Double(shift.y) * CompanionBurnIn.step)
            .opacity(dimmed ? CompanionBurnIn.dimAlpha : 1)
            .animation(reducedMotion ? nil : .easeInOut(duration: CompanionBurnIn.dimFade), value: dimmed)
            #if !os(tvOS)
            // Every touch counts, whoever takes it (Apple TV has no second screen, so no companion)
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touched() })
            #endif
            #if !os(tvOS)
            if dimmed {
                // Dimmed: the first touch only wakes the screen (it must never press a button it cannot be seen to press)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        dimmed = false
                        lastTouch = .now
                    })
            }
            #endif
        }
        .task(id: DimTimer(lastTouch: lastTouch, delay: delay, page: page?.key)) {
            dimmed = false
            guard let delay else { return }
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { dimmed = true }
        }
        .task {
            let opened = Date.now
            while !Task.isCancelled {
                shift = CompanionBurnIn.shift(at: Date.now.timeIntervalSince(opened))
                try? await Task.sleep(for: .seconds(CompanionBurnIn.period))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DisplaySettings.didChange)) { _ in dim = CompanionDim.load() }
    }

    /// The PC in the header: the stream's, else the connected one; "No PC" on the welcome card.
    private var headerPC: String? {
        if let stream = hub.stream { return stream.pcName }
        if let host = hub.context?.host { return host.name }
        return hub.context?.welcome == true ? L("companion_no_pc") : nil
    }

    private func touched() {
        // A drag reports every move: once a second is enough to restart the timer
        if Date.now.timeIntervalSince(lastTouch) > 1 { lastTouch = .now }
    }

    private struct DimTimer: Equatable {
        let lastTouch: Date
        let delay: TimeInterval?
        let page: String?
    }
}

/// Shows [page] and fades to the next one when its key changes (a different row, game, screen: ``Motion/fade``, snapped
/// with reduced motion); a page with the same key is the same page updated and does not fade (`PageHost`). While the page
/// shown is a settings help, the hub says so (`CompanionSession.helpShown`).
private struct CompanionPageHost: View {
    let page: CompanionPage
    let hub: CompanionHub
    @Environment(\.reducedMotion) private var reducedMotion

    var body: some View {
        ZStack {
            page.content()
                .id(page.key)
                .transition(.opacity)
        }
        .animation(reducedMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: page.key)
        .onChange(of: page.isSettingsHelp, initial: true) { _, help in hub.showsHelp = help }
        .onDisappear { hub.showsHelp = false }
    }
}

/// The strip at the top (`Header`): the brand on the left, the PC on the right; 64 stage pixels with its rule.
private struct CompanionHeader: View {
    let pcName: String?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: stage.px(28)) {
                HStack(spacing: stage.px(14)) {
                    LogoMark(size: 34)
                    Text(verbatim: "DELOS")
                        .font(DelosFonts.unbounded(stage.tpx(CompanionFit.minText), .medium))
                        .tracking(stage.tpx(CompanionFit.minText) * 0.08)
                        .foregroundStyle(colors.text.color)
                }
                Spacer(minLength: 0)
                if let pcName, !pcName.isEmpty {
                    HStack(spacing: stage.px(14)) {
                        Circle().fill(colors.accent2.color).frame(width: stage.px(14), height: stage.px(14))
                        Text(verbatim: pcName)
                            .font(DelosFonts.figtree(stage.tpx(CompanionFit.minText)))
                            .foregroundStyle(colors.text2.color)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, stage.px(CompanionFit.margin))
            .frame(height: stage.px(CompanionFit.header - 1))
            Rectangle().fill(colors.line.color).frame(height: stage.px(1))
        }
        .padding(.top, stage.px(stage.safe.top))
    }
}

// MARK: - Fallback and welcome

/// The status card of every screen without content of its own (`FallbackPage`, CompanionFallbackPage.kt:17-52): the
/// screen's title and purpose, the connected PC with its status and running game, the clock and the battery, and what the
/// controller does here (the entries of the main hint bar).
enum FallbackPage {
    static func page(_ context: ShellContext) -> CompanionPage {
        CompanionPage(key: "fallback/\(context.title)", revision: context) { FallbackCard(context: context) }
    }
}

private struct FallbackCard: View {
    let context: ShellContext
    @Environment(\.delosColors) private var colors

    var body: some View {
        let hub = CompanionHub.shared
        PageCard { fit in
            let b = fit.budget
            let width = b.innerWidth
            PageHeading(
                icon: Symbols.info, title: context.title.isEmpty ? L("companion_screen_home") : context.title, subtitle: L("companion_context_eyebrow"))
            let purpose = CompanionFit.summary(
                context.purpose, short: context.purpose, maxLines: b.roomy ? 3 : 1, width: width, metrics: fit.metrics, last: L("companion_see_main"))
            if !purpose.isEmpty { BodyText(purpose, color: colors.text2).optional(60) }
            if let host = context.host {
                let full = b.roomy || host.runningGame == nil
                    ? "\(host.name) \u{00B7} \(host.status)" : "\(host.name) \u{00B7} \(host.status) \u{00B7} \(host.runningGame ?? "")"
                BodyText(fit.metrics.lines(full, width: width) <= 1 ? full : host.status, color: colors.accent2, maxLines: 1).optional(80)
                if b.roomy, let game = host.runningGame {
                    BodyText(L("companion_host_running", game), maxLines: 1).optional(30)
                }
            }
            HStack {
                TimelineView(.everyMinute) { timeline in
                    BodyText(StatusClock.text(timeline.date, format: hub.look.clock, locale: .autoupdatingCurrent), maxLines: 1)
                }
                if let battery = hub.battery {
                    BodyText(L("companion_battery", Int((battery.level * 100).rounded())), maxLines: 1, alignment: .trailing)
                }
            }
            .optional(40)
            Filler()
            let (shown, rest) = CompanionFit.top(context.hints, b.hints)
            if shown.isEmpty {
                BodyText(L("companion_no_hints"), color: colors.text2, maxLines: 2)
            } else {
                HintList(hints: shown, rest: rest).optional(70)
            }
        }
    }
}

/// No PC is paired yet: a short welcome and the one thing to do (`WelcomePage`, CompanionFallbackPage.kt:55-72).
enum WelcomePage {
    static func page(_ context: ShellContext) -> CompanionPage {
        CompanionPage(key: "welcome", revision: context) { WelcomeCard(context: context) }
    }
}

private struct WelcomeCard: View {
    let context: ShellContext
    @Environment(\.delosColors) private var colors

    var body: some View {
        PageCard { fit in
            let b = fit.budget
            PageHeading(icon: Symbols.addLink, title: L("companion_screen_boot"), subtitle: L("companion_welcome_sub"))
            BodyText(CompanionFit.summary(
                L("companion_welcome_text"), short: L("companion_welcome_short"), maxLines: b.bodyLines, width: b.innerWidth, metrics: fit.metrics,
                last: L("companion_see_main")), color: colors.text2)
                .optional(60)
            Filler()
            if !context.hints.isEmpty { HintList(hints: Array(context.hints.prefix(1)), rest: 0).optional(70) }
        }
    }
}
