import CoreGraphics
@testable import DelosData
import DelosHost
import DelosInput
import Foundation
import SwiftUI
import Testing
@testable import DelosUI

/// The game overview (A · Descent): what it shows of sparse and complete data, its navigation, its scroll line and its
/// motion's arithmetic.
@MainActor
@Suite struct GameOverviewTests {
    private let complete = DemoOverview.complete(1)
    /// The complete game without Steam's media: YouTube's videos and IGDB's screenshots.
    private let youTube = { var details = DemoOverview.complete(1); details.steam = nil; return details }()
    private let sparse = DemoOverview.sparse(3)

    @Test func completeGameShowsEverySection() {
        let content = OverviewContent(details: complete, library: [HostApp(id: 9, title: "Hades")], region: "CZ")
        #expect(content.sections == [.about, .media, .details, .streaming, .links, .similar])
        #expect(content.media.count == 11)
        #expect(content.media.prefix(2).allSatisfy { $0.kind == .video })
        #expect(content.ageRatings.first?.organization == "PEGI")
        #expect(content.eyebrow == "2025 · Driftlight Studios")
        // A similar game the player owns is the library's app
        #expect(content.similar.first { $0.name == "Hades" }?.app?.id == 9)
        #expect(content.similar.first { $0.name == "Deepwake" }?.app == nil)
        #expect(content.facts.count == 5)
    }

    @Test func sparseGameDropsWhatIsEmpty() {
        let content = OverviewContent(details: sparse, library: [], region: "US")
        #expect(content.critics.value == nil)
        #expect(sparse.fewRatings)
        #expect(content.groups.contains { $0.kind == .ageRatings } == false)
        #expect(content.groups.contains { $0.kind == .themes } == false)
        #expect(content.links.count == 1)
        #expect(content.sections == [.about, .media, .details, .streaming, .links, .similar])
        let bare = OverviewContent(details: GameDetails(id: 4, name: "Bare"), library: [], region: nil)
        #expect(bare.sections == [.streaming])
        #expect(bare.eyebrow == nil)
    }

    @Test func steamLinkFallsBackToTheAppID() {
        let d = GameDetails(id: 1, name: "G", externalGames: [.init(uid: "620", source: 1)])
        let links = OverviewContent(details: d, library: [], region: nil).links
        #expect(links.map(\.url.absoluteString) == ["https://store.steampowered.com/app/620"])
    }

    @Test func navigation() {
        typealias N = OverviewNavigation
        #expect(N.outcome(.back, focused: AnyHashable(N.summary)) == .close)
        #expect(N.outcome(.up, focused: AnyHashable(N.play)) == .close)
        #expect(N.outcome(.up, focused: AnyHashable(N.settings)) == .close)
        #expect(N.outcome(.up, focused: AnyHashable(N.summary)) == .focus)
        #expect(N.outcome(.down, focused: AnyHashable(N.play)) == .focus)
        #expect(N.outcome(.accept, focused: AnyHashable(N.play)) == .focus)
        #expect(N.outcome(.toastAction, focused: AnyHashable(N.play)) == .ignore)
        #expect(N.initialFocus == N.play)
        #expect(N.opens(HostApp(id: 1, title: "Hades"), hasDetails: true))
        #expect(!N.opens(HostApp(id: 1, title: "Desktop"), hasDetails: true))
        #expect(!N.opens(HostApp(id: 1, title: "Hades"), hasDetails: false))
    }

    @Test func focusModelWalksThePageAndUpLeavesIt() {
        let focus = FocusModel(initial: OverviewNavigation.play)
        focus.register(OverviewNavigation.play, frame: CGRect(x: 560, y: 600, width: 200, height: 76)) {}
        focus.register(OverviewNavigation.settings, frame: CGRect(x: 780, y: 600, width: 300, height: 76)) {}
        focus.register(OverviewNavigation.summary, frame: CGRect(x: 150, y: 1100, width: 1000, height: 200)) {}
        focus.register(OverviewNavigation.facts, frame: CGRect(x: 1200, y: 1100, width: 560, height: 300)) {}
        #expect(focus.handle(.down))
        #expect(focus.focused == AnyHashable(OverviewNavigation.summary))
        #expect(focus.handle(.right))
        #expect(focus.focused == AnyHashable(OverviewNavigation.facts))
        #expect(focus.handle(.up))
        #expect(OverviewNavigation.inHeader(focus.focused))
        #expect(OverviewNavigation.outcome(.up, focused: focus.focused) == .close)
    }

    @Test func focusedSectionScrollsToItsLine() {
        typealias N = OverviewNavigation
        #expect(N.scrollTarget(header: true, sectionTop: 0, sectionHeight: 0, itemTop: 0, itemHeight: 0, viewport: 1440, maximum: 5000, current: 800) == 0)
        #expect(N.scrollTarget(header: false, sectionTop: 1400, sectionHeight: 400, itemTop: 1500, itemHeight: 76, viewport: 1440, maximum: 5000, current: 0) == 1400 - N.sectionAnchor)
        // A section taller than the viewport reveals the item with a margin instead
        #expect(N.scrollTarget(header: false, sectionTop: 1400, sectionHeight: 1500, itemTop: 2600, itemHeight: 200, viewport: 1080, maximum: 5000, current: 1300) == 2600 + 200 + 160 - 1080)
        #expect(N.scrollTarget(header: false, sectionTop: 4900, sectionHeight: 300, itemTop: 4900, itemHeight: 76, viewport: 1080, maximum: 4000, current: 0) == 4000)
    }

