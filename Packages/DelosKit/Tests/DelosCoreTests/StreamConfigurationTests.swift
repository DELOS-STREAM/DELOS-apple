import CDelosCommon
import Testing
@testable import DelosCore

@Suite struct StreamConfigurationTests {
    private let key = RemoteInputKey(key: Array(1...16), iv: Array(101...116))!

    @Test func everyFieldReachesTheCStructure() {
        let configuration = StreamConfiguration(
            width: 2560, height: 1440, fps: 120, bitrateKbps: 80_000, packetSize: 1024,
            streamingLocation: .remote, audio: .surround51, supportedVideoFormats: [.hevc, .av1Main10],
            clientRefreshRateX100: 11_988, colorSpace: .rec2020, colorRange: .full,
            encryption: [.audio, .video], remoteInputKey: key,
            pyroWave: PyroWaveSettings(compression: 1, linkMbps: 900, paceMbps: 600))

        let c = configuration.cValue

        #expect(c.width == 2560)
        #expect(c.height == 1440)
        #expect(c.fps == 120)
        #expect(c.bitrate == 80_000)
        #expect(c.packetSize == 1024)
        #expect(c.streamingRemotely == STREAM_CFG_REMOTE)
        #expect(c.audioConfiguration == 0x3F_06CA)
        #expect(c.supportedVideoFormats == 0x0100 | 0x2000)
        #expect(c.clientRefreshRateX100 == 11_988)
        #expect(c.colorSpace == COLORSPACE_REC_2020)
        #expect(c.colorRange == COLOR_RANGE_FULL)
        #expect(c.encryptionFlags == 0x3)
        #expect(withUnsafeBytes(of: c.remoteInputAesKey) { Array($0) } == Array(1...16))
        #expect(withUnsafeBytes(of: c.remoteInputAesIv) { Array($0) } == Array(101...116))
        #expect(c.pyrowaveCompression == 1)
        #expect(c.pyrowaveLinkMbps == 900)
        #expect(c.pyrowavePaceMbps == 600)
    }

    @Test func locationsAndColorsUseTheCoreConstants() {
        #expect(StreamingLocation.local.rawValue == STREAM_CFG_LOCAL)
        #expect(StreamingLocation.automatic.rawValue == STREAM_CFG_AUTO)
        #expect(ColorSpace.rec601.rawValue == COLORSPACE_REC_601)
        #expect(ColorSpace.rec709.rawValue == COLORSPACE_REC_709)
        #expect(ColorRange.limited.rawValue == COLOR_RANGE_LIMITED)
    }

    @Test func allEncryptionIsEveryBit() {
        var configuration = StreamConfiguration(
            width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, remoteInputKey: key)
        configuration.encryption = .all
        #expect(UInt32(bitPattern: configuration.cValue.encryptionFlags) == 0xFFFF_FFFF)
    }

    @Test func outOfRangeNumbersAreClampedNotWrapped() {
        let configuration = StreamConfiguration(
            width: Int(Int32.max) + 10, height: 1080, fps: 60, bitrateKbps: Int(Int32.min) - 1, remoteInputKey: key)
        #expect(configuration.cValue.width == Int32.max)
        #expect(configuration.cValue.bitrate == Int32.min)
    }

    @Test(arguments: [
        (AudioConfiguration.stereo, Int32(0x0003_02CA), 2),
        (AudioConfiguration.surround51, Int32(0x003F_06CA), 6),
        (AudioConfiguration.surround71, Int32(0x063F_08CA), 8),
    ])
    func audioLayoutsEncodeLikeTheCoreMacro(layout: AudioConfiguration, encoded: Int32, channels: Int) {
        // MAKE_AUDIO_CONFIGURATION(channels, mask) = mask << 16 | channels << 8 | 0xCA, evaluated by hand
        #expect(layout.rawValue == encoded)
        #expect(layout.channelCount == channels)
        #expect(AudioConfiguration(rawValue: encoded) == layout)
    }

    @Test func unknownAudioEncodingsAreRejected() {
        #expect(AudioConfiguration(rawValue: 0x0003_02CB) == nil)
        #expect(AudioConfiguration(rawValue: 0) == nil)
    }

