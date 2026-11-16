import DelosHost
import Foundation
import Testing
@testable import DelosData

/// Decision L7 of the plan (the storage of hosts, profiles and settings on Apple TV). tvOS has no persistent files: the
/// system may empty the caches whenever space is short, and `UserDefaults` is the one local store that stays (Apple's
/// limit for it is 500 KB). So every record the app needs after a restart is kept in `UserDefaults` on every platform
/// and read back at launch, and nothing essential is in a file; what is in files (the images and the artwork matches)
/// is found or downloaded again. These tests restart the stores without any file.
@MainActor
@Suite struct StorageMirrorTests {
    /// A `UserDefaults` suite of its own, removed afterwards.
    private final class Suite {
        let name = "delos.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        deinit { UserDefaults().removePersistentDomain(forName: name) }
    }

    /// The `UserDefaults` limit of Apple TV.
    private static let tvOSLimit = 500_000

    private func host(_ id: String, name: String) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state>\
        <mac>AA:BB:CC:DD:EE:FF</mac></root>
        """
        let info = try ServerInfo.parse(Data(xml.utf8))
        let record = HostRecord(firstReply: ServerInfoReply(info: info, address: HostAddress(host: "192.168.1.5", port: 47989), source: .plainHTTP))
        // The size of a real pinned certificate (an RSA 2048 certificate is about 800 bytes)
        return record.paired(with: HostPin(certificate: Data((0..<900).map { UInt8(truncatingIfNeeded: $0 &* 7) }), httpsPort: 47984))
    }

    /// Everything the app keeps for [profileCount] profiles, [hostCount] PCs and [appCount] apps on each PC.
    private func fill(_ suite: Suite, profileCount: Int, hostCount: Int, appCount: Int) throws -> (HostStore, ProfileStore) {
        let hosts = HostStore(defaults: suite.defaults)
        for index in 0..<hostCount { hosts.store(try host("HOST\(index)", name: "Gaming PC \(index)")) }
        let profiles = ProfileStore(suiteName: suite.name)
        let playtimes = PlaytimeStore(suiteName: suite.name)
        let played = PlayedGames(suiteName: suite.name)
        for index in 0..<profileCount {
            let profile = try #require(profiles.create(name: "Player \(index)", avatar: index))
            profiles.setDefaultPC("HOST0")
            var appearance = Appearance()
            appearance.dark = false
            appearance.uiScale = 120
            AppearanceStore(suiteName: suite.name).save(appearance, profile: profile.id)
            var stream = StreamSettings()
            stream.fps = 90
            StreamSettingsStore(suiteName: suite.name).save(stream, profile: profile.id)
            for hostIndex in 0..<hostCount {
                for app in 0..<appCount {
                    playtimes.add(3600 + Double(app), profile: profile.id, hostID: "HOST\(hostIndex)", appID: 1000 + app)
                    played.markStarted(profile: profile.id, hostID: "HOST\(hostIndex)", appID: 1000 + app)
                }
            }
        }
        return (hosts, profiles)
    }

    @Test func everythingTheAppNeedsComesBackAtLaunchFromUserDefaultsAlone() throws {
        let suite = Suite()
        let (hosts, profiles) = try fill(suite, profileCount: 3, hostCount: 2, appCount: 5)
        let current = try #require(profiles.current)
        hosts.rename("HOST1", to: "Living room")

        // A new launch: new stores over the same defaults, no file of the old one
        let hostsAgain = HostStore(defaults: suite.defaults)
        let profilesAgain = ProfileStore(suiteName: suite.name)
        #expect(hostsAgain.paired.map(\.id) == ["HOST0", "HOST1"])
        #expect(hostsAgain.host("HOST1")?.name == "Living room")
        #expect(hostsAgain.host("HOST0")?.pin == hosts.host("HOST0")?.pin)
        #expect(profilesAgain.profiles == profiles.profiles)
        #expect(profilesAgain.current == current)
        #expect(profilesAgain.startup.defaultPC == "HOST0")
        #expect(AppearanceStore(suiteName: suite.name).load(profile: current.id).uiScale == 120)
        #expect(!AppearanceStore(suiteName: suite.name).load(profile: current.id).dark)
        #expect(StreamSettingsStore(suiteName: suite.name).load(profile: current.id).fps == 90)
        #expect(PlaytimeStore(suiteName: suite.name).playtime(profile: current.id, hostID: "HOST1", appID: 1003).totalSeconds == 3603)
        #expect(PlayedGames(suiteName: suite.name).times(profile: current.id, hostID: "HOST1").count == 5)
    }

    @Test func aHeavyUseStaysFarBelowTheLimitOfAppleTV() throws {
        let suite = Suite()
        // More than anyone has: 6 profiles, 4 PCs, 80 apps on each (about 217 KB measured, the playtimes being the most)
        _ = try fill(suite, profileCount: 6, hostCount: 4, appCount: 80)
        let stored = try #require(UserDefaults(suiteName: suite.name)?.persistentDomain(forName: suite.name))
        let size = try PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0).count
        #expect(size < Self.tvOSLimit * 6 / 10, "the app's UserDefaults take \(size) bytes, Apple TV allows \(Self.tvOSLimit)")
    }

    @Test func theArtworkMatchesAreInTheCachesOnAppleTVAndNotInApplicationSupport() {
        let path = ArtworkStore.defaultMatchesDirectory.path
        #if os(tvOS)
        #expect(path.contains("/Library/Caches/"))
        #else
        #expect(path.contains("/Application Support/"))
        #endif
    }
}
