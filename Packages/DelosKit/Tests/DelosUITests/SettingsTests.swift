import DelosCore
import DelosData
import Testing
@testable import DelosInput
@testable import DelosUI

/// iPhone 14 Pro Max: 2796 × 1290, 120 Hz, H.264 and HEVC in hardware.
private let iPhone = StreamDevice(pixelWidth: 1290, pixelHeight: 2796, maxFramesPerSecond: 120, decodable: [.h264, .hevc])

@Suite struct SettingsFormTests {
    @Test func theTabsHoldTheirRowsInAndroidsOrder() {
        let form = StreamSettingsForm(settings: StreamSettings(), device: iPhone)
        #expect(form.rows(.stream).map(\.id) == ["list_resolution", "list_fps", "seekbar_bitrate_kbps", "video_format"])
        #expect(form.rows(.audio).map(\.id) == ["checkbox_host_audio"])
        #expect(Set(form.rows(.stream).map(\.section)) == ["Video Settings"])
        #expect(form.rows(.audio)[0].section == "Host Settings")
        #expect(SettingsTab.stream.step(1) == .audio)
        #expect(SettingsTab.stream.step(-1) == .audio)
        #expect(SettingsTab.audio.step(1) == .stream)
    }

    @Test func theRowsShowAndroidsLabels() throws {
        let form = StreamSettingsForm(settings: StreamSettings(), device: iPhone)
        let rows = form.rows(.stream)
        let display = StreamResolution.forDisplay(pixelWidth: 1290, pixelHeight: 2796)
        guard case let .choice(resolution, options, selected) = rows[0].value else { Issue.record("resolution"); return }
        #expect(resolution == "Automatic · \(display.text)")
        #expect(selected == 0)
        #expect(options == ["Automatic · \(display.text)", "360p", "480p", "720p", "1080p", "1440p", "4K", "Native (2796x1290)"])
        guard case let .choice(fps, rates, _) = rows[1].value else { Issue.record("fps"); return }
        #expect(fps == "60 FPS")
        #expect(rates == ["30 FPS", "60 FPS", "90 FPS", "120 FPS"])
        guard case let .slider(kbps, range, step, divisor, unit) = rows[2].value else { Issue.record("bitrate"); return }
        #expect(kbps == StreamPlan.defaultBitrateKbps(width: display.width, height: display.height, fps: 60))
        #expect(range == 1000...1_000_000 && step == 1000 && divisor == 1000 && unit == " Mbps")
        guard case let .choice(codec, codecs, _) = rows[3].value else { Issue.record("codec"); return }
        #expect(codec == "Automatic")
        #expect(codecs == ["Automatic", "HEVC (H.265)", "H.264"])
        #expect(rows[3].help.hasPrefix("Automatic\nPicks H.264 or HEVC."))
        #expect(form.rows(.audio)[0].value == .toggle(false))
        #expect(form.rows(.audio)[0].label == "Play audio on PC")
    }

    @Test func leftAndRightStepThroughTheChoicesAndWrap() {
        var form = StreamSettingsForm(settings: StreamSettings(), device: iPhone)
        form.step("video_format", by: -1)
        #expect(form.settings.codec == .h264)
        form.step("video_format", by: 1)
        #expect(form.settings.codec == .automatic)
        form.step("list_fps", by: 1)
        #expect(form.settings.fps == 90)
        form.step("list_resolution", by: 1)
        #expect(form.settings.resolution == StreamResolution(width: 640, height: 360))
        form.step("list_resolution", by: -1)
        #expect(form.settings.resolution == nil)
        form.step("list_resolution", by: -1)
        #expect(form.settings.resolution == StreamResolution(width: 2796, height: 1290))
        form.step("checkbox_host_audio", by: 1)
        #expect(form.settings.playAudioOnHost)
    }

    @Test func aPickedValueIsStored() {
        var form = StreamSettingsForm(settings: StreamSettings(), device: iPhone)
        form.pick("list_resolution", option: 4)
        #expect(form.settings.resolution == StreamResolution(width: 1920, height: 1080))
        form.pick("list_fps", option: 3)
        #expect(form.settings.fps == 120)
        form.pick("video_format", option: 1)
        #expect(form.settings.codec == .hevc)
        // An index outside the list changes nothing
        form.pick("video_format", option: 9)
        #expect(form.settings.codec == .hevc)
    }

