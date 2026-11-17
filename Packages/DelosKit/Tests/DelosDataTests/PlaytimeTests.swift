import Foundation
import Testing
@testable import DelosData

@Suite struct PlaytimeTests {
    private func suite() -> String { "delos.tests.\(UUID().uuidString)" }

    @Test func theAmountIsMinutesUnderAnHourThenTenthsOfHours() {
        // PlaytimeFormatTest of DELOS for Android
        #expect(PlaytimeAmount(seconds: 0) == .tenthsOfHours(0))
        #expect(PlaytimeAmount(seconds: -5) == .tenthsOfHours(0))
        #expect(PlaytimeAmount(seconds: 1) == .minutes(1))
        #expect(PlaytimeAmount(seconds: 59 * 60 + 59) == .minutes(59))
        #expect(PlaytimeAmount(seconds: 3600) == .tenthsOfHours(10))
        #expect(PlaytimeAmount(seconds: 20.4 * 3600) == .tenthsOfHours(204))
        // Rounded to the nearest tenth: 1 h 2 min 59 s is 1.0, 1 h 3 min is 1.1
        #expect(PlaytimeAmount(seconds: 3600 + 179) == .tenthsOfHours(10))
        #expect(PlaytimeAmount(seconds: 3600 + 180) == .tenthsOfHours(11))
    }

    @Test func lastStreamedCountsCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
        func date(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text)) }
        let now = try date("2026-11-16T00:10:00+01:00")
        #expect(LastStreamed(nil, now: now, calendar: calendar) == .never)
        #expect(LastStreamed(try date("2026-11-16T00:05:00+01:00"), now: now, calendar: calendar) == .today)
        // A clock set back: a time in the future is today
        #expect(LastStreamed(try date("2026-11-17T10:00:00+01:00"), now: now, calendar: calendar) == .today)
        // 23:50 the evening before is yesterday at 00:10
        #expect(LastStreamed(try date("2026-11-15T23:50:00+01:00"), now: now, calendar: calendar) == .yesterday)
        #expect(LastStreamed(try date("2026-11-14T12:00:00+01:00"), now: now, calendar: calendar) == .days(2))
        #expect(LastStreamed(try date("2026-11-10T12:00:00+01:00"), now: now, calendar: calendar) == .days(6))
        #expect(LastStreamed(try date("2026-11-09T12:00:00+01:00"), now: now, calendar: calendar) == .weeks(1))
        #expect(LastStreamed(try date("2026-10-19T12:00:00+02:00"), now: now, calendar: calendar) == .weeks(4))
        // Up to 34 days are weeks (34 / 7 is 4), 35 days are a date
        #expect(LastStreamed(try date("2026-10-13T12:00:00+02:00"), now: now, calendar: calendar) == .weeks(4))
        let old = try date("2026-10-12T12:00:00+02:00")
        #expect(LastStreamed(old, now: now, calendar: calendar) == .date(old))
    }

    @Test func timeIsAddedPerProfilePCAndAppAndRemovedWithTheProfile() throws {
        let name = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = PlaytimeStore(suiteName: name)
        #expect(store.playtime(profile: "a", hostID: "PC", appID: 1) == .none)
        let first = Date(timeIntervalSince1970: 1_000), second = Date(timeIntervalSince1970: 2_000)
        store.add(90, profile: "a", hostID: "PC", appID: 1, at: first)
        store.add(30, profile: "a", hostID: "PC", appID: 1, at: second)
        store.add(0, profile: "a", hostID: "PC", appID: 1, at: Date(timeIntervalSince1970: 3_000))
        #expect(store.playtime(profile: "a", hostID: "PC", appID: 1) == Playtime(totalSeconds: 120, lastStreamed: second))
        #expect(store.playtime(profile: "b", hostID: "PC", appID: 1) == .none)
        #expect(store.playtime(profile: "a", hostID: "PC", appID: 2) == .none)
        store.remove(profile: "a")
        #expect(store.playtime(profile: "a", hostID: "PC", appID: 1) == .none)
    }

    @Test func aProfilesTotalAddsEveryAppOnEveryPCAndKeepsTheLatestDay() throws {
        let name = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = PlaytimeStore(suiteName: name)
        #expect(store.total(profile: "a") == .none)
        let first = Date(timeIntervalSince1970: 1_000), second = Date(timeIntervalSince1970: 2_000)
        store.add(90, profile: "a", hostID: "PC", appID: 1, at: second)
        store.add(30, profile: "a", hostID: "PC", appID: 2, at: first)
        store.add(600, profile: "a", hostID: "Other", appID: 1, at: first)
        // Another profile, and one whose id starts the same, stay apart
        store.add(45, profile: "b", hostID: "PC", appID: 1, at: second)
        store.add(45, profile: "ab", hostID: "PC", appID: 1, at: Date(timeIntervalSince1970: 9_000))
        #expect(store.total(profile: "a") == Playtime(totalSeconds: 720, lastStreamed: second))
        #expect(store.total(profile: "b") == Playtime(totalSeconds: 45, lastStreamed: second))
    }

    @Test func theLibraryListsTheRunningGameThenThePlayedOnesFromTheMostRecent() throws {
        let name = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let played = PlayedGames(suiteName: name)
        #expect(played.last(profile: "a", hostID: "PC") == nil)
        played.markStarted(profile: "a", hostID: "PC", appID: 3, at: Date(timeIntervalSince1970: 100))
        played.markStarted(profile: "a", hostID: "PC", appID: 5, at: Date(timeIntervalSince1970: 200))
        #expect(played.last(profile: "a", hostID: "PC") == 5)
        #expect(played.last(profile: "b", hostID: "PC") == nil)
        let times = played.times(profile: "a", hostID: "PC")
        #expect(PlayedGames.order([1, 2, 3, 4, 5], played: times, running: nil) == [5, 3, 1, 2, 4])
        #expect(PlayedGames.order([1, 2, 3, 4, 5], played: times, running: 4) == [4, 5, 3, 1, 2])
        #expect(PlayedGames.order([1, 2], played: times, running: 9) == [1, 2])
        played.remove(profile: "a")
        #expect(played.times(profile: "a", hostID: "PC").isEmpty)
    }
}

