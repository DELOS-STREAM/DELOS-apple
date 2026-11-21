import CoreGraphics
import Foundation
import Testing
@testable import DelosData

struct HLSStillTests {
    private let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="hls_264_4_audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=5800000,RESOLUTION=1920x1080,AUDIO="audio"
        hls_264_0_video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2600000,RESOLUTION=1280x720,AUDIO="audio"
        hls_264_1_video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=854x480,AUDIO="audio"
        hls_264_2_video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,AUDIO="audio"
        hls_264_3_video.m3u8
        """

    private let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:3
        #EXT-X-MAP:URI="dash_h264/init-stream1.m4s"
        #EXTINF:3
        dash_h264/chunk-1.m4s
        #EXTINF:3
        dash_h264/chunk-2.m4s
        #EXTINF:3,
        dash_h264/chunk-3.m4s
        #EXTINF:3
        dash_h264/chunk-4.m4s
        #EXTINF:3
        dash_h264/chunk-5.m4s
        #EXTINF:3
        dash_h264/chunk-6.m4s
        #EXT-X-ENDLIST
        """

    @Test func theNarrowRenditionIsReadNotTheAudioOrTheLargest() {
        #expect(HLSStill.variant(master) == "hls_264_2_video.m3u8")
        #expect(HLSStill.variant("#EXTM3U\n") == nil)
    }

    @Test func theStillComesFromTheSegmentPlayingAtASixthThenAThird() throws {
        let playlist = try #require(HLSStill.playlist(media))
        #expect(playlist.initSection == "dash_h264/init-stream1.m4s")
        #expect(playlist.segments.count == 6)
        // 18 s: a sixth is 3 s (the second segment starts there), a third 6 s (the third)
        #expect(playlist.segment(at: 1.0 / 6) == "dash_h264/chunk-2.m4s")
        #expect(playlist.segment(at: 1.0 / 3) == "dash_h264/chunk-3.m4s")
    }

    @Test func aPlaylistWithoutAnInitSectionCannotGiveAStill() {
        #expect(HLSStill.playlist("#EXTM3U\n#EXTINF:3\nchunk.ts\n") == nil)
    }

    @Test func aStillIsNamedByItsMovieAndKeepsItsStream() throws {
        let stream = try #require(URL(string: "https://video.akamai.steamstatic.com/store_trailers/1/2/hls_264_master.m3u8?t=17"))
        let url = try #require(HLSStill.url(movie: "751913", stream: stream))
        let parsed = try #require(HLSStill.parse(url))
        #expect(parsed.movie == "751913")
        #expect(parsed.stream == stream)
        #expect(HLSStill.parse(stream) == nil)
    }

    @Test func relativeSegmentsKeepTheStreamsAccessToken() throws {
        let base = try #require(URL(string: "https://video.akamai.steamstatic.com/a/b/hls_264_2_video.m3u8?t=17"))
        #expect(TrailerStills.resolve(base, "dash_h264/chunk-1.m4s")?.absoluteString
                == "https://video.akamai.steamstatic.com/a/b/dash_h264/chunk-1.m4s?t=17")
    }

    @Test func aBlackFrameIsDarkAndAGreyOneIsNot() throws {
        func image(_ grey: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 64,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
            return try #require(context.makeImage())
        }
        #expect(HLSStill.isDark(try image(0.02)))
        #expect(!HLSStill.isDark(try image(0.4)))
    }

    @Test func failedStillsAreRememberedByMovieNotStreamURL() async throws {
        let transport = FailedStillTransport()
        let stills = TrailerStills(http: MetadataHTTP(transport: transport))
        let first = try #require(URL(string: "https://example.com/master.m3u8?t=1"))
        let refreshed = try #require(URL(string: "https://example.com/master.m3u8?t=2"))
        #expect(await stills.make(movie: "one", stream: first) == nil)
        #expect(await stills.make(movie: "one", stream: refreshed) == nil)
        #expect(await transport.requests == 1)
        #expect(await stills.make(movie: "two", stream: first) == nil)
        #expect(await transport.requests == 2)
        let restarted = TrailerStills(http: MetadataHTTP(transport: transport))
        #expect(await restarted.make(movie: "one", stream: first) == nil)
        #expect(await transport.requests == 3)
    }
}

private actor FailedStillTransport: MetadataTransport {
    private(set) var requests = 0

    func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
        requests += 1
        return MetadataHTTPResponse(data: Data(), status: 403)
    }
}
