import DelosCore
import DelosHost
import Foundation
import Testing
@testable import DelosData

@Suite struct StreamSettingsTests {
    @Test func unknownAndMissingValuesFallBackOneByOne() throws {
        // A codec removed in a later version, numbers out of range and a broken resolution keep the rest
        let json = #"{"codec":"h266","fps":0,"bitrateKbps":5000000,"resolution":{"width":-4,"height":720},"playAudioOnHost":true}"#
        let s = try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8))
        #expect(s.codec == .automatic)
        #expect(s.fps == 1)
        #expect(s.bitrateKbps == 1_000_000)
        #expect(s.resolution == nil)
        #expect(s.playAudioOnHost)
        let empty = try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8))
        #expect(empty == StreamSettings())
        #expect(empty.fps == 60 && empty.bitrateKbps == nil && empty.codec == .automatic && !empty.playAudioOnHost)
    }

    @Test func settingsSurviveAStoreRoundTrip() throws {
        var s = StreamSettings(resolution: StreamResolution(width: 2560, height: 1440), fps: 120, bitrateKbps: 80000)
        s.codec = .hevc
        s.playAudioOnHost = true
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @Test func theStatisticsOverlayGoesOffFullCompactAndIsKeptByTheProfile() throws {
        #expect(StreamSettings().statisticsOverlay == .off)
        #expect(StatisticsOverlay.off.next == .full && StatisticsOverlay.full.next == .compact && StatisticsOverlay.compact.next == .off)
        #expect(!StatisticsOverlay.off.isShown && StatisticsOverlay.full.isShown && StatisticsOverlay.compact.isShown)
        var s = StreamSettings()
        s.statisticsOverlay = .compact
        #expect(try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s)).statisticsOverlay == .compact)
        // Settings stored before the overlay had modes, or by a version that knew another mode, show none
        #expect(try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"fps":90}"#.utf8)).statisticsOverlay == .off)
        let unknown = try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"fps":90,"statisticsOverlay":"tiny"}"#.utf8))
        #expect(unknown.statisticsOverlay == .off && unknown.fps == 90)
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = StreamSettingsStore(suiteName: suite)
        store.save(s, profile: "a")
        #expect(store.load(profile: "a").statisticsOverlay == .compact)
        #expect(store.load(profile: "b").statisticsOverlay == .off)
    }

    /// `ui_stream_menu_buttons` and `ui_stream_menu_swipe`: no buttons and the swipe on by default, both kept by the profile.
    @Test func theStreamMenuButtonsAndSwipeAreKeptByTheProfile() throws {
        #expect(StreamSettings().streamMenuButtons.isEmpty)
        #expect(StreamSettings().streamMenuSwipe)
        var s = StreamSettings()
        s.streamMenuButtons = ["l3", "r3"]
        s.streamMenuSwipe = false
        #expect(try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s)) == s)
        // Settings stored before these rows existed: none and on
        let old = try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"fps":90}"#.utf8))
        #expect(old.streamMenuButtons.isEmpty && old.streamMenuSwipe)
    }

    @Test func settersClampToTheRanges() {
        var s = StreamSettings()
        s.bitrateKbps = 10
        #expect(s.bitrateKbps == 1000)
        s.fps = -3
        #expect(s.fps == 1)
    }

    @Test func eachProfileKeepsItsOwnStreamSettings() {
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = StreamSettingsStore(suiteName: suite)
        store.save(StreamSettings(fps: 30), profile: "a")
        #expect(store.load(profile: "a").fps == 30)
        #expect(store.load(profile: "b") == StreamSettings())
        store.remove(profile: "a")
        #expect(store.load(profile: "a") == StreamSettings())
    }

    @MainActor
    @Test func aNewProfileCopiesTheCurrentOnesStreamSettingsAndDeletingForgetsThem() async throws {
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let profiles = ProfileStore(suiteName: suite, deleteGrace: .milliseconds(20))
        let stream = StreamSettingsStore(suiteName: suite)
        let ann = try #require(profiles.create(name: "Ann", avatar: 0))
        stream.save(StreamSettings(fps: 120), profile: ann.id)
        let bob = try #require(profiles.create(name: "Bob", avatar: 1))
        #expect(stream.load(profile: bob.id).fps == 120)
        // Later changes are independent
        stream.save(StreamSettings(fps: 30), profile: bob.id)
        #expect(stream.load(profile: ann.id).fps == 120)
        profiles.delete(bob.id)
        for _ in 0..<500 where stream.load(profile: bob.id) != StreamSettings() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stream.load(profile: bob.id) == StreamSettings())
    }

    // MARK: Bitrate

    @Test func theBitrateFollowsTheResolutionAndFrameRateUntilChosen() {
        var s = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080))
        #expect(s.bitrate(at: StreamResolution(width: 1920, height: 1080)) == 20000)
        s.fps = 120
        #expect(s.bitrate(at: StreamResolution(width: 1920, height: 1080)) == 28000)
        #expect(s.bitrate(at: StreamResolution(width: 3840, height: 2160)) == 113000)
        s.bitrateKbps = 50000
        #expect(s.bitrate(at: StreamResolution(width: 3840, height: 2160)) == 50000)
        #expect(StreamSettings.bitrateRange == 1000...1_000_000)
    }

    // MARK: Value lists

    @Test func theResolutionsArePresetsThenTheDisplaysAspectThenTheDisplay() {
        // iPhone 14 Pro Max, portrait pixels as UIScreen reports them: its 19.5:9 presets up to 1440 lines (4K's 4681 is too wide)
        let list = StreamChoices.resolutions(displayWidth: 1290, displayHeight: 2796)
        let presets = StreamResolution.presets.map(StreamChoices.Resolution.preset)
        #expect(Array(list.prefix(6)) == presets)
        #expect(Array(list.dropFirst(6)) == [
            .aspect(StreamResolution(width: 1560, height: 720)), .aspect(StreamResolution(width: 2340, height: 1080)),
            .aspect(StreamResolution(width: 3122, height: 1440)), .native(StreamResolution(width: 2796, height: 1290), portrait: false),
        ])
        // A 16:9 1080p display: no presets of its own, and its native resolution is the 1080p preset, listed once
        #expect(StreamChoices.resolutions(displayWidth: 1920, displayHeight: 1080).count == 6)
        #expect(StreamChoices.resolutions(displayWidth: 3840, displayHeight: 2160) == presets)
        // A squarish display (aspect below 1.3) also gets its portrait resolution, first; its 1440-line preset is its own
        // resolution and keeps the Native name
        let square = StreamChoices.resolutions(displayWidth: 1600, displayHeight: 1440)
        #expect(Array(square.dropFirst(6)) == [
            .aspect(StreamResolution(width: 800, height: 720)), .aspect(StreamResolution(width: 1200, height: 1080)),
            .aspect(StreamResolution(width: 2400, height: 2160)),
            .native(StreamResolution(width: 1440, height: 1600), portrait: true),
            .native(StreamResolution(width: 1600, height: 1440), portrait: false),
        ])
    }

    @Test(arguments: [
        // 13" iPad Pro (M4, M5), 4:3
        (2064, 2752, [(960, 720), (1440, 1080), (1920, 1440), (2880, 2160)]),
        // 11" iPad Pro (M4, M5), 1.45:1
        (1668, 2420, [(1044, 720), (1566, 1080), (2090, 1440), (3134, 2160)]),
        // A 16:10 Mac display
        (2560, 1600, [(1152, 720), (1728, 1080), (2304, 1440), (3456, 2160)]),
        // A 16:9 TV, and a panel within the 2 % tolerance of 16:9
        (3840, 2160, []),
        (2400, 1334, []),
    ])
    func theDisplaysAspectHasPresetsOfItsOwn(width: Int, height: Int, expected: [(Int, Int)]) {
        let presets = StreamChoices.aspectPresets(displayWidth: width, displayHeight: height)
        #expect(presets == expected.map { StreamResolution(width: $0.0, height: $0.1) })
    }

    @Test(arguments: [
        (60, [30, 60]),
        (61, [30, 60, 61]),
        (90, [30, 60, 90]),
        (100, [30, 60, 90, 100]),
        (120, [30, 60, 90, 120]),
        (144, [30, 60, 90, 120, 144]),
    ])
    func theFrameRatesFollowTheDisplay(maxFPS: Int, expected: [Int]) {
        let list = StreamChoices.frameRates(maxFramesPerSecond: maxFPS)
        #expect(list.map(\.fps) == expected)
        // Only a rate the presets do not have is the display's own
        let natives = list.filter { if case .native = $0 { true } else { false } }
        #expect(natives.map(\.fps) == ([30, 60, 90, 120].contains(maxFPS) ? [] : [maxFPS]))
    }

    @Test func onlyDecodableCodecsAreOffered() {
        #expect(VideoCodec.choices(decodable: .h264) == [.automatic, .h264])
        #expect(VideoCodec.choices(decodable: [.h264, .hevc]) == [.automatic, .hevc, .h264])
        #expect(VideoCodec.choices(decodable: [.h264, .hevc, .av1Main8]) == [.automatic, .av1, .hevc, .h264])
    }

    @Test func theCodecChoosesTheOfferedFormats() {
        let all: VideoFormats = [.h264, .hevc, .av1Main8]
        // Automatic offers H.264 and HEVC; AV1 only when chosen (DELOS for Android's decoder choice)
        #expect(VideoCodec.automatic.formats(decodable: all) == [.h264, .hevc])
        #expect(VideoCodec.av1.formats(decodable: all) == all)
        #expect(VideoCodec.hevc.formats(decodable: all) == [.h264, .hevc])
        #expect(VideoCodec.h264.formats(decodable: all) == .h264)
        // A codec the device cannot decode is never offered
        #expect(VideoCodec.av1.formats(decodable: [.h264, .hevc]) == [.h264, .hevc])
        #expect(VideoCodec.hevc.formats(decodable: .h264) == .h264)
    }

    @Test func choicesTheDeviceDoesNotOfferAreReplaced() {
        var s = StreamSettings(resolution: StreamResolution(width: 2732, height: 2048), fps: 120)
        s.codec = .av1
        let n = StreamChoices.normalized(s, displayWidth: 1290, displayHeight: 2796, maxFramesPerSecond: 60, decodable: [.h264, .hevc])
        #expect(n.resolution == StreamResolution(width: 3840, height: 2160))
        #expect(n.fps == 60)
        #expect(n.codec == .automatic)
        // What the device offers stays, and no resolution stays no resolution
        let kept = StreamSettings(fps: 30)
        #expect(StreamChoices.normalized(kept, displayWidth: 1290, displayHeight: 2796, maxFramesPerSecond: 120, decodable: .h264) == kept)
    }

    // MARK: The stream

    @Test func thePlanUsesTheStoredSettings() {
        var s = StreamSettings(fps: 120, bitrateKbps: 45000)
        s.codec = .h264
        s.playAudioOnHost = true
        let plan = StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: s, display: StreamResolution(width: 1290, height: 2796),
            decodable: [.h264, .hevc], refreshRate: 120, displaySupportsHDR: true)
        // No resolution chosen: the display's, capped at 1080p
        let display = StreamResolution.forDisplay(pixelWidth: 1290, pixelHeight: 2796)
        #expect(display.width <= 1920 && display.height <= 1080 && display.width > 1900)
        #expect(plan.request.width == display.width && plan.request.height == display.height)
        #expect(plan.configuration.width == display.width && plan.configuration.height == display.height)
        #expect(plan.request.frameRate == 120 && plan.configuration.fps == 120)
        #expect(plan.configuration.bitrateKbps == 45000)
        #expect(plan.configuration.supportedVideoFormats == .h264)
        #expect(plan.request.playAudioOnHost)
        // GeForce Experience's "optimize game settings" stays off, as DELOS for Android sends it
        #expect(!plan.request.optimizeGameSettings)
    }

    @Test func thePlanUsesTheChosenResolutionAndItsDefaultBitrate() {
        let plan = StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: StreamSettings(resolution: StreamResolution(width: 2560, height: 1440)),
            display: StreamResolution(width: 1290, height: 2796), decodable: [.h264, .hevc, .av1Main8], refreshRate: 60, displaySupportsHDR: true)
        #expect(plan.request.width == 2560 && plan.request.height == 1440)
        #expect(plan.configuration.bitrateKbps == 40000)
        #expect(plan.configuration.supportedVideoFormats == [.h264, .hevc])
    }

    private func plan(_ settings: StreamSettings) -> StreamPlan {
        StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: settings, display: StreamResolution(width: 1920, height: 1080),
            decodable: [.h264, .hevc], refreshRate: 60, displaySupportsHDR: false)
    }

    /// `list_audio_config` (PreferenceConfiguration.java:811-820): "71" and "51" ask for surround, anything else is
    /// stereo; the core and the launch request get the same layout.
    @Test(arguments: [
        (nil, AudioConfiguration.stereo), ("2", .stereo), ("51", .surround51), ("71", .surround71), ("6", .stereo),
    ] as [(String?, AudioConfiguration)])
    func thePlanAsksForTheChosenSpeakerLayout(stored: String?, layout: AudioConfiguration) {
        var s = StreamSettings()
        if let stored { s.values[SettingKey.audioConfiguration.rawValue] = .text(stored) }
        let planned = plan(s)
        #expect(planned.configuration.audio == layout)
        #expect(planned.request.surroundAudioInfo == layout.channelMask << 16 | layout.channelCount)
    }

    /// `seekbar_resolution_scale_factor` goes to the launch request's `scaleFactor` (NvHTTP.java:919), within 20…200.
    @Test func thePlanSendsTheResolutionScaleFactor() {
        var s = StreamSettings()
        #expect(plan(s).request.resolutionScaleFactor == 100)
        s.set(.resolutionScaleFactor, .int(150))
        #expect(plan(s).request.resolutionScaleFactor == 150)
        s.values[SettingKey.resolutionScaleFactor.rawValue] = .int(5)
        #expect(plan(s).request.resolutionScaleFactor == 20)
        s.values[SettingKey.resolutionScaleFactor.rawValue] = .int(900)
        #expect(plan(s).request.resolutionScaleFactor == 200)
    }

    /// `checkbox_full_range` asks the host for full-range video (MediaCodecDecoderRenderer.java:588-595).
    @Test func thePlanAsksForFullRangeWhenChosen() {
        var s = StreamSettings()
        #expect(plan(s).configuration.colorRange == .limited)
        s.set(.fullRange, .bool(true))
        #expect(plan(s).configuration.colorRange == .full)
    }

    /// A virtual display is asked for only when chosen and the PC has one ready (GameLauncher.kt:100-103).
    @Test(arguments: [(false, false, false), (false, true, false), (true, false, false), (true, true, true)])
    func thePlanAsksForAVirtualDisplayOnlyWhenThePCHasOneReady(chosen: Bool, ready: Bool, asked: Bool) {
        var s = StreamSettings()
        s.set(.useVirtualDisplay, .bool(chosen))
        let planned = StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: s, display: StreamResolution(width: 1920, height: 1080),
            decodable: .h264, refreshRate: 60, displaySupportsHDR: false, virtualDisplayReady: ready)
        #expect(planned.request.virtualDisplay == asked)
    }

    // MARK: HDR

    private let tenBitDevice: VideoFormats = [.h264, .hevc, .hevcMain10, .av1Main8, .av1Main10]

    @Test func hdrOffersTheMain10ProfilesOfTheChosenCodecAndAsksTheHostForHDR() {
        func plan(_ codec: VideoCodec, hdr: Bool, decodable: VideoFormats) -> StreamPlan {
            var s = StreamSettings()
            s.codec = codec
            s.hdr = hdr
            return StreamPlan(
                app: HostApp(id: 7, title: "Desktop"), settings: s, display: StreamResolution(width: 1920, height: 1080),
                decodable: decodable, refreshRate: 60, displaySupportsHDR: true)
        }
        // Off: no 10-bit format and no flag
        var off = plan(.automatic, hdr: false, decodable: tenBitDevice)
        #expect(off.configuration.supportedVideoFormats == [.h264, .hevc] && !off.request.hdr)
        // Automatic: HEVC Main10 next to HEVC (HDR implies HEVC), no AV1
        var on = plan(.automatic, hdr: true, decodable: tenBitDevice)
        #expect(on.configuration.supportedVideoFormats == [.h264, .hevc, .hevcMain10] && on.request.hdr)
        // AV1 chosen: both Main10 profiles
        on = plan(.av1, hdr: true, decodable: tenBitDevice)
        #expect(on.configuration.supportedVideoFormats == [.h264, .hevc, .hevcMain10, .av1Main8, .av1Main10] && on.request.hdr)
        // H.264 has no HDR
        on = plan(.h264, hdr: true, decodable: tenBitDevice)
        #expect(on.configuration.supportedVideoFormats == .h264 && !on.request.hdr)
        // A device without a hardware Main10 session offers none and does not ask the host for HDR
        off = plan(.automatic, hdr: true, decodable: [.h264, .hevc])
        #expect(off.configuration.supportedVideoFormats == [.h264, .hevc] && !off.request.hdr)
        // AV1 Main10 alone carries HDR when HEVC Main10 is missing
        on = plan(.av1, hdr: true, decodable: [.h264, .hevc, .av1Main8, .av1Main10])
        #expect(on.configuration.supportedVideoFormats == [.h264, .hevc, .av1Main8, .av1Main10] && on.request.hdr)
    }

    @Test func aStoredHDRFlagIsIgnoredWhenTheDisplayCannotShowHDR() {
        var s = StreamSettings()
        s.hdr = true
        let plan = StreamPlan(
            app: HostApp(id: 7, title: "Desktop"), settings: s, display: StreamResolution(width: 1920, height: 1080),
            decodable: tenBitDevice, refreshRate: 60, displaySupportsHDR: false)
        #expect(!plan.request.hdr)
        #expect(plan.configuration.supportedVideoFormats.isDisjoint(with: .tenBit))
    }

    @Test func hdrIsStoredLeniently() throws {
        var s = StreamSettings()
        #expect(!s.hdr)
        s.hdr = true
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.hdr)
        #expect(try !JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8)).hdr)
        #expect(try !JSONDecoder().decode(StreamSettings.self, from: Data(#"{"hdr":"yes"}"#.utf8)).hdr)
    }

    @Test func aMeteredNetworkAsksForTheMeteredBitrate() {
        let size = StreamResolution(width: 1920, height: 1080)
        var s = StreamSettings(bitrateKbps: 40_000)
        #expect(StreamPlan.bitrateKbps(s, at: size, metered: false) == 40_000)
        // Unset: a quarter of the normal bitrate, as the row's help and Android's PreferenceConfiguration say
        #expect(StreamPlan.bitrateKbps(s, at: size, metered: true) == 10_000)
        s.set(.meteredBitrate, .int(5_000))
        #expect(StreamPlan.bitrateKbps(s, at: size, metered: true) == 5_000)
        #expect(StreamPlan.bitrateKbps(s, at: size, metered: false) == 40_000)
        // The default bitrate follows the resolution, and so does its quarter
        let following = StreamSettings()
        #expect(StreamPlan.bitrateKbps(following, at: size, metered: true) == StreamPlan.defaultBitrateKbps(width: 1920, height: 1080, fps: 60) / 4)
    }

    @Test func theCustomFrameRateChoiceIsStoredAndKeptByNormalizing() throws {
        var s = StreamSettings(fps: 48)
        s.set(.customRefreshRate, .text("47.95"))
        // Stored before the choice had its own flag: the whole rate only the custom rate gives is that choice
        let normalized = StreamChoices.normalized(s, displayWidth: 1920, displayHeight: 1080, maxFramesPerSecond: 60, decodable: .h264)
        #expect(normalized.fps == 48 && normalized.customFrameRateChosen)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(normalized))
        #expect(decoded.customFrameRateChosen && decoded.launchFrameRate(refreshRate: 60) == 47.95)
        var warp = decoded
        warp.framePacing = .warp
        #expect(warp.launchFrameRate(refreshRate: 60) == 95.9)
    }
}