@MainActor
@Suite struct PlaytimeTrackerTests {
    private final class Ledger {
        var now = 0.0
        var slices: [Double] = []
    }

    private func tracker(_ ledger: Ledger) -> PlaytimeTracker {
        PlaytimeTracker(clock: { ledger.now }, sink: { ledger.slices.append($0) })
    }

    @Test func theSlicesAddUpToTheConnectedTime() {
        let ledger = Ledger()
        let tracker = tracker(ledger)
        ledger.now = 5
        tracker.flush()
        #expect(ledger.slices.isEmpty, "not started: nothing counts")
        tracker.start()
        ledger.now += 30
        tracker.flush()
        ledger.now += 12
        tracker.end()
        tracker.end()
        ledger.now += 100
        tracker.flush()
        #expect(ledger.slices == [30, 12])
        #expect(!tracker.running)
    }

    @Test func startingWhileCountingChangesNothingAndItCanStartAgain() {
        let ledger = Ledger()
        let tracker = tracker(ledger)
        tracker.start()
        ledger.now += 10
        tracker.start()
        ledger.now += 10
        tracker.end()
        ledger.now += 50
        tracker.start()
        ledger.now += 3
        tracker.end()
        #expect(ledger.slices == [20, 3])
    }

    @Test func theStoreKeepsTheTotalAndTheDayOfTheLastAdditionPerProfileHostAndApp() {
        let store = PlaytimeStore(suiteName: "delos.tests.\(UUID().uuidString)")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        store.add(30, profile: "p", hostID: "h", appID: 7, at: day)
        store.add(12, profile: "p", hostID: "h", appID: 7, at: day.addingTimeInterval(60))
        store.add(5, profile: "p", hostID: "h", appID: 8, at: day)
        #expect(store.playtime(profile: "p", hostID: "h", appID: 7) == Playtime(totalSeconds: 42, lastStreamed: day.addingTimeInterval(60)))
        #expect(store.playtime(profile: "p", hostID: "h", appID: 8).totalSeconds == 5)
        #expect(store.playtime(profile: "q", hostID: "h", appID: 7) == .none)
    }
}
