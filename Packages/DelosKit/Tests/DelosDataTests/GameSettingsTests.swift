import DelosMedia
import Foundation
import Testing
@testable import DelosData

@Suite struct GameSettingsTests {
    private func store() -> GameSettingsStore { GameSettingsStore(suiteName: "delos.tests.\(UUID().uuidString)") }

    private func profile() -> StreamSettings {
        var settings = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080), fps: 60, bitrateKbps: 30_000)
        settings.codec = .hevc
        settings.framePacing = .balanced
        return settings
    }

    @Test func anAppThatOverridesNothingFollowsTheProfile() {
        let none = GameSettingsOverride()
        #expect(none.isEmpty && none.count == 0)
        #expect(none.merged(onto: profile()) == profile())
    }

    @Test func overridesLieOverTheProfileAndTheRestFollowsIt() {
        var game = GameSettingsOverride()
        game.resolution = .fixed(StreamResolution(width: 1280, height: 720))
        game.fps = 120
        game.playAudioOnHost = true
        let merged = game.merged(onto: profile())
        #expect(merged.resolution == StreamResolution(width: 1280, height: 720) && merged.fps == 120 && merged.playAudioOnHost)
        #expect(merged.bitrateKbps == 30_000 && merged.codec == .hevc && merged.framePacing == .balanced)
        // A later edit of the profile shows through every setting the app does not override
        var edited = profile()
        edited.bitrateKbps = 50_000
        edited.fps = 30
        #expect(game.merged(onto: edited).bitrateKbps == 50_000 && game.merged(onto: edited).fps == 120)
    }

    @Test func theDisplaysOwnResolutionIsAnOverrideToo() {
        var game = GameSettingsOverride()
        game.resolution = .automatic
        #expect(game.merged(onto: profile()).resolution == nil)
        #expect(game.keys == [.resolution])
    }

    @Test func anEditMakesOnlyWhatItChangedCustomEvenWhenItEqualsTheProfile() {
        var game = GameSettingsOverride()
        var after = profile()
        after.codec = .h264
        game.record(from: profile(), to: after)
        #expect(game.keys == [.codec] && game.codec == .h264)
        // Going back to the profile's value is still an override: only a reset removes it
        game.record(from: after, to: profile())
        #expect(game.codec == .hevc && game.keys == [.codec])
        // Nothing changed, nothing recorded
        var untouched = GameSettingsOverride()
        untouched.record(from: profile(), to: profile())
        #expect(untouched.isEmpty)
    }

    @Test func aRowResetsAndTheUndoPutsBackOnlyWhatIsMissing() {
        var game = GameSettingsOverride()
        game.fps = 90
        game.codec = .av1
        game.playAudioOnHost = true
        let backup = game
        game.reset(.frameRate)
        game.reset(.codec)
        game.reset(.hostAudio)
        #expect(game.isEmpty)
        // Changed since the reset: kept, not overwritten by the backup
        game.codec = .h264
        game.restoreMissing(from: backup)
        #expect(game.fps == 90 && game.codec == .h264 && game.playAudioOnHost == true)
    }

    @Test func storedOverridesAreSparseAndKeptPerProfilePCAndApp() {
        let store = store()
        var game = GameSettingsOverride()
        game.fps = 120
        store.save(game, profile: "a", hostID: "pc1", appID: 7)
        #expect(store.load(profile: "a", hostID: "pc1", appID: 7) == game)
        #expect(store.load(profile: "a", hostID: "pc1", appID: 8).isEmpty)
        #expect(store.load(profile: "a", hostID: "pc2", appID: 7).isEmpty)
        #expect(store.load(profile: "b", hostID: "pc1", appID: 7).isEmpty)
        #expect(store.customApps(profile: "a", hostID: "pc1") == [7])
        // Resetting the last override leaves no entry
        store.save(GameSettingsOverride(), profile: "a", hostID: "pc1", appID: 7)
        #expect(store.customApps(profile: "a", hostID: "pc1").isEmpty)
    }

    @Test func aNewProfileCopiesTheOverridesAndLaterEditsAreIndependent() {
        let store = store()
        var game = GameSettingsOverride()
        game.fps = 120
        store.save(game, profile: "a", hostID: "pc1", appID: 7)
        store.copy(from: "a", to: "b")
        #expect(store.load(profile: "b", hostID: "pc1", appID: 7) == game)
        game.fps = 30
        store.save(game, profile: "b", hostID: "pc1", appID: 7)
        #expect(store.load(profile: "a", hostID: "pc1", appID: 7).fps == 120)
    }

    @Test func removingAProfileOrAPCForgetsTheirOverrides() {
        let store = store()
        var game = GameSettingsOverride()
        game.fps = 120
        for (profile, host, app) in [("a", "pc1", 1), ("a", "pc2", 1), ("b", "pc1", 1), ("b", "pc2", 2)] {
            store.save(game, profile: profile, hostID: host, appID: app)
        }
        store.remove(hostID: "pc1")
        #expect(store.customApps(profile: "a", hostID: "pc1").isEmpty && store.customApps(profile: "b", hostID: "pc1").isEmpty)
        #expect(store.customApps(profile: "a", hostID: "pc2") == [1])
        store.remove(profile: "a")
        #expect(store.customApps(profile: "a", hostID: "pc2").isEmpty)
        #expect(store.customApps(profile: "b", hostID: "pc2") == [2])
    }

    @Test func aValueTheAppCannotReadFollowsTheProfileAndNumbersAreClamped() throws {
        let json = Data(#"{"codec":"removed-codec","fps":99999,"bitrateKbps":5,"resolution":{"fixed":{"_0":{"width":0,"height":0}}},"playAudioOnHost":true}"#.utf8)
        let game = try JSONDecoder().decode(GameSettingsOverride.self, from: json)
        #expect(game.codec == nil && game.resolution == nil)
        #expect(game.fps == 1000 && game.bitrateKbps == StreamSettings.bitrateRange.lowerBound && game.playAudioOnHost == true)
        let round = try JSONDecoder().decode(GameSettingsOverride.self, from: JSONEncoder().encode(game))
        #expect(round == game)
    }

    @Test func hdrIsAnOverrideOfItsOwn() throws {
        var game = GameSettingsOverride()
        var after = StreamSettings()
        after.hdr = true
        game.record(from: StreamSettings(), to: after)
        #expect(game.hdr == true && game.keys == [.hdr])
        #expect(game.merged(onto: StreamSettings()).hdr)
        let decoded = try JSONDecoder().decode(GameSettingsOverride.self, from: JSONEncoder().encode(game))
        #expect(decoded.hdr == true)
        game.reset(.hdr)
        #expect(game.isEmpty)
        game.restoreMissing(from: decoded)
        #expect(game.hdr == true)
    }
}
