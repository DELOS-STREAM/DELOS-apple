import DelosCore
import DelosHost
import DelosMedia
import Foundation
import Testing
@testable import DelosData

struct DecoderPacingTests {
    // Android StreamDisplayPlanner.java:288–315: 3 Hz tolerance and the <=49 Hz fallback are intentional.
    @Test func capFPSMatchesAndroidsRefreshBoundaryRules() {
        var settings = StreamSettings(fps: 120); settings.framePacing = .capFPS
        #expect(settings.streamFPS(refreshRate: 120) == 119)
        #expect(settings.streamFPS(refreshRate: 119) == 118)
        #expect(settings.streamFPS(refreshRate: 117) == 116)
        #expect(settings.streamFPS(refreshRate: 116) == 120)
        #expect(settings.streamFPS(refreshRate: 60) == 120)
        settings.fps = 60
        #expect(settings.streamFPS(refreshRate: 120) == 60)
        settings.fps = 49
        #expect(settings.streamFPS(refreshRate: 49) == 49)
        #expect(settings.streamFPS(refreshRate: 0) == 49)
    }
    @Test func launchAndCoreBothRequestActualWarpOversamplingWithoutChangingStoredFPSOrBitrate() {
        for (mode, expected) in [(FramePacing.warp, 240), (.warp2, 480), (.capFPS, 119)] {
            var settings = StreamSettings(fps: 120, bitrateKbps: 80000); settings.framePacing = mode
            let plan = StreamPlan(app: HostApp(id: 7, title: "Desktop"), settings: settings,
                                  display: StreamResolution(width: 1920, height: 1080), decodable: [.h264],
                                  refreshRate: 120, displaySupportsHDR: true, randomBytes: { [UInt8](repeating: 1, count: $0) })
            #expect(plan.request.frameRate == Double(expected))
            #expect(plan.configuration.fps == expected)
            #expect(plan.configuration.bitrateKbps == 80000)
            #expect(settings.fps == 120)
        }
    }
    @Test func additionalModesSurviveSettingsPersistence() throws {
        for mode in [FramePacing.capFPS, .warp, .warp2] {
            var settings = StreamSettings(fps: 120); settings.framePacing = mode
            let restored = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.framePacing == mode)
            #expect(restored.fps == 120)
        }
    }
}
