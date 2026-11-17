import Foundation

/// What is recorded of one app (`Playtime` of DELOS for Android): the summed connected time and when time was last
/// added; both zero: never streamed.
public struct Playtime: Equatable, Sendable {
    public var totalSeconds: Double
    public var lastStreamed: Date?

    public init(totalSeconds: Double = 0, lastStreamed: Date? = nil) {
        self.totalSeconds = totalSeconds
        self.lastStreamed = lastStreamed
    }

    public static let none = Playtime()
}

/// Streaming time per profile, PC and app (`PlaytimeStore` of DELOS for Android), in `UserDefaults`: the total and the
/// time of the last addition stay on the device and have no reset; deleting a profile removes them.
public struct PlaytimeStore: Sendable {
    private let suiteName: String?

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String, _ hostID: String, _ appID: Int) -> String { "playtime.\(profile).\(hostID).\(appID)" }

    public func playtime(profile: String, hostID: String, appID: Int) -> Playtime {
        guard let stored = defaults.array(forKey: key(profile, hostID, appID)) as? [Double], stored.count == 2 else { return .none }
        return Playtime(totalSeconds: max(stored[0], 0), lastStreamed: stored[1] > 0 ? Date(timeIntervalSince1970: stored[1]) : nil)
    }

    /// Adds [seconds] to one app's total and stamps its last-streamed time.
    public func add(_ seconds: Double, profile: String, hostID: String, appID: Int, at now: Date = Date()) {
        guard seconds > 0 else { return }
        let total = playtime(profile: profile, hostID: hostID, appID: appID).totalSeconds + seconds
        defaults.set([total, now.timeIntervalSince1970], forKey: key(profile, hostID, appID))
    }

    /// A profile's whole streaming time: every app's total on every PC added up, and the latest of their last-streamed
    /// times (the side menu's summary).
    public func total(profile: String) -> Playtime {
        let prefix = "playtime.\(profile)."
        var total = Playtime.none
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let stored = value as? [Double], stored.count == 2 else { continue }
            total.totalSeconds += max(stored[0], 0)
            if stored[1] > 0 {
                let last = Date(timeIntervalSince1970: stored[1])
                total.lastStreamed = max(total.lastStreamed ?? last, last)
            }
        }
        return total
    }

    /// Forgets a removed profile's times.
    public func remove(profile: String) {
        let prefix = "playtime.\(profile)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    }
}

/// The "Streaming time" amount (`PlaytimeFormat.amount` of DELOS for Android): minutes under one hour, hours with one
/// decimal from one hour up; no time at all is 0 hours, under one minute counts as one minute.
public enum PlaytimeAmount: Equatable, Sendable {
    case minutes(Int)
    /// Hours times ten (204 is 20.4 hours).
    case tenthsOfHours(Int)

    public init(seconds: Double) {
        let millis = Int64((seconds * 1000).rounded())
        let minute: Int64 = 60_000, hour = 60 * minute
        if millis <= 0 {
            self = .tenthsOfHours(0)
        } else if millis < hour {
            self = .minutes(Int(max(millis / minute, 1)))
        } else {
            self = .tenthsOfHours(Int((millis * 10 + hour / 2) / hour))
        }
    }
}

/// The "Last streamed" day (`LastStreamed.relative` of DELOS for Android): calendar days of [calendar]'s time zone, so a
/// stream at 23:50 is "Yesterday" at 00:10; a time in the future (a clock set back) counts as today.
public enum LastStreamed: Equatable, Sendable {
    case never, today, yesterday
    case days(Int)
    case weeks(Int)
    case date(Date)

    public init(_ last: Date?, now: Date = Date(), calendar: Calendar = .current) {
        guard let last else {
            self = .never
            return
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
        self = switch days {
        case ...0: .today
        case 1: .yesterday
        case 2..<7: .days(days)
        case _ where days / 7 <= 4: .weeks(days / 7)
        default: .date(last)
        }
    }
}

/// When each game of a PC was last started, per profile (`playedTimes` of DELOS for Android's `PcRepository`): the
/// library lists the running game first, then the played ones from the most recent, then the others in the PC's order,
/// and the first cover of a played game says "Last played".
public struct PlayedGames: Sendable {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String, _ hostID: String) -> String { "played.\(profile).\(hostID)" }

    /// App id → when it was last started.
    public func times(profile: String, hostID: String) -> [Int: Date] {
        let stored = defaults.dictionary(forKey: key(profile, hostID)) as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { id, time in Int(id).map { ($0, Date(timeIntervalSince1970: time)) } })
    }

    /// The game last started, if any.
    public func last(profile: String, hostID: String) -> Int? {
        times(profile: profile, hostID: hostID).max { $0.value < $1.value }?.key
    }

    public func markStarted(profile: String, hostID: String, appID: Int, at now: Date = Date()) {
        var stored = defaults.dictionary(forKey: key(profile, hostID)) as? [String: Double] ?? [:]
        stored[String(appID)] = now.timeIntervalSince1970
        defaults.set(stored, forKey: key(profile, hostID))
    }

    /// Forgets a removed profile's games.
    public func remove(profile: String) {
        let prefix = "played.\(profile)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    }

    /// [ids] (the PC's order) with the running game first, then the played ones from the most recent.
    public static func order(_ ids: [Int], played: [Int: Date], running: Int?) -> [Int] {
        let recent = ids.filter { played[$0] != nil }.sorted { played[$0]! > played[$1]! }
        var ordered = recent + ids.filter { played[$0] == nil }
        if let running, let index = ordered.firstIndex(of: running) {
            ordered.remove(at: index)
            ordered.insert(running, at: 0)
        }
        return ordered
    }
}
