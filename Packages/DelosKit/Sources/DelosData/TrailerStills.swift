import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pure parts of ``TrailerStills``: choosing the rendition and the segment of a Steam trailer's HLS stream, telling a
/// dark frame, and naming a still.
public enum HLSStill {
    /// Where the still is taken: a sixth of the trailer, else (a dark frame) a third.
    public static let fractions: [Double] = [1.0 / 6, 1.0 / 3]

    /// Width of the rendition read: enough for the carousel and the viewer's blurred still, and a small download.
    static let width = 854

    /// The URL a still is loaded by (``IGDBImageStore/data(_:)``): `delos-still://<movie>?hls=<stream>`.
    public static func url(movie: String, stream: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = "delos-still"
        parts.host = movie
        parts.queryItems = [URLQueryItem(name: "hls", value: stream.absoluteString)]
        return parts.url
    }

    /// The movie and its stream named by a still's URL; nil for any other URL.
    static func parse(_ url: URL) -> (movie: String, stream: URL)? {
        guard url.scheme == "delos-still", let movie = url.host, !movie.isEmpty,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "hls" })?.value,
              let stream = URL(string: value) else { return nil }
        return (movie, stream)
    }

    /// The media playlist of a master playlist's rendition closest to ``width`` wide; nil for no rendition.
    public static func variant(_ master: String) -> String? {
        let lines = master.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var best: (distance: Int, uri: String)?
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
            let found = line.range(of: #"RESOLUTION=(\d+)x"#, options: .regularExpression).flatMap { Int(line[$0].dropFirst(11).dropLast()) } ?? 0
            let distance = abs(found - width)
            if best == nil || distance < best!.distance { best = (distance, uri) }
        }
        return best?.uri
    }

    /// A fragmented-MP4 media playlist: its init section and its segments with their lengths (seconds).
    public struct Playlist: Equatable {
        public let initSection: String
        public let segments: [(uri: String, length: Double)]

        public static func == (a: Playlist, b: Playlist) -> Bool {
            a.initSection == b.initSection && a.segments.map(\.uri) == b.segments.map(\.uri) && a.segments.map(\.length) == b.segments.map(\.length)
        }

        /// The segment that plays at [fraction] of the whole.
        public func segment(at fraction: Double) -> String? {
            let total = segments.reduce(0) { $0 + $1.length }
            guard total > 0 else { return nil }
            var at = 0.0
            for segment in segments {
                at += segment.length
                if at > total * fraction { return segment.uri }
            }
            return segments.last?.uri
        }
    }

    /// Parses a fragmented-MP4 media playlist; nil without an init section (`EXT-X-MAP`) or segments.
    public static func playlist(_ text: String) -> Playlist? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP") }),
              let range = map.range(of: #"URI="[^"]+""#, options: .regularExpression) else { return nil }
        let initSection = String(map[range].dropFirst(5).dropLast())
        var segments: [(String, Double)] = []
        var length: Double?
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                length = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#") {
                segments.append((line, length ?? 0))
                length = nil
            }
        }
        return segments.isEmpty ? nil : Playlist(initSection: initSection, segments: segments)
    }

    /// A frame darker than about 8 % mean luma (a fade, a black title card).
    public static func isDark(_ image: CGImage) -> Bool {
        let side = (width: 32, height: 18)
        var pixels = [UInt8](repeating: 0, count: side.width * side.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side.width, height: side.height, bitsPerComponent: 8,
                                          bytesPerRow: side.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side.width, height: side.height))
            return true
        }
        guard drawn else { return false }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
        }
        return sum / Double(side.width * side.height) < 0.08
    }
}

/// A still from each Steam trailer, its carousel poster (Steam's own trailer stills are only 293 × 165). The trailer's HLS
/// stream is read, not played: the 854 px rendition's init section and the one segment at a sixth of its length are joined
/// into a small fragmented MP4 (a few hundred kB) and its first frame is decoded; a near-black frame tries a third of the
/// length. Up to three trailers are read at once, each once however many ask; the JPEGs are kept by the caller's cache.
actor TrailerStills {
    private let http: MetadataHTTP
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// A movie that cannot yield a still is not downloaded again until the app restarts.
    private var failed: Set<String> = []

    init(http: MetadataHTTP) { self.http = http }

    /// A JPEG still of the trailer at [stream]; nil when it cannot be made.
    func make(movie: String, stream: URL) async -> Data? {
        guard !failed.contains(movie) else { return nil }
        await acquire()
        defer { release() }
        guard !failed.contains(movie) else { return nil }
        let result = await extract(stream: stream)
        if result == nil { failed.insert(movie) }
        return result
    }

    private func extract(stream: URL) async -> Data? {
        guard let masterText = await text(stream), let variant = HLSStill.variant(masterText),
              let playlistURL = Self.resolve(stream, variant), let playlistText = await text(playlistURL),
              let playlist = HLSStill.playlist(playlistText),
              let initURL = Self.resolve(playlistURL, playlist.initSection), let initData = await bytes(initURL) else { return nil }
        for fraction in HLSStill.fractions {
            guard let segment = playlist.segment(at: fraction), let segmentURL = Self.resolve(playlistURL, segment),
                  let chunk = await bytes(segmentURL), let frame = await Self.firstFrame(initData + chunk) else { continue }
            if HLSStill.isDark(frame) { continue }
            return Self.jpeg(frame)
        }
        return nil
    }

    private func acquire() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    /// [relative] against [base], keeping [base]'s query (Steam's access token) when the reference has none.
    static func resolve(_ base: URL, _ relative: String) -> URL? {
        guard let url = URL(string: relative, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if parts.query == nil, let token = URLComponents(url: base, resolvingAgainstBaseURL: false)?.percentEncodedQuery {
            parts.percentEncodedQuery = token
        }
        return parts.url
    }

    private func text(_ url: URL) async -> String? {
        guard let data = await bytes(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func bytes(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        let data = try? await http.send(URLRequest(url: url))
        return data.flatMap { $0.isEmpty || $0.count > 8 * 1024 * 1024 ? nil : $0 }
    }

    private static func firstFrame(_ mp4: Data) async -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? mp4.write(to: file)) != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: .zero).image
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
