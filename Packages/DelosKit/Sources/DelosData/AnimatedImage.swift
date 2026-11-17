import Foundation
import ImageIO

/// What the app needs to know of an animated image before it plays it (`AnimatedWebp` of DELOS for Android): its canvas,
/// each frame's time on screen and how long one pass lasts. ImageIO reads animated WebP, GIF and APNG alike, so every one of
/// them plays; a still image, a canvas over ``maxPixels`` or a file ImageIO cannot read is nil and keeps its first frame.
public struct AnimatedImageInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Each frame's time on screen in milliseconds (``frameMillis(unclampedSeconds:clampedSeconds:gif:)``).
    public let durations: [Int]

    public init(width: Int, height: Int, durations: [Int]) {
        self.width = width
        self.height = height
        self.durations = durations
    }

    /// The largest canvas that is played (a 3840 × 1240 hero is 4.8 million pixels).
    public static let maxPixels: Int64 = 100_000_000

    public var frameCount: Int { durations.count }

    /// How long one pass lasts: the sum of the frames' times, milliseconds (`AnimatedWebp.loopMillis`).
    public var loopMillis: Int { durations.reduce(0, +) }

    /// Whether an image of [frameCount] frames on a [width] × [height] canvas plays: more than one frame, and a canvas of 1
    /// to ``maxPixels`` pixels.
    public static func playable(frameCount: Int, width: Int, height: Int) -> Bool {
        guard frameCount > 1, width > 0, height > 0 else { return false }
        return Int64(width) * Int64(height) <= maxPixels
    }

    /// A frame's time on screen in milliseconds, as the Android platform's `AnimatedImageDrawable` takes it: the delay the
    /// file says (ImageIO's unclamped one, the clamped one when a file has no other), never below 0; a GIF's delay of 10 ms
    /// or less is 100 ms (Chrome's and Firefox's rule, which Android follows), any other format's is kept, 0 included (that
    /// frame shows for one display frame).
    public static func frameMillis(unclampedSeconds: Double?, clampedSeconds: Double?, gif: Bool) -> Int {
        let seconds = unclampedSeconds ?? clampedSeconds ?? 0
        let millis = seconds.isFinite ? max(Int((seconds * 1000).rounded()), 0) : 0
        return gif && millis <= 10 ? 100 : millis
    }

    /// The animation of [data], nil when it does not play (see the type).
    public static func of(_ data: Data) -> AnimatedImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return of(source)
    }

    /// The animation [source] holds, nil when it does not play. Reads the properties only; no frame is decoded.
    public static func of(_ source: CGImageSource) -> AnimatedImageInfo? {
        let count = CGImageSourceGetCount(source)
        guard count > 1,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = first[kCGImagePropertyPixelWidth] as? Int, let height = first[kCGImagePropertyPixelHeight] as? Int,
              playable(frameCount: count, width: width, height: height) else { return nil }
        let type = CGImageSourceGetType(source) as String?
        let gif = type == "com.compuserve.gif"
        let durations = (0..<count).map { index in
            let properties = index == 0 ? first : CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let delays = delays(properties)
            return frameMillis(unclampedSeconds: delays.unclamped, clampedSeconds: delays.clamped, gif: gif)
        }
        return AnimatedImageInfo(width: width, height: height, durations: durations)
    }

    /// The delays of a frame's properties, in whichever format's dictionary holds them.
    private static func delays(_ properties: [CFString: Any]) -> (unclamped: Double?, clamped: Double?) {
        let formats: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictionary, unclamped, clamped) in formats {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let seconds = { (key: CFString) in (values[key] as? NSNumber)?.doubleValue }
            if seconds(unclamped) != nil || seconds(clamped) != nil { return (seconds(unclamped), seconds(clamped)) }
        }
        return (nil, nil)
    }
}

/// The frames of an animation, decoded one at a time off the main actor at a set size (the thumbnail of each frame, which
/// ImageIO composes onto the canvas like a viewer would), and passed through [render] (the game background's look).
public actor AnimatedFrameDecoder {
    private let source: CGImageSource
    private let options: CFDictionary
    private let render: (@Sendable (CGImage) -> CGImage?)?

    /// Nil when [data] is no image ImageIO reads. [maxPixelSize]: the longer side of a decoded frame, at most.
    public init?(data: Data, maxPixelSize: Int, render: (@Sendable (CGImage) -> CGImage?)? = nil) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        self.source = source
        options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ] as CFDictionary
        self.render = render
    }

    /// Frame [index], whole (composed over the frames before it), or nil when it cannot be decoded.
    public func frame(_ index: Int) -> CGImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
        return render.map { $0(image) } ?? image
    }
}
