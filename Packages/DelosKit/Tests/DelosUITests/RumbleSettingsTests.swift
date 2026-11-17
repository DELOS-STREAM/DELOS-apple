import DelosData
import Foundation
import Testing
@testable import DelosUI

struct RumbleSettingsTests {
    @Test func strengthAndFeelRoundTripWithoutResettingStreamSettings() throws {
        let suite = "RumbleSettingsTests." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = StreamSettingsStore(suiteName: suite)
        var settings = StreamSettings(fps: 120)
        settings.rumble.profile = .pulsing
        settings.rumble.deviceFallback = true
        settings.rumble.deviceStrength = 173
        store.save(settings, profile: "test")
        #expect(store.load(profile: "test") == settings)
        let legacy = try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"fps":90}"#.utf8))
        #expect(legacy.fps == 90)
        #expect(legacy.rumble.profile == .original)
    }

    @Test func disabledDependenciesCannotChangeAndPresetChoicePersists() {
        // A device with a vibration motor: without one Android hides the device rumble rows and the feel
        let device = StreamDevice(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 120, decodable: [.h264], haptics: true)
        var form = StreamSettingsForm(settings: StreamSettings(), device: device)
        let changedWhileDisabled = form.step(StreamSettingsForm.rumbleStrength, by: 10)
        #expect(!changedWhileDisabled)
        let enabledFallback = form.step(StreamSettingsForm.rumbleFallback, by: 1)
        #expect(enabledFallback)
        let changedStrength = form.step(StreamSettingsForm.rumbleStrength, by: 10)
        #expect(changedStrength)
        #expect(form.settings.rumble.deviceStrength == 110)
        form.pick(StreamSettingsForm.rumbleFeel, option: 2)
        #expect(form.settings.rumble.profile == .kickStart)
        let disabledRumble = form.step(StreamSettingsForm.rumbleEnabled, by: 1)
        #expect(disabledRumble)
        let changedDisabledFeel = form.step(StreamSettingsForm.rumbleFeel, by: 1)
        #expect(!changedDisabledFeel)
        let rumbleIDs: Set = [StreamSettingsForm.rumbleFeel, StreamSettingsForm.rumbleFallback, StreamSettingsForm.rumbleDevice,
                              StreamSettingsForm.rumbleStrength]
        #expect(form.rows(.controls).filter { rumbleIDs.contains($0.id) && !$0.enabled }.count == 4)
    }
}