    @Test func theBitrateFollowsUntilTheSliderMoves() {
        var form = StreamSettingsForm(settings: StreamSettings(resolution: StreamResolution(width: 1920, height: 1080)), device: iPhone)
        #expect(form.effectiveBitrate == 20000)
        form.step("list_fps", by: 2)
        #expect(form.effectiveBitrate == 28000)
        form.step("seekbar_bitrate_kbps", by: 1)
        #expect(form.settings.bitrateKbps == 29000)
        form.step("list_fps", by: -2)
        #expect(form.effectiveBitrate == 29000)
        // The slider lands on whole Mbps within its range
        form.setBitrate(45_400)
        #expect(form.settings.bitrateKbps == 45000)
        form.setBitrate(-5)
        #expect(form.settings.bitrateKbps == 1000)
        form.setBitrate(2_000_000)
        #expect(form.settings.bitrateKbps == 1_000_000)
        let changed = form.step("seekbar_bitrate_kbps", by: 1)
        #expect(!changed)
    }

    @Test func aHeldSliderSpeedsUpLikeAndroid() {
        #expect(StreamSettingsForm.sliderAcceleration(steps: 999, repeatCount: 0) == 1)
        #expect(StreamSettingsForm.sliderAcceleration(steps: 999, repeatCount: 10) == 5)
        #expect(StreamSettingsForm.sliderAcceleration(steps: 999, repeatCount: 25) == 10)
        // At most a fortieth of the range
        #expect(StreamSettingsForm.sliderAcceleration(steps: 999, repeatCount: 40) == 24)
        #expect(StreamSettingsForm.sliderAcceleration(steps: 20, repeatCount: 40) == 1)
    }

    @Test func aChoiceTheDeviceLacksIsReplacedWhenTheScreenOpens() {
        var stored = StreamSettings(fps: 144)
        stored.codec = .av1
        let form = StreamSettingsForm(settings: stored, device: iPhone)
        #expect(form.settings.fps == 60)
        #expect(form.settings.codec == .automatic)
    }

    @Test func theHelpPutsTheValueBeforeWhatTheSettingDoes() {
        #expect(StreamSettingsForm.details(value: "1080p", explanation: "Requests a 1920 × 1080 stream.", unavailable: false, about: "About.")
            == "1080p\nRequests a 1920 × 1080 stream.\n\nAbout.")
        #expect(StreamSettingsForm.details(value: "x", explanation: nil, unavailable: true, about: "About.")
            == "The saved choice is unavailable\n\nAbout.")
        #expect(StreamSettingsForm.details(value: "x", explanation: nil, unavailable: false, about: "About.") == "About.")
    }
}

@MainActor
@Suite struct SettingsNavigationTests {
    @Test func settingsAndProfileTakeEachOthersPlace() {
        let navigator = Navigator(root: .start)
        navigator.push(.home(hostID: "pc"))
        navigator.openFromNavigation(.settings)
        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "pc"), .settings])
        navigator.openFromNavigation(.profile)
        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "pc"), .profile])
        // The current one stays as it is
        navigator.openFromNavigation(.profile)
        #expect(navigator.stack.count == 3)
        #expect(navigator.back())
        #expect(navigator.current == .home(hostID: "pc"))
    }

    @Test func theNavigationAndTheSideMenuBelongToAndroidsScreens() {
        #expect(Screen.home(hostID: "pc").showsNavigation && Screen.settings.showsNavigation && Screen.profile.showsNavigation)
        #expect(!Screen.start.showsNavigation && Screen.start.hasSideMenu)
        #expect(!Screen.pair.hasSideMenu && !Screen.stream(hostID: "pc", appID: 1).hasSideMenu && !Screen.boot.hasSideMenu)
    }

    @Test func onlyDirectionsRepeatWhileHeld() {
        #expect(MenuInput.repeats(.up) && MenuInput.repeats(.right))
        #expect(!MenuInput.repeats(.accept) && !MenuInput.repeats(.nextTab) && !MenuInput.repeats(.menu))
    }
}
