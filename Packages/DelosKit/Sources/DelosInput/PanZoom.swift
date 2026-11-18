import Foundation

/// How the picture is placed on the surface (the Display settings' scale mode).
public enum PictureFit: Sendable, Equatable {
    /// The whole picture, as large as fits, centred.
    case fit
    /// The whole surface, as small as covers it: the edges beyond it are cut off.
    case fill
    /// The whole surface.
    case stretch
}

/// The surface the stream is shown on and where the picture lies on it, in pixels (Android's stream container in its
/// parent): what touches and the local pointer are measured against.
public struct TouchSurface: Equatable, Sendable {
    public var width: Double
    public var height: Double
    /// The picture's rectangle on the surface without zoom.
    public var pictureX: Double
    public var pictureY: Double
    public var pictureWidth: Double
    public var pictureHeight: Double
    /// The picture sits at the top where it leaves room (`checkbox_enable_view_top_center`), also when unzoomed again.
    public var topAligned = false

    public init(width: Double, height: Double, pictureX: Double, pictureY: Double, pictureWidth: Double, pictureHeight: Double) {
        self.width = width
        self.height = height
        self.pictureX = pictureX
        self.pictureY = pictureY
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
    }

    /// A surface of `width` × `height` showing a `videoWidth` × `videoHeight` picture placed by `fit`; at the top instead
    /// of the middle when `topAligned` (`checkbox_enable_view_top_center`, the renderers' placement).
    public init(width: Double, height: Double, videoWidth: Int, videoHeight: Int, fit: PictureFit, topAligned: Bool = false) {
        var pictureWidth = width, pictureHeight = height
        if videoWidth > 0, videoHeight > 0, width > 0, height > 0, fit != .stretch {
            let scaleX = width / Double(videoWidth), scaleY = height / Double(videoHeight)
            let scale = fit == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
            pictureWidth = (Double(videoWidth) * scale).rounded()
            pictureHeight = (Double(videoHeight) * scale).rounded()
        }
        self.init(
            width: width, height: height, pictureX: ((width - pictureWidth) / 2).rounded(.down),
            pictureY: topAligned ? 0 : ((height - pictureHeight) / 2).rounded(.down), pictureWidth: pictureWidth, pictureHeight: pictureHeight)
        self.topAligned = topAligned
    }

    /// The picture's size in whole pixels, at least 1 × 1.
    public var pictureSize: TouchViewSize {
        TouchViewSize(width: max(Int(pictureWidth), 1), height: max(Int(pictureHeight), 1))
    }
}

/// The pan and zoom of the picture (`PanZoomHandler`): the picture scaled about its top left corner by ``scale`` (1…10)
/// and placed with that corner at ``x``, ``y`` of the surface, always covering the surface where it is larger and centred
/// where it is smaller. Pinching zooms about the fingers' middle, moving the fingers pans.
public struct PanZoom: Equatable, Sendable {
    public static let maxScale = 10.0

    public private(set) var scale = 1.0
    /// Where the picture's top left corner is on the surface, in pixels.
    public private(set) var x = 0.0
    public private(set) var y = 0.0

    public init() {}

    /// Unzoomed, where the surface puts the picture.
    public init(surface: TouchSurface) {
        x = surface.pictureX
        y = surface.pictureY
    }

    /// Saved values (`number_zoom_scale`, `number_pan_offset_x`, `_y`; `setInitialZoomAndPan`), kept within the surface.
    public init(scale: Double, x: Double, y: Double, surface: TouchSurface) {
        self.scale = min(max(scale, 1), Self.maxScale)
        self.x = x
        self.y = y
        constrain(to: surface)
    }

    public var isZoomed: Bool { scale != 1 }

