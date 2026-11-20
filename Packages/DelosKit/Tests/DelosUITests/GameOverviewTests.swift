import CoreGraphics
@testable import DelosData
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// The game overview (A · Descent): what it shows of sparse and complete data, its navigation, its scroll line and its
/// motion's arithmetic.
@MainActor
@Suite struct GameOverviewTests {
    private let complete = DemoOverview.complete(1)
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

    /// The open spring's overshoot only grows the cover around the slot, so the slot's edge never shows; the close
    /// spring's does the same around the card.
    @Test func flightOvershootOnlyGrowsAroundTheEnds() {
        let from = CGRect(x: 150, y: 520, width: 316.5, height: 474.75), to = CGRect(x: 150, y: 150, width: 340, height: 510)
        let past = OverviewMotion.flightFrame(from: from, to: to, progress: 1.04, lift: 30)
        #expect(past.contains(to) && abs(past.midX - to.midX) < 0.001 && abs(past.midY - to.midY) < 0.001)
        #expect(abs(past.width - to.width * 1.04) < 0.001)
        let before = OverviewMotion.flightFrame(from: from, to: to, progress: -0.015, lift: 30)
        #expect(before.contains(from) && abs(before.midY - from.midY) < 0.001)
    }

    @Test func ratingRingOvershootIsLimited() {
        #expect(OverviewMotion.ratingFill(ms: 0) == 0)
        #expect(OverviewMotion.ratingFill(ms: OverviewMotion.ratingRun) == 1)
        let samples = stride(from: 0.0, through: OverviewMotion.ratingRun, by: 4).map(OverviewMotion.ratingFill(ms:))
        // About 5.5 % past the target at most, reached near the spring's peak (≈ 438 ms)
        let peak = samples.max() ?? 0
        #expect(peak > 1.04 && peak < 1.06)
        // No second bounce: once past its peak it only comes down, never below the target
        let index = samples.firstIndex(of: peak) ?? 0
        #expect(abs(Double(index) * 4 - 438) < 12)
        for (a, b) in zip(samples[index...], samples[(index + 1)...]) { #expect(b <= a + 1e-9 && b >= 1) }
    }

    /// Regression: a touch's first tap focused a thumbnail (the focused-screenshot backdrop), the viewer opened and
    /// closed, and a finger scrolled back to the header: the backdrop stayed darker and shrank with the scroll.
    @Test func touchScrollLeavesTheFocusedScreenshotBackdrop() {
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: nil)
        let header = (deep: session.backdropDeep(scroll: 0), zoom: OverviewMotion.heroZoom(0))
        session.scroll = 1400
        session.mediaFocus = 2
        #expect(session.backdropDeep(scroll: 1400) == 1)
        session.pageScrollBegan()
        session.scroll = 0
        #expect(session.mediaFocus == nil)
        #expect(session.backdropDeep(scroll: 0) == header.deep && OverviewMotion.heroZoom(0) == header.zoom)
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
        var opened: (Int, Double)?
        launcher.canOpen = { _ in true }
        launcher.open = { app, drag in opened = (app.id, drag) }
        let app = HostApp(id: 7, title: "Hades")
        // Sideways is the row's, not a swipe
        launcher.drag(app, translation: CGSize(width: 40, height: -12), slop: 10)
        #expect(launcher.dragApp == nil)
        launcher.drag(app, translation: CGSize(width: 2, height: -60), slop: 10)
        #expect(launcher.dragApp == 7 && launcher.dragOffset < 0 && launcher.dragOffset > -60)
        launcher.end(app, translation: CGSize(width: 2, height: -120), threshold: 90)
        #expect(opened?.0 == 7 && (opened?.1 ?? 0) < 0)
        #expect(launcher.dragApp == nil)
        // Short of the threshold the cover springs back
        opened = nil
        launcher.drag(app, translation: CGSize(width: 0, height: -40), slop: 10)
        launcher.end(app, translation: CGSize(width: 0, height: -40), threshold: 90)
        #expect(opened == nil && launcher.dragApp == nil)
    }

    @Test func viewerIsEdgeToEdge() {
        let item = OverviewContent.Media(kind: .video, id: "v", name: nil)
        #expect(OverviewViewer.frame(item, width: 1920, height: 1080) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(OverviewViewer.frame(.init(kind: .screenshot, id: "s", name: nil), width: 1920, height: 1440) == CGRect(x: 0, y: 0, width: 1920, height: 1440))
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
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: complete)
        let media = OverviewContent(details: complete, library: [], region: nil).media
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
        let count = sent.count
        OverviewViewer.handle(.accept, session: session, media: media)
        #expect(sent.count == count)
        OverviewViewer.handle(.right, session: session, media: media)
        #expect(session.viewer == 2)
        OverviewViewer.handle(.right, session: session, media: media)
        #expect(session.viewer == 3)
        OverviewViewer.handle(.back, session: session, media: media)
        #expect(session.viewerClosing)
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
        let all = OverviewContent(details: complete, library: [], region: nil).media
        let kept = OverviewContent(details: complete, library: [], region: nil, unplayable: ["x7mer01"]).media
        #expect(all.filter { $0.kind == .video }.map(\.id) == ["x7mer01", "x7mer02"])
        #expect(kept.filter { $0.kind == .video }.map(\.id) == ["x7mer02"] && kept.count == all.count - 1 && kept.first?.kind == .video)
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
        let browse = [Hint(button: .adjust, label: L("overview_hint_browse")), Hint(button: .pad(.east), label: L("shell_hint_back"))]
        #expect(shown(.screenshot) == browse)
        #expect(shown(.unplayable) == browse)
        let playing = shown(.video(playing: true, muted: false))
        #expect(playing.map(\Hint.button) == [.adjust, .pad(.south), .pad(.north), .pad(.leftShoulder), .pad(.rightShoulder), .pad(.east)])
        #expect(playing.map(\.label) == [L("overview_hint_seek"), L("overview_hint_pause"), L("overview_hint_mute"), L("overview_previous"),
                                         L("overview_next"), L("shell_hint_back")])
        let paused = shown(.video(playing: false, muted: true))
        #expect(paused[1].label == L("overview_hint_play") && paused[2].label == L("overview_hint_unmute"))
    }
}
