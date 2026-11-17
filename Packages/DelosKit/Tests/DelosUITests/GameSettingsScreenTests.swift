import DelosData
import DelosHost
import DelosMedia
import Foundation
import Testing
@testable import DelosUI

@Suite @MainActor struct GameSettingsScreenTests {
    private let app = HostApp(id: 7, title: "Hades")
    private let device = StreamDevice(pixelWidth: 2796, pixelHeight: 1290, maxFramesPerSecond: 120, decodable: [.h264, .hevc])

    private func make() -> (model: GameSettingsModel, game: GameSettingsStore, streams: StreamSettingsStore) {
        let suite = "delos.tests.\(UUID().uuidString)"
        let streams = StreamSettingsStore(suiteName: suite)
        var settings = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080), fps: 60, bitrateKbps: 30_000)
        settings.codec = .hevc
        streams.save(settings, profile: "p")
        let game = GameSettingsStore(suiteName: suite)
        return (GameSettingsModel(hostID: "pc", app: app, profileID: "p", device: device, store: game, streams: streams), game, streams)
    }

    private func value(_ model: GameSettingsModel, _ id: String) -> String {
        GameSettingsModel.valueLabel(model.rows.first { $0.id == id }!)
    }

    @Test func theRowsAreTheStreamSettingsThatExistHereAndFollowTheProfile() {
        let (model, _, _) = make()
        #expect(model.rows.map(\.id) == GameSettingsOverride.Key.allCases.map(\.rawValue))
        #expect(model.rows.allSatisfy { $0.customLine == nil && $0.note == "From profile" })
        #expect(model.overrides.isEmpty)
    }

    @Test func anEditMakesOnlyThatRowCustomAndStoresItForTheAppNotTheProfile() {
        let (model, game, streams) = make()
        let profileFPS = value(model, StreamSettingsForm.frameRate)
        #expect(model.step(StreamSettingsForm.frameRate, by: 1))
        #expect(model.overrides.keys == [.frameRate] && model.overrides.fps == 90)
        let row = model.rows.first { $0.id == StreamSettingsForm.frameRate }!
        #expect(row.customLine == "Profile: \(profileFPS)" && row.note == nil)
        #expect(model.isCustom(StreamSettingsForm.frameRate) && !model.isCustom(StreamSettingsForm.codec))
        #expect(value(model, StreamSettingsForm.frameRate) != profileFPS)
        // The profile is untouched; the app's entry is stored
        #expect(streams.load(profile: "p").fps == 60)
        #expect(game.load(profile: "p", hostID: "pc", appID: 7).fps == 90)
        #expect(game.load(profile: "p", hostID: "pc", appID: 8).isEmpty)
    }

    @Test func theBitrateAndTheAudioToggleAreOverridesToo() {
        let (model, _, _) = make()
        model.slide(to: 80_000)
        model.step(StreamSettingsForm.hostAudio, by: 1)
        #expect(model.overrides.bitrateKbps == 80_000 && model.overrides.playAudioOnHost == true)
        #expect(model.form.effectiveBitrate == 80_000)
        #expect(value(model, StreamSettingsForm.bitrate) == "80 Mbps")
        #expect(value(model, StreamSettingsForm.hostAudio) == "On")
    }

    @Test func aChoiceIsPickedFromItsList() {
        let (model, _, _) = make()
        let options = model.form.codecOptions
        let h264 = options.firstIndex { $0.value == .h264 }!
        model.pick(StreamSettingsForm.codec, option: h264)
        #expect(model.overrides.codec == .h264)
        // Picking what is already chosen changes nothing
        model.pick(StreamSettingsForm.codec, option: h264)
        #expect(model.overrides.keys == [.codec])
    }

    @Test func aProfileEditShowsThroughUntouchedRows() {
        let (model, _, streams) = make()
        model.step(StreamSettingsForm.codec, by: 1)
        var edited = streams.load(profile: "p")
        edited.bitrateKbps = 50_000
        streams.save(edited, profile: "p")
        let reopened = GameSettingsModel(hostID: "pc", app: app, profileID: "p", device: device, store: GameSettingsStore(suiteName: nil), streams: streams)
        #expect(reopened.form.effectiveBitrate == 50_000)
    }

    @Test func resettingARowOrAllFollowsTheProfileAgainAndUndoRestoresWhatWasRemoved() {
        let (model, game, _) = make()
        model.step(StreamSettingsForm.frameRate, by: 1)
        model.step(StreamSettingsForm.codec, by: 1)
        let backup = model.reset(StreamSettingsForm.frameRate)
        #expect(model.overrides.keys == [.codec] && !model.isCustom(StreamSettingsForm.frameRate))
        model.restore(backup)
        #expect(model.overrides.keys == [.frameRate, .codec])
        let all = model.resetAll()
        #expect(model.overrides.isEmpty && game.customApps(profile: "p", hostID: "pc").isEmpty)
        // Undo of Reset all, with a row changed meanwhile: that one is kept
        model.step(StreamSettingsForm.codec, by: -1)
        let changed = model.overrides.codec
        model.restore(all)
        #expect(model.overrides.fps == 90 && model.overrides.codec == changed)
    }

    @Test func theChipAndTheSummarySayHowMuchIsCustom() {
        #expect(GameSettingsText.customLabel(0) == "Follows your profile")
        #expect(GameSettingsText.customLabel(1) == "1 custom setting")
        #expect(GameSettingsText.customLabel(3) == "3 custom settings")
        #expect(GameSettingsText.summary(0, app: "Hades") == "Change a row and it becomes custom for this app.")
        #expect(GameSettingsText.summary(2, app: "Hades") == "Only Hades uses these changes. Everything else follows your profile.")
    }
}