    @Test func flightRunsFromTheCardToTheSlot() {
        let from = CGRect(x: 150, y: 520, width: 316.5, height: 474.75), to = CGRect(x: 150, y: 150, width: 340, height: 510)
        #expect(OverviewMotion.flightFrame(from: from, to: to, progress: 0, lift: 30) == from)
        #expect(OverviewMotion.flightFrame(from: from, to: to, progress: 1, lift: 30) == to)
        let middle = OverviewMotion.flightFrame(from: from, to: to, progress: 0.5, lift: 30)
        // Above the straight line and a little larger at the middle
        #expect(middle.midY < (from.midY + to.midY) / 2 - 29 && middle.width > (from.width + to.width) / 2)
    }

    /// #108: past an end only the cover's position overshoots, along the half of the arc it arrived on, softly capped;
    /// its size (and so its corners) stays the end's.
    @Test func flightOvershootMovesOnlyThePosition() {
        let from = CGRect(x: 150, y: 520, width: 316.5, height: 474.75), to = CGRect(x: 150, y: 150, width: 340, height: 510)
        let past = OverviewMotion.flightFrame(from: from, to: to, progress: 1.04, lift: 30, cap: 40)
        #expect(past.size == to.size && past.midY < to.midY)
        let before = OverviewMotion.flightFrame(from: from, to: to, progress: -0.015, lift: 30, cap: 40)
        #expect(before.size == from.size && before.midY > from.midY)
        // Never more than the cap, however far the spring passes
        let far = OverviewMotion.flightFrame(from: from, to: to, progress: 2, lift: 30, cap: 40)
        #expect(hypot(far.midX - to.midX, far.midY - to.midY) < 40)
    }