    @Test func videoFormatBitsMatchTheProtocol() {
        #expect(VideoFormats.h264.rawValue == 0x0001)
        #expect(VideoFormats.h264High444.rawValue == 0x0004)
        #expect(VideoFormats.hevc.rawValue == 0x0100)
        #expect(VideoFormats.hevcMain10.rawValue == 0x0200)
        #expect(VideoFormats.hevcRExt444.rawValue == 0x0400)
        #expect(VideoFormats.hevcRExt10_444.rawValue == 0x0800)
        #expect(VideoFormats.av1Main8.rawValue == 0x1000)
        #expect(VideoFormats.av1Main10.rawValue == 0x2000)
        #expect(VideoFormats.av1High444.rawValue == 0x4000)
        #expect(VideoFormats.av1High10_444.rawValue == 0x8000)
        #expect(VideoFormats.pyroWave.rawValue == 0x01_0000)
        #expect(VideoFormats.pyroWaveHDR10_444.rawValue == 0x08_0000)
    }

    @Test func videoFormatMasksGroupTheRightFormats() {
        #expect(VideoFormats.allHEVC == [.hevc, .hevcMain10, .hevcRExt444, .hevcRExt10_444])
        #expect(VideoFormats.allAV1 == [.av1Main8, .av1Main10, .av1High444, .av1High10_444])
        #expect(
            VideoFormats.tenBit == [
                .hevcMain10, .hevcRExt10_444, .av1Main10, .av1High10_444, .pyroWaveHDR10, .pyroWaveHDR10_444,
            ])
        #expect(
            VideoFormats.yuv444 == [
                .h264High444, .hevcRExt444, .hevcRExt10_444, .av1High444, .av1High10_444, .pyroWave444,
                .pyroWaveHDR10_444,
            ])
        #expect(!VideoFormats.tenBit.contains(.hevc))
    }

    @Test func serverCodecModesMatchTheProtocol() {
        #expect(ServerCodecModes.h264.rawValue == 0x0000_0001)
        #expect(ServerCodecModes.hevc.rawValue == 0x0000_0100)
        #expect(ServerCodecModes.hevcMain10.rawValue == 0x0000_0200)
        #expect(ServerCodecModes.av1Main8.rawValue == 0x0001_0000)
        #expect(ServerCodecModes.av1Main10.rawValue == 0x0002_0000)
        #expect(ServerCodecModes.h264High444.rawValue == 0x0004_0000)
        #expect(ServerCodecModes.av1High10_444.rawValue == 0x0040_0000)
        #expect(ServerCodecModes.pyroWaveHDR10_444.rawValue == 0x0400_0000)
    }

    @Test func remoteInputKeysNeedSixteenBytes() {
        #expect(RemoteInputKey(key: Array(repeating: 0, count: 15), iv: Array(repeating: 0, count: 16)) == nil)
        #expect(RemoteInputKey(key: Array(repeating: 0, count: 16), iv: Array(repeating: 0, count: 17)) == nil)
        let random = RemoteInputKey.random()
        #expect(random.key.count == 16 && random.iv.count == 16)
        #expect(random != RemoteInputKey.random())
    }

    @Test func serverInformationStringsReachTheCStructure() {
        let server = ServerInformation(
            address: "192.168.1.20", appVersion: "7.1.431.-1", gfeVersion: "3.23.0.74",
            rtspSessionURL: "rtsp://192.168.1.20:48010", codecModeSupport: [.h264, .hevc])
        server.withCValue { info in
            #expect(String(cString: info.address) == "192.168.1.20")
            #expect(String(cString: info.serverInfoAppVersion) == "7.1.431.-1")
            #expect(String(cString: info.serverInfoGfeVersion) == "3.23.0.74")
            #expect(String(cString: info.rtspSessionUrl) == "rtsp://192.168.1.20:48010")
            #expect(info.serverCodecModeSupport == 0x101)
        }

        let minimal = ServerInformation(address: "host", appVersion: "7.1.431.-1", codecModeSupport: .h264)
        minimal.withCValue { info in
            #expect(info.serverInfoGfeVersion == nil)
            #expect(info.rtspSessionUrl == nil)
        }
    }

    @Test func stagesCarryTheCoreNames() {
        #expect(StreamStage.platformInit.name == "platform initialization")
        #expect(StreamStage.rtspHandshake.name == "RTSP handshake")
        #expect(StreamStage.allCases.map(\.rawValue) == Array(1...11))
    }

    @Test func terminationCodesMapToReasons() {
        #expect(StreamTermination(errorCode: 0) == .graceful)
        #expect(StreamTermination(errorCode: -100) == .noVideoTraffic)
        #expect(StreamTermination(errorCode: -103) == .protectedContent)
        #expect(StreamTermination(errorCode: 10054) == .error(10054))
    }
}
