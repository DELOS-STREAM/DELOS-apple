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
        let start = OverviewMotion.flightTransform(from: from, to: to, progress: 0)
        #expect(abs(start.dy - 370) < 0.001 && abs(start.sx - from.width / to.width) < 0.001)
        let end = OverviewMotion.flightTransform(from: from, to: to, progress: 1)
        #expect(end.dx == 0 && end.dy == 0 && end.sx == 1 && end.sy == 1)
        let middle = OverviewMotion.flightTransform(from: from, to: to, progress: 0.5)
        // Above the straight line and a little larger at the middle
        #expect(middle.dy < 185 && middle.sx > (from.width / to.width + 1) / 2)
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

    @Test func viewerFitsSixteenByNine() {
        let odin = OverviewViewer.fit(width: 1920, height: 1080)
        #expect(odin.height == 780 && abs(odin.width - 780 * 16 / 9) < 0.001)
        let ipad = OverviewViewer.fit(width: 1920, height: 1440)
        #expect(ipad.width == 1640 && abs(ipad.height - 922.5) < 0.001)
    }

    @Test func viewerCommands() {
        let session = OverviewSession(hostID: "h", app: HostApp(id: 1, title: "G"), coverID: AnyHashable("app-1"), source: .zero, details: complete)
        let media = OverviewContent(details: complete, library: [], region: nil).media
        session.viewer = 0
        OverviewViewer.handle(.left, session: session, media: media, openURL: .init(handler: { _ in .handled }))
        #expect(session.viewer == 0)
        OverviewViewer.handle(.right, session: session, media: media, openURL: .init(handler: { _ in .handled }))
        #expect(session.viewer == 1 && session.viewerDirection == 1)
        OverviewViewer.handle(.back, session: session, media: media, openURL: .init(handler: { _ in .handled }))
        #expect(session.viewerClosing)
    }

    @Test func overviewHints() {
        var hints = ScreenHints()
        hints.overview = true
        let shown = ShellHints.hints(ShellHints.Context(screen: .home(hostID: "h"), screenHints: hints), kind: .controller)
        #expect(shown.map(\Hint.button) == [HintButton.pad(.south), HintButton.pad(.east)])
    }
}