    /// #108: sampled every millisecond, both springs carry the cover past its target exactly once (the next bounce is
    /// under 0.05 px), by 4–6 % of the travel, with its size at the target's whenever it is past.
    @Test func flightPositionOvershootsOnceOnBothSprings() {
        let card = CGRect(x: 150, y: 520, width: 316.5, height: 474.75), slot = CGRect(x: 150, y: 150, width: 340, height: 510)
        let travel = hypot(card.midX - slot.midX, card.midY - slot.midY)
        for (spring, opening) in [(OverviewMotion.flightOpen, true), (OverviewMotion.flightClose, false)] {
            let target = opening ? slot : card
            // How far past the target the cover is, along the way it came (positive: past)
            let way = CGPoint(x: target.midX - (opening ? card : slot).midX, y: target.midY - (opening ? card : slot).midY)
            let length = hypot(way.x, way.y)
            var excursions = 0, peak = 0.0, wasPast = false
            for ms in stride(from: 0.0, through: 3000, by: 1) {
                let moved = spring.value(target: 1.0, initialVelocity: 0, time: ms / 1000)
                let progress = opening ? moved : 1 - moved
                let frame = OverviewMotion.flightFrame(from: card, to: slot, progress: progress, lift: 30, cap: 40)
                let past = ((frame.midX - target.midX) * way.x + (frame.midY - target.midY) * way.y) / length
                let isPast = past > 0.05
                if isPast && !wasPast { excursions += 1 }
                wasPast = isPast
                peak = max(peak, past)
                if progress > 1 || progress < 0 { #expect(frame.size == target.size) }
            }
            #expect(excursions == 1)
            #expect(peak > travel * 0.04 && peak < travel * 0.06)
        }
    }

    @Test func ratingRingOvershootIsLimited() {
        #expect(OverviewMotion.ratingFill(ms: 0) == 0)
        #expect(OverviewMotion.ratingFill(ms: OverviewMotion.ratingRun) == 1)
        let samples = stride(from: 0.0, through: OverviewMotion.ratingRun, by: 4).map(OverviewMotion.ratingFill(ms:))
        // About 7.3 % past the target at most (under the 8 % cap), reached near the spring's peak (≈ 599 ms)
        let peak = samples.max() ?? 0
        #expect(peak > 1.06 && peak < 1.08)
        let index = samples.firstIndex(of: peak) ?? 0
        #expect(abs(Double(index) * 4 - 599) < 12)
        // No second bounce: once past its peak it only comes down, never below the target
        for (a, b) in zip(samples[index...], samples[(index + 1)...]) { #expect(b <= a + 1e-9 && b >= 1) }
        // One overshoot only: the curve has a single local maximum, and it settles at its end without a jump
        let maxima = samples.indices.dropFirst().dropLast().filter { samples[$0] > samples[$0 - 1] && samples[$0] >= samples[$0 + 1] }
        #expect(maxima.count == 1)
        #expect(OverviewMotion.ratingFill(ms: OverviewMotion.ratingRun - 1) - 1 < 0.002)
    }

    @Test func ratingNumberCountsUpWithoutOvershoot() {
        #expect(OverviewMotion.ratingNumber(ms: 0) == 0)
        #expect(OverviewMotion.ratingNumber(ms: OverviewMotion.ratingCount) == 1)
        #expect(OverviewMotion.ratingNumber(ms: OverviewMotion.ratingRun) == 1)
        let samples = stride(from: 0.0, through: OverviewMotion.ratingRun, by: 4).map(OverviewMotion.ratingNumber(ms:))
        // Rising all the way (CSS's ease-out: fast first), never past the rating
        for (a, b) in zip(samples, samples.dropFirst()) { #expect(b >= a && b <= 1) }
        #expect(OverviewMotion.ratingNumber(ms: OverviewMotion.ratingCount / 2) > 0.65)
    }

    @Test func swipedCoverRidesARubberBand() {
        let cap = 100.0
        // At most 60 % of the finger's travel, never past the cap, rising all the way
        var previous = 0.0
        for travel in stride(from: 0.0, through: 2000, by: 10) {
            let follow = OverviewMotion.swipeFollow(-travel, cap: cap)
            #expect(-follow <= travel * OverviewMotion.swipeShare + 1e-9 && -follow < cap)
            #expect(follow <= previous)
            previous = follow
        }
        // 60 % at first, then easing towards the cap
        #expect(abs(OverviewMotion.swipeFollow(-1, cap: cap) + 0.6) < 0.01)
        #expect(OverviewMotion.swipeFollow(-400, cap: cap) < -90)
        // Down it barely gives
        #expect(abs(OverviewMotion.swipeFollow(40, cap: cap) - 6) < 1e-9)
        // It fades only near the top of its band, to 70 %
        #expect(OverviewMotion.swipeOpacity(0) == 1 && OverviewMotion.swipeOpacity(0.5) == 1)
        #expect(abs(OverviewMotion.swipeOpacity(1) - 0.7) < 1e-9 && OverviewMotion.swipeOpacity(0.75) < 1)
    }

    /// Regression (#25): pulled down to close, the cover stopped where the finger left it, then jumped back to the slot
    /// and flew from there. The flight now starts at the pulled cover's frame with the finger's speed.
    @Test func pullCloseHandsTheFingersPositionAndSpeedToTheFlight() {
        let slot = CGRect(x: 150, y: 150, width: 340, height: 510), card = CGRect(x: 150, y: 900, width: 340, height: 510)
        let still = OverviewMotion.pullHandoff(slot: slot, pull: 0, scale: 1, speed: 0, card: card)
        #expect(still.frame == slot && still.velocity == 0)
        let scale = OverviewMotion.pullScale(200)
        #expect(abs(scale - (1 - 200.0 / 2400)) < 1e-12)
        let pulled = OverviewMotion.pullHandoff(slot: slot, pull: 200, scale: scale, speed: 1100, card: card)
        // The pulled cover's frame: moved down by the pull, shrunk about its middle
        #expect(abs(pulled.frame.midX - slot.midX) < 1e-9 && abs(pulled.frame.midY - (slot.midY + 200)) < 1e-9)
        #expect(abs(pulled.frame.width - slot.width * scale) < 1e-9 && abs(pulled.frame.height - slot.height * scale) < 1e-9)
        // Straight down to the card: the speed over the remaining distance, in flights per second
        #expect(abs(pulled.velocity - 1100.0 / (card.midY - pulled.frame.midY)) < 1e-9)
        // The flight's frame at its header end is the pulled cover's
        let end = OverviewMotion.flightFrame(from: card, to: pulled.frame, progress: 1, lift: 30)
        #expect(abs(end.minX - pulled.frame.minX) < 1e-9 && abs(end.minY - pulled.frame.minY) < 1e-9 && abs(end.width - pulled.frame.width) < 1e-9)
        // Moving up (or not at all) adds no speed; a fling is capped
        #expect(OverviewMotion.pullHandoff(slot: slot, pull: 200, scale: scale, speed: -500, card: card).velocity == 0)
        #expect(OverviewMotion.pullHandoff(slot: slot, pull: 200, scale: scale, speed: 1e6, card: card).velocity == 6)
    }

    /// Regression (#23): flying back into the wide first cover stretched the portrait art to the landscape frame; the
    /// frame now changes its shape while the picture keeps one scale for both axes, filling it.
    @Test func wideFlightKeepsThePictureUnstretched() {
        let wide = CGRect(x: 120, y: 560, width: 1000, height: 474), slot = CGRect(x: 150, y: 150, width: 340, height: 510)
        let aspect = 2.0 / 3
        let base = OverviewMotion.fillSize(aspect: aspect, box: slot.size)
        #expect(abs(base.width - 340) < 0.001 && abs(base.height - 510) < 0.001)
        for progress in [0.0, 0.3, 0.7, 1.0] {
            let frame = OverviewMotion.flightFrame(from: wide, to: slot, progress: progress, lift: 30)
            let fill = OverviewMotion.fill(aspect: aspect, base: base, frame: frame)
            let shown = CGRect(x: fill.dx, y: fill.dy, width: base.width * fill.scale, height: base.height * fill.scale)
            // The same shape as the picture, covering the frame, centred on it
            #expect(abs(shown.width / shown.height - aspect) < 0.0001)
            #expect(shown.width >= frame.width - 0.001 && shown.height >= frame.height - 0.001)
            #expect(abs(shown.midX - frame.midX) < 0.001 && abs(shown.midY - frame.midY) < 0.001)
        }
        // At the card the wide frame crops the portrait art to its width
        let start = OverviewMotion.fill(aspect: aspect, base: base, frame: wide)
        #expect(abs(base.width * start.scale - wide.width) < 0.001)
    }

    @Test func theHeroBlurDeepensFromTheDashboards() {
        // 60 % of the former 40 px on top of the dashboard's
        #expect(OverviewMotion.deepBlur(from: 0) == 24 && OverviewMotion.deepBlur(from: 20) == 44)
    }

    @Test func homeMotionNumbers() {
        #expect(OverviewMotion.coverLift(distance: 1) == -190)
        #expect(OverviewMotion.heroZoom(0) == 1 && OverviewMotion.heroZoom(9000) == 1.1)
        #expect(OverviewMotion.heroDrift(5000) == -70)
        #expect(OverviewContent.completionShare(streamedSeconds: 73_440, completionSeconds: 81_900) == 90)
        #expect(OverviewContent.completionShare(streamedSeconds: 900_000, completionSeconds: 81_900) == 100)
        #expect(OverviewContent.completionShare(streamedSeconds: 1, completionSeconds: nil) == nil)
    }

    @Test func swipeUpOpensFromWhereTheFingerLeftIt() {
        let launcher = OverviewLauncher()
        var opened: (Int, OverviewSwipeRelease?)?
        launcher.canOpen = { _ in true }
        launcher.isFocused = { $0.id == 7 }
        launcher.open = { app, release in opened = (app.id, release) }
        let app = HostApp(id: 7, title: "Hades")
        // Sideways is the row's, not a swipe
        launcher.drag(app, translation: CGSize(width: 40, height: -12), slop: 10, cap: 100, threshold: 90)
        #expect(launcher.dragApp == nil)
        launcher.drag(app, translation: CGSize(width: 2, height: -60), slop: 10, cap: 100, threshold: 90)
        #expect(launcher.dragApp == 7 && launcher.dragOffset < 0 && launcher.dragOffset > -36)
        // The rubber band's share and how near opening it is (60 of 90 points) for this cover only
        #expect(launcher.follow(7).share > 0 && abs(launcher.follow(7).ready - 60.0 / 90) < 1e-9 && launcher.follow(8).offset == 0)
        launcher.drag(app, translation: CGSize(width: 2, height: -300), slop: 10, cap: 100, threshold: 90)
        let share = launcher.dragShare, offset = launcher.dragOffset
        launcher.end(app, translation: CGSize(width: 2, height: -300), velocityY: -900, threshold: 90)
        // The flight starts from the cover as the finger left it: its lift, growth, opacity and speed
        #expect(opened?.0 == 7 && opened?.1 == OverviewSwipeRelease(offset: offset, share: share, opacity: OverviewMotion.swipeOpacity(share), velocityY: -900))
        #expect((opened?.1?.opacity ?? 1) < 0.9 && abs((opened?.1?.scale ?? 1) - (1 + 0.03 * share)) < 1e-12)
        #expect(launcher.dragApp == nil && launcher.follow(7).offset == 0)
        // Short of the threshold the cover springs back
        opened = nil
        launcher.drag(app, translation: CGSize(width: 0, height: -40), slop: 10, cap: 100, threshold: 90)
        launcher.end(app, translation: CGSize(width: 0, height: -40), threshold: 90)
        #expect(opened == nil && launcher.dragApp == nil)
    }

    @Test func cancelledCoverSwipeSettlesWithoutOpeningOrCancellingAnotherCover() {
        let launcher = OverviewLauncher()
        let app = HostApp(id: 7, title: "Fixture")
        var opened = false
        launcher.canOpen = { _ in true }
        launcher.isFocused = { _ in true }
        launcher.open = { _, _ in opened = true }
        launcher.drag(app, translation: CGSize(width: 2, height: -50), slop: 10, cap: 100, threshold: 90)
        launcher.cancel(HostApp(id: 8, title: "Other"))
        #expect(launcher.dragApp == app.id && launcher.dragOffset < 0)
        launcher.cancel(app)
        #expect(launcher.dragApp == nil && launcher.dragOffset == 0 && launcher.dragShare == 0 && launcher.dragReady == 0 && !opened)
        launcher.end(app, translation: CGSize(width: 0, height: -150), threshold: 90)
        #expect(!opened)
    }

    @Test func viewerIsEdgeToEdge() {
        let item = OverviewContent.Media(kind: .video, id: "v", name: nil)
        #expect(OverviewViewer.frame(item, width: 1920, height: 1080) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(OverviewViewer.frame(.init(kind: .screenshot, id: "s", name: nil), width: 1920, height: 1440) == CGRect(x: 0, y: 0, width: 1920, height: 1440))
    }

    /// #28: a long gallery's dots are a window of nine around the current item, always holding it.
    @Test func longGalleryShowsAWindowOfPageDots() {
        #expect(OverviewDock.pageWindow(count: 5, shown: 4) == 0..<5)
        #expect(OverviewDock.pageWindow(count: 29, shown: 2) == 0..<9)
        #expect(OverviewDock.pageWindow(count: 29, shown: 5) == 1..<10)
        #expect(OverviewDock.pageWindow(count: 29, shown: 28) == 20..<29)
        for shown in 0..<29 { #expect(OverviewDock.pageWindow(count: 29, shown: shown).contains(shown)) }
    }

    /// #28: the screenshot dock's title column ends 24 px before the previous button, however wide the dots are.
    @Test func dockTitleEndsBeforeTheTransport() {
        let px: (Double) -> CGFloat = { CGFloat($0) }
        for dots in [9, 3, 1] {
            let pageWidth = Double(dots) * 26 + 28 + 74
            let width = 1920.0, panel = width - 120
            let info = OverviewDock.infoWidth(width: width, pageWidth: pageWidth, px: px)
            // The column starts 44 px in from the panel's left edge; the previous button's left edge is half the middle in
            let titleEnd = -panel / 2 + 44 + info, previousLeft = -(pageWidth + 204) / 2
            #expect(info > 0 && titleEnd <= previousLeft - 24 + 1e-9)
        }
    }

    /// #28: a tile's picture keeps 16:9, enlarged evenly; its parallax is 10 % of the distance, never past the rim; the
    /// viewer's flight lands at the size the tile shows it.
    @Test func carouselPictureKeepsItsShapeAndRim() {
        let width = 520.0 * OverviewMotion.mediaOverscan, rim = (width - 520) / 2
        #expect(abs(OverviewMotion.parallaxShift(distance: 100, width: width) + 10) < 1e-9)
        #expect(abs(OverviewMotion.parallaxShift(distance: -5000, width: width) - rim) < 1e-9)
        #expect(abs(OverviewMotion.parallaxShift(distance: 5000, width: width) + rim) < 1e-9)
        // A screenshot fitted 16:9 in a 4:3 viewer: at the tile its picture is the tile's width, enlarged by the rim
        let scale = OverviewMotion.viewerFlightScale(tile: CGSize(width: 520, height: 292.5), target: CGSize(width: 1920, height: 1440), fills: false)
        #expect(abs(1920 * scale - 520 * OverviewMotion.mediaOverscan) < 1e-6)
        // A video fills the 4:3 viewer: at the tile the frame covers it (its width the tile's), enlarged by the rim
        let video = OverviewMotion.viewerFlightScale(tile: CGSize(width: 520, height: 292.5), target: CGSize(width: 1920, height: 1440), fills: true)
        #expect(abs(1920 * video - 520 * OverviewMotion.mediaOverscan) < 1e-6 && 1440 * video > 292.5 * OverviewMotion.mediaOverscan)
    }

    @MainActor @Test func viewerOverlayHidesAfterThreeIdleSeconds() {
        let start = ContinuousClock.now
        let controls = OverviewViewerControls(now: start)
        controls.hideIfIdle(at: start + .milliseconds(2900))
        #expect(controls.visible)
        controls.hideIfIdle(at: start + .seconds(3))
        #expect(!controls.visible)
        controls.onInput(at: start + .seconds(4))
        #expect(controls.visible && controls.remaining(at: start + .seconds(5)) == .seconds(2))
    }

    @Test func viewerCommands() {
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: youTube)
        let media = OverviewContent(details: youTube, library: [], region: nil).media
        var sent: [String] = []
        func player(_ id: String) {
            session.video.reset(id)
            session.video.run = { sent.append($0) }
        }
        // A video that plays: Left and Right seek, A plays or pauses, Y mutes, L1 and R1 browse
        session.viewer = 0
        player(media[0].id)
        OverviewViewer.handle(.left, session: session, media: media)
        OverviewViewer.handle(.right, session: session, media: media)
        #expect(session.viewer == 0)
        #expect(sent.count == 2 && sent[0].contains("getCurrentTime()+-10.0") && sent[1].contains("getCurrentTime()+10.0"))
        OverviewViewer.handle(.accept, session: session, media: media)
        #expect(sent.last?.contains("player.playVideo()") == true)
        session.video.receive(#"{"type":"status","state":1,"time":12.5,"duration":90,"muted":false}"#)
        #expect(session.video.playing && session.video.started && session.video.duration == 90)
        OverviewViewer.handle(.accept, session: session, media: media)
        #expect(sent.last?.contains("player.pauseVideo()") == true)
        OverviewViewer.handle(.toastAction, session: session, media: media)
        #expect(sent.last?.contains("player.mute()") == true)
        // M on a keyboard does what Y does: once the player reports the mute, it turns the sound on again
        session.video.receive(#"{"type":"status","state":1,"time":13,"duration":90,"muted":true}"#)
        OverviewViewer.handle(.mute, session: session, media: media)
        #expect(sent.last?.contains("player.unMute()") == true)
        OverviewViewer.handle(.previousTab, session: session, media: media)
        #expect(session.viewer == 0)
        OverviewViewer.handle(.nextTab, session: session, media: media)
        #expect(session.viewer == 1 && session.viewerDirection == 1)
        // A video that cannot play browses like a screenshot, and is left out of the carousel from now on
        player(media[1].id)
        session.video.receive(#"{"type":"error","code":150}"#)
        #expect(session.video.error == 150 && OverviewVideos.shared.unplayable.contains(media[1].id))
        // Only L1 and R1 browse: there the D-pad walks the dock (previous, next; next first) and A presses the focused one
        let count = sent.count
        OverviewViewer.handle(.right, session: session, media: media)
        #expect(session.viewer == 1 && session.video.controls.focus == .next)
        OverviewViewer.handle(.accept, session: session, media: media)
        #expect(sent.count == count && session.viewer == 2 && session.video.controls.focus == .next)
        OverviewViewer.handle(.nextTab, session: session, media: media)
        #expect(session.viewer == 3)
        OverviewViewer.handle(.left, session: session, media: media)
        #expect(session.viewer == 3 && session.video.controls.focus == .previous)
        OverviewViewer.handle(.accept, session: session, media: media)
        #expect(session.viewer == 2)
        OverviewViewer.handle(.back, session: session, media: media)
        #expect(session.viewerClosing)
    }

    @Test func viewerMorphPreservesSharedFocusAndReleasesPlayer() {
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: youTube)
        let media: [OverviewContent.Media] = [
            .init(kind: .video, id: "v", name: nil),
            .init(kind: .screenshot, id: "s", name: nil)
        ]
        session.viewer = 0
        session.video.reset("v")
        session.video.controls.focus = .previous
        session.video.run = { _ in }
        OverviewViewer.handle(.nextTab, session: session, media: media)
        #expect(session.viewer == 1 && session.video.controls.focus == .previous)
        #expect(session.video.videoID == nil && session.video.run == nil)
        OverviewViewer.handle(.previousTab, session: session, media: media)
        #expect(session.viewer == 0 && session.video.controls.focus == .previous)
        #expect(OverviewDockFocus.back.surviving(playable: false, direction: 1) == .previous)
        #expect(OverviewDockFocus.forward.surviving(playable: false, direction: -1) == .next)
        #expect(OverviewDockFocus.volume.surviving(playable: false, direction: -1) == .next)
        #expect(OverviewDockFocus.play.surviving(playable: false, direction: -1) == .previous)
        #expect(OverviewDockFocus.play.surviving(playable: false, direction: 1) == .next)
        #expect(OverviewDockFocus.close.surviving(playable: false, direction: 1) == .close)
    }

    @Test func viewerDockFocusAndSeekFlash() {
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: youTube)
        let media = OverviewContent(details: youTube, library: [], region: nil).media
        session.viewer = 0
        session.video.reset(media[0].id)
        var sent: [String] = []
        session.video.run = { sent.append($0) }
        let controls = session.video.controls
        // The timeline first; Down reaches play, Right walks to the sound, Up goes back, Up again reaches close
        OverviewViewer.handle(.down, session: session, media: media)
        #expect(controls.focus == .play)
        for _ in 0..<4 { OverviewViewer.handle(.right, session: session, media: media) }
        #expect(controls.focus == .volume)
        OverviewViewer.handle(.left, session: session, media: media)
        #expect(controls.focus == .volume && sent.last?.contains("player.setVolume(90)") == true)
        OverviewViewer.handle(.up, session: session, media: media)
        OverviewViewer.handle(.up, session: session, media: media)
        #expect(controls.focus == .close)
        OverviewViewer.handle(.down, session: session, media: media)
        #expect(controls.focus == .timeline)
        // Repeated seeks in one direction count up; the other direction starts over
        let start = ContinuousClock.now
        controls.seekFlash(1, at: start)
        controls.seekFlash(1, at: start + .milliseconds(400))
        #expect(controls.flash?.total == 20 && controls.flash?.direction == 1)
        controls.seekFlash(-1, at: start + .milliseconds(500))
        #expect(controls.flash?.total == 10 && controls.flash?.direction == -1)
        controls.seekFlash(-1, at: start + .seconds(2))
        #expect(controls.flash?.total == 10)
        // Paused or dragging: the overlay stays
        controls.paused = true
        controls.hideIfIdle(at: .now + .seconds(10))
        #expect(controls.visible)
        controls.paused = false
        controls.hideIfIdle(at: .now + .seconds(20))
        #expect(!controls.visible)
        // A press while hidden brings the focus home
        controls.focus = .mute
        OverviewViewer.handle(.down, session: session, media: media)
        #expect(controls.visible && controls.focus == .play)
    }

    /// The owner's measure: every dock glyph's ink bounds centre equals its button's centre within 1 px; play's ink centroid.
    @Test func dockGlyphsAreCentred() throws {
        _ = DelosFonts.register()
        let cases: [(String, Double, Bool)] = [
            (Symbols.playerPlay, 124, true), (Symbols.playerPause, 124, true), (Symbols.playerSeekBack, 92, false),
            (Symbols.playerSeekForward, 92, false), (Symbols.playerPrevious, 76, false), (Symbols.playerNext, 76, false),
            (Symbols.playerSound, 76, false), (Symbols.playerMuted, 76, false), (Symbols.playerVolumeLow, 76, false),
            (Symbols.playerVolumeNone, 76, false), (Symbols.close, 72, false),
        ]
        for (symbol, size, filled) in cases {
            let play = symbol == Symbols.playerPlay
            let view = InkSymbol(symbol: symbol, size: DockButton.glyph(size), color: RGBA(red: 1, green: 1, blue: 1), filled: filled, centroid: play)
                .frame(width: size, height: size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let ink = try #require(Self.ink(image))
            let centre = play ? ink.centroid : CGPoint(x: ink.bounds.midX, y: ink.bounds.midY)
            #expect(abs(centre.x - size / 2) <= 1 && abs(centre.y - size / 2) <= 1, "\(symbol.unicodeScalars.first!.value): \(centre) in \(size)")
        }
    }

    /// The alpha-weighted centroid and the bounds of [image]'s ink, pixels.
    private static func ink(_ image: CGImage) -> (bounds: CGRect, centroid: CGPoint)? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        var sum = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let a = Double(data[y * w + x]) / 255
                guard a > 0 else { continue }
                sum += a
                sx += a * (Double(x) + 0.5)
                sy += a * (Double(y) + 0.5)
                if a > 0.25 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard sum > 0, maxX >= 0 else { return nil }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), CGPoint(x: sx / sum, y: sy / sum))
    }

    @Test func playerErrorsAndClock() {
        #expect([100, 101, 150].allSatisfy(OverviewVideo.unplayable(code:)))
        #expect(![-1, 2, 5, 153].contains(where: OverviewVideo.unplayable(code:)))
        #expect(OverviewVideo.blocked(code: 101) && OverviewVideo.blocked(code: 150) && !OverviewVideo.blocked(code: 100))
        #expect(OverviewVideo.clock(0) == "0:00" && OverviewVideo.clock(75.9) == "1:15" && OverviewVideo.clock(3723) == "1:02:03")
        // A transient error shows, but the video stays in the carousel
        let video = OverviewVideo()
        video.reset("transient1")
        video.receive(#"{"type":"error","code":5}"#)
        #expect(video.error == 5 && !OverviewVideos.shared.unplayable.contains("transient1"))
    }

    @Test func unplayableVideosLeftOut() {
        let all = OverviewContent(details: youTube, library: [], region: nil).media
        let kept = OverviewContent(details: youTube, library: [], region: nil, unplayable: ["x7mer01"]).media
        #expect(all.filter { $0.kind == .video }.map(\.id) == ["x7mer01", "x7mer02"])
        #expect(kept.filter { $0.kind == .video }.map(\.id) == ["x7mer02"] && kept.count == all.count - 1 && kept.first?.kind == .video)
    }

    @Test func steamMediaComeFirstAndYouTubeOnlyFallsBack() throws {
        // Steam's movies, then Steam's screenshots; YouTube's videos and IGDB's screenshots are not shown
        let media = OverviewContent(details: complete, library: [], region: nil).media
        #expect(media.map(\.id).prefix(3) == ["steam-movie-257052901", "steam-movie-256938596", "steam-shot-0"])
        #expect(media.count == 11 && media.allSatisfy { $0.steam != nil })
        #expect(OverviewContent.youTubeVideos(complete).isEmpty)
        // Steam's 293 px poster is never shown: a movie takes Steam's first screenshot (600 px in the carousel, 1920 px
        // in the viewer); the screenshots their own two sizes
        let shot = try #require(media.first { $0.kind == .screenshot }?.steam)
        #expect(media[0].steam?.thumb == shot.thumb && media[0].steam?.full == shot.full)
        #expect(shot.thumb?.lastPathComponent.hasSuffix(".600x338.jpg") == true && shot.full?.lastPathComponent.hasSuffix(".1920x1080.jpg") == true)
        #expect(media[0].steam?.stream?.absoluteString.contains("hls_264_master.m3u8") == true)
        #expect(OverviewImageSizes.thumb(media[0], tall: true) == shot.thumb && OverviewImageSizes.full(media[0], tall: false) == shot.full)
        // No Steam screenshot: IGDB's screenshots, and the movies have no picture rather than a stretched poster
        var noShots = complete
        noShots.steam?.screenshots = []
        let fallback = OverviewContent(details: noShots, library: [], region: nil).media
        #expect(fallback.filter { $0.kind == .video }.allSatisfy { $0.steam?.thumb == nil && $0.steam?.full == nil })
        #expect(fallback.filter { $0.kind == .screenshot }.allSatisfy { $0.steam == nil } && fallback.count == 11)
        // A poster at least 600 px wide is the movie's own
        noShots.steam?.movies = [.init(id: 5, thumbnail: "https://shared.akamai.steamstatic.com/x/movie.640x360.jpg", mp4: "http://cdn.akamai.steamstatic.com/x/movie_max.mp4")]
        let own = try #require(OverviewContent(details: noShots, library: [], region: nil).media.first?.steam)
        #expect(own.thumb?.lastPathComponent == "movie.640x360.jpg" && own.stream?.absoluteString == "https://cdn.akamai.steamstatic.com/x/movie_max.mp4")
        // Steam's movies that AVPlayer cannot play (DASH or WebM only): YouTube's videos stay the fallback
        var dashOnly = complete
        dashOnly.steam?.movies = [.init(id: 6, dash: "https://video.akamai.steamstatic.com/x/dash_h264.mpd", webm: "https://video.akamai.steamstatic.com/x/movie_max.webm")]
        let videos = OverviewContent(details: dashOnly, library: [], region: nil).media.filter { $0.kind == .video }
        #if os(tvOS)
        #expect(videos.isEmpty)
        #else
        #expect(videos.map(\.id) == ["x7mer01", "x7mer02"] && videos.allSatisfy { $0.steam == nil })
        #endif
    }

    @Test func nativePlayerReportsLikeYouTubes() {
        let video = OverviewVideo()
        video.reset("steam-movie-1")
        video.report(state: 3, time: 0, duration: 0, muted: false, loaded: 0, volume: 100)
        #expect(video.playing && !video.started)
        video.report(state: 1, time: 2.5, duration: 90, muted: false, loaded: 0.25, volume: 100)
        #expect(video.duration == 90 && video.loaded == 0.25 && video.started)
        video.reset("steam-movie-1")
        video.firstFrame()
        #expect(video.started)
        // Without a player, the commands do nothing
        video.setVolume(40)
        #expect(video.volume == 100)
    }

    #if !os(tvOS)
    @Test func playerStaysOnItsPage() {
        let origin = "https://io.github.meitoncz.delos"
        let page = URL(string: "https://io.github.meitoncz.delos")
        #expect(OverviewVideoPlayer.allows(targetMainFrame: true, url: page, firstLoad: true, origin: origin))
        #expect(!OverviewVideoPlayer.allows(targetMainFrame: true, url: page, firstLoad: false, origin: origin))
        #expect(!OverviewVideoPlayer.allows(targetMainFrame: true, url: URL(string: "https://www.youtube.com/watch?v=x"), firstLoad: true, origin: origin))
        #expect(OverviewVideoPlayer.allows(targetMainFrame: true, url: URL(string: "about:blank"), firstLoad: false, origin: origin))
        #expect(OverviewVideoPlayer.allows(targetMainFrame: false, url: URL(string: "https://www.youtube-nocookie.com/embed/x"), firstLoad: false, origin: origin))
        #expect(!OverviewVideoPlayer.allows(targetMainFrame: nil, url: URL(string: "https://www.youtube.com/watch?v=x"), firstLoad: false, origin: origin))
        let html = OverviewVideoPlayer.html(videoID: "abc_DEF-123", origin: origin)
        #expect(html.contains("videoId:'abc_DEF-123'") && html.contains("origin:'\(origin)'") && html.contains("webkit.messageHandlers.delos"))
    }
    #endif

    @Test func overviewHints() {
        var hints = ScreenHints()
        hints.overview = true
        let shown = ShellHints.hints(ShellHints.Context(screen: .home(hostID: "h"), screenHints: hints), kind: .controller)
        #expect(shown.map(\Hint.button) == [HintButton.pad(.south), HintButton.pad(.east)])
    }

    @Test func viewerHints() {
        func shown(_ item: OverviewViewerItem) -> [Hint] {
            var hints = ScreenHints()
            hints.overview = true
            hints.overviewViewer = item
            return ShellHints.hints(ShellHints.Context(screen: .home(hostID: "h"), screenHints: hints), kind: .controller)
        }
        let pair = Hint(button: .pair(.leftShoulder, .rightShoulder), label: L("overview_hint_browse"))
        let browse = [Hint(button: .pad(.south), label: L("shell_hint_select")), pair, Hint(button: .pad(.east), label: L("shell_hint_back"))]
        #expect(shown(.screenshot) == browse)
        #expect(shown(.unplayable) == browse)
        let playing = shown(.video(playing: true, muted: false))
        #expect(playing.map(\Hint.button) == [.adjust, .pad(.south), .pad(.north), .pair(.leftShoulder, .rightShoulder), .pad(.east)])
        #expect(playing.map(\.label) == [L("overview_hint_seek"), L("overview_hint_pause"), L("overview_hint_mute"), L("overview_hint_browse"),
                                         L("shell_hint_back")])
        let onVolume = shown(.video(playing: true, muted: false, focus: .volume))
        #expect(onVolume[0].label == L("overview_video_volume") && onVolume[1].label == L("shell_hint_select"))
        let paused = shown(.video(playing: false, muted: true))
        #expect(paused[1].label == L("overview_hint_play") && paused[2].label == L("overview_hint_unmute"))
    }
}
