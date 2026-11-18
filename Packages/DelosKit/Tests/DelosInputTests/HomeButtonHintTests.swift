import Testing
@testable import DelosInput

/// The system's Home button settings as a test sets them.
@MainActor
private final class FakeHomeSettings: HomeButtonSettingsReader {
    var action: HomeButtonInAppAction
    var reads = 0
    var opened = 0
    var opens = true

    init(_ action: HomeButtonInAppAction) { self.action = action }

    func inAppAction() -> HomeButtonInAppAction {
        reads += 1
        return action
    }

    func openInAppActionSettings() -> Bool {
        opened += 1
        return opens
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> { Task {} }
}

/// The events a hint asked for, in order.
@MainActor
private final class EventLog {
    var events: [HomeButtonHint.Event] = []
}

@MainActor
@Suite struct HomeButtonHintTests {
    private func hint(_ action: HomeButtonInAppAction) -> (HomeButtonHint, FakeHomeSettings, () -> [HomeButtonHint.Event]) {
        let reader = FakeHomeSettings(action)
        let log = EventLog()
        let hint = HomeButtonHint(reader: reader) { log.events.append($0) }
        return (hint, reader, { log.events })
    }

    @Test func aControllerWhoseHomeTheSystemKeepsAsksForTheNotice() {
        let (hint, _, events) = hint(.systemDefault)
        hint.controllerConnected(hasHomeButton: true)
        #expect(events() == [.show])
        #expect(hint.shownThisLaunch)
    }

    @Test func noNoticeWhenHomeReachesTheAppOrTheSettingCannotBeRead() {
        for action in [HomeButtonInAppAction.deferred, .disabled, .unavailable] {
            let (hint, _, events) = hint(action)
            hint.controllerConnected(hasHomeButton: true)
            #expect(events().isEmpty)
            #expect(!hint.shownThisLaunch)
        }
    }

    @Test func aControllerWithoutHomeNeverReadsTheSetting() {
        let (hint, reader, events) = hint(.systemDefault)
        hint.controllerConnected(hasHomeButton: false)
        #expect(events().isEmpty)
        #expect(reader.reads == 0)
    }

    @Test func theNoticeComesOncePerLaunch() {
        let (hint, _, events) = hint(.systemDefault)
        hint.controllerConnected(hasHomeButton: true)
        hint.controllerConnected(hasHomeButton: true)
        hint.settingsChanged()
        hint.controllerConnected(hasHomeButton: true)
        #expect(events() == [.show])
    }

    @Test func theNoticeGoesWhenTheSettingDefersToTheApp() {
        let (hint, reader, events) = hint(.systemDefault)
        hint.controllerConnected(hasHomeButton: true)
        reader.action = .deferred
        hint.settingsChanged()
        hint.settingsChanged()
        #expect(events() == [.show, .hide])
        // Back to the system: the notice stays gone for this launch
        reader.action = .systemDefault
        hint.settingsChanged()
        hint.controllerConnected(hasHomeButton: true)
        #expect(events() == [.show, .hide])
    }

    @Test func aChangeWithoutTheNoticeHidesNothing() {
        let (hint, _, events) = hint(.deferred)
        hint.settingsChanged()
        #expect(events().isEmpty)
    }

    @Test func theActionOpensTheSystemsPage() {
        let (hint, reader, _) = hint(.systemDefault)
        #expect(hint.openSettings())
        reader.opens = false
        #expect(!hint.openSettings())
        #expect(reader.opened == 2)
    }

    @Test func theNoticeNamesTheWayToTheMenuThisDeviceHas() {
        #expect(StreamMenuWay.choose(touch: true, swipeOn: true, keyboard: true) == .swipe)
        #expect(StreamMenuWay.choose(touch: true, swipeOn: false, keyboard: true) == .keys)
        #expect(StreamMenuWay.choose(touch: true, swipeOn: false, keyboard: false) == .buttons)
        #expect(StreamMenuWay.choose(touch: false, swipeOn: true, keyboard: true) == .keys)
        #expect(StreamMenuWay.choose(touch: false, swipeOn: true, keyboard: false) == .buttons)
    }
}