    /// A pinch: the scale times [factor] about [focusX], [focusY] (`onScale`).
    public mutating func zoom(by factor: Double, focusX: Double, focusY: Double, surface: TouchSurface) {
        let newScale = min(max(scale * factor, 1), Self.maxScale)
        x = focusX + (x - focusX) / scale * newScale
        y = focusY + (y - focusY) / scale * newScale
        scale = newScale
        constrain(to: surface)
    }

    /// A drag of [dx], [dy] pixels (`onScroll`).
    public mutating func pan(dx: Double, dy: Double, surface: TouchSurface) {
        x += dx
        y += dy
        constrain(to: surface)
    }

    /// `constrainToBounds`: centred along an axis where the picture is no larger than the surface (at the top of a
    /// top-aligned surface), else no edge inside it.
    public mutating func constrain(to surface: TouchSurface) {
        let width = surface.pictureWidth * scale, height = surface.pictureHeight * scale
        x = surface.width >= width ? (surface.width - width) / 2 : max(surface.width - width, min(x, 0))
        y = surface.height >= height ? (surface.topAligned ? 0 : (surface.height - height) / 2) : max(surface.height - height, min(y, 0))
    }

    /// A point of the surface in pixels of the unzoomed picture.
    public func picturePoint(x px: Double, y py: Double) -> (x: Double, y: Double) {
        ((px - x) / scale, (py - y) / scale)
    }

    /// The surface's content transform: a point p of the unzoomed surface shows at `p * scale + (tx, ty)`.
    public func transform(on surface: TouchSurface) -> (scale: Double, tx: Double, ty: Double) {
        (scale, x - surface.pictureX * scale, y - surface.pictureY * scale)
    }
}

/// The fingers of the pan and zoom mode (Android's `ScaleGestureDetector` and `GestureDetector` on the picture):
/// two or more fingers spreading or closing zoom about their middle, the middle moving pans once it left the touch slop.
public struct PanZoomGesture: Sendable {
    private var lastFocus: (x: Double, y: Double)?
    private var lastSpan = 0.0
    private var downFocus: (x: Double, y: Double)?
    private var scrolling = false

    public init() {}

    private static func focusAndSpan(_ points: [(x: Double, y: Double)]) -> (x: Double, y: Double, span: Double) {
        let count = Double(points.count)
        let fx = points.map(\.x).reduce(0, +) / count, fy = points.map(\.y).reduce(0, +) / count
        let span = points.map { (($0.x - fx) * ($0.x - fx) + ($0.y - fy) * ($0.y - fy)).squareRoot() }.reduce(0, +) / count * 2
        return (fx, fy, span)
    }

    /// The fingers changed (one went down or up): measuring starts again from where they are.
    public mutating func reset(_ points: [(x: Double, y: Double)]) {
        guard !points.isEmpty else {
            self = PanZoomGesture()
            return
        }
        let (fx, fy, span) = Self.focusAndSpan(points)
        lastFocus = (fx, fy)
        lastSpan = span
        // Android's detector measures the pan from where the fingers were when the last one went down
        if !scrolling { downFocus = (fx, fy) }
    }

    /// The fingers moved to [points]: zooms and pans [zoom]. [slop] is the motion the middle needs before it pans.
    public mutating func moved(_ points: [(x: Double, y: Double)], zoom: inout PanZoom, surface: TouchSurface, slop: Double) {
        guard !points.isEmpty, let last = lastFocus else {
            reset(points)
            return
        }
        let (fx, fy, span) = Self.focusAndSpan(points)
        if points.count >= 2, lastSpan > 0, span > 0 {
            zoom.zoom(by: span / lastSpan, focusX: fx, focusY: fy, surface: surface)
        }
        if !scrolling, let down = downFocus, ((fx - down.x) * (fx - down.x) + (fy - down.y) * (fy - down.y)).squareRoot() > slop {
            scrolling = true
        }
        if scrolling { zoom.pan(dx: fx - last.x, dy: fy - last.y, surface: surface) }
        lastFocus = (fx, fy)
        lastSpan = span
    }
}
