import Accelerate
import CoreGraphics
import Foundation

/// The game background as one small picture (`HeroBitmaps.render` of DELOS for Android): the hero composition of
/// ``HeroGeometry`` over the hero area, saturated by 1.15, blurred and faded out diagonally from the top-right corner to
/// the bottom-left one. With a blur it is 420 pixels wide (the blur hides the rest; the screen scales it up), without
/// one ``sharpWidth``. Also works out the game background's colors.
enum HeroRender {
    static let width = 420
    /// The width of an unblurred background.
    static let sharpWidth = 1600
    static let saturation = 1.15
    /// The extension is drawn at a tenth of the area: it is blurred by 40 px anyway.
    static let extensionScale = 0.1

    struct Result: Sendable {
        let image: CGImage
        /// The main colors of the background (the plain crop's for a wide hero, whose extension's tint would mute them).
        let colors: GameColors?
    }

    /// The bitmap's height for [area] at [width]: 252 for the standard area at 420.
    static func height(_ area: HeroArea, width: Int = width) -> Int {
        max(1, Int((Double(width) * area.height / area.width).rounded()))
    }

    /// Renders [source] with a blur of [blur] stage pixels (CSS blur(σ)) for [area]. Call off the main thread.
    static func render(_ source: CGImage, blur: Int, area: HeroArea) -> Result? {
        let extended = HeroGeometry.layout(area, width: source.width, height: source.height).extended
        let underlay = extended ? extensionImage(source, area: area) : nil
        if extended, underlay == nil { return nil }
        guard let composed = compose(source, blur: blur, area: area, extension: underlay, colors: true),
              let image = composed.bitmap.image() else { return nil }
        return Result(image: image, colors: composed.colors)
    }

    /// A frame of an animated game background: [source] (the frame, decoded as small as it is drawn) rendered like
    /// ``render(_:blur:area:)``, over [extension] (``extensionImage(_:area:)`` of the still first frame) for a wide hero,
    /// without working out the colors. Call off the main thread.
    static func frame(_ source: CGImage, blur: Int, area: HeroArea, extension: CGImage?) -> CGImage? {
        compose(source, blur: blur, area: area, extension: `extension`, colors: false)?.bitmap.image()
    }

    /// The blurred, darkened extension under a wide hero (`HeroBitmaps.extension`), nil when [source] has none to make.
    static func extensionImage(_ source: CGImage, area: HeroArea) -> CGImage? {
        extensionBitmap(source, area: area)?.image()
    }

    /// The composition, saturated, blurred and faded; with [colors], the main colors too (the plain crop's for a wide hero,
    /// whose extension's tint would mute them).
    private static func compose(_ source: CGImage, blur: Int, area: HeroArea, extension extensionImage: CGImage?,
                                colors: Bool) -> (bitmap: Bitmap, colors: GameColors?)? {
        let w = blur > 0 ? width : sharpWidth
        let h = height(area, width: w)
        let scale = Double(w) / area.width
        let layout = HeroGeometry.layout(area, width: source.width, height: source.height)
        var out: Bitmap
        let hues: GameColors?
        if layout.extended {
            guard let extensionImage, var composed = Bitmap(width: w, height: h), var band = Bitmap(width: w, height: h) else { return nil }
            composed.draw(extensionImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            let top = layout.top * scale, bottom = layout.bottom * scale, fade = layout.fade * scale
            band.draw(source, in: CGRect(x: layout.left * scale, y: top, width: layout.width * scale, height: layout.height * scale))
            band.fadeRows(from: bottom - fade, to: bottom)
            composed.composite(band)
            composed.saturate(saturation)
            out = composed
            hues = colors ? coverCrop(source, width: w, height: h).flatMap { GameColors.dominant($0.argb()) } : nil
        } else {
            guard let crop = coverCrop(source, width: w, height: h) else { return nil }
            out = crop
            hues = colors ? GameColors.dominant(crop.argb()) : nil
        }
        // CSS blur(σ) in stage pixels at this scale; three box blurs approximate a Gaussian
        let radius = Int((Double(blur) * scale).rounded())
        if radius > 0 { out.boxBlur(radius: radius, passes: 3) }
        out.fadeDiagonally()
        return (out, hues)
    }

    /// The image cropped to fill [width] × [height], saturated.
    private static func coverCrop(_ source: CGImage, width: Int, height: Int) -> Bitmap? {
        guard var bitmap = Bitmap(width: width, height: height) else { return nil }
        let scale = max(Double(width) / Double(source.width), Double(height) / Double(source.height))
        let w = Double(source.width) * scale, h = Double(source.height) * scale
        bitmap.draw(source, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        bitmap.saturate(saturation)
        return bitmap
    }

    /// The blurred, darkened copy that fills the area under a wide hero's band (`HeroBitmaps.extension`).
    private static func extensionBitmap(_ source: CGImage, area: HeroArea) -> Bitmap? {
        let w = Int((area.width * extensionScale).rounded()), h = Int((area.height * extensionScale).rounded())
        guard var bitmap = Bitmap(width: w, height: h) else { return nil }
        let cover = HeroGeometry.cover(area, width: source.width, height: source.height)
        bitmap.draw(source, in: CGRect(x: cover.left * extensionScale, y: cover.top * extensionScale,
                                       width: cover.width * extensionScale, height: cover.height * extensionScale))
        bitmap.boxBlur(radius: Int((HeroGeometry.extensionBlur * extensionScale).rounded()), passes: 3)
        bitmap.tint(HeroGeometry.extensionTint, amount: HeroGeometry.extensionTintAmount)
        return bitmap
    }
}

/// How the frames of an animated game background are made (`HeroLive`): decoded no wider than the render draws them (and
/// never above ``AnimatedPlayback/heroWidth``), then rendered exactly like the still one (``HeroRender/frame(_:blur:area:extension:)``),
/// over the still first frame's extension for a wide hero.
struct HeroFrameRender: Sendable {
    /// The longest side a frame is decoded at, at most (``AnimationPlayer/load(_:maxWidth:maxHeight:fit:repeats:render:)``'s maxWidth).
    let decodeWidth: Int
    private let blur: Int
    private let area: HeroArea
    private let underlay: CGImage?

    /// The frames of the animation whose still first frame is [still]; nil when a wide hero's extension cannot be made. Renders
    /// that extension: call off the main thread.
    init?(still: CGImage, blur: Int, area: HeroArea) {
        let layout = HeroGeometry.layout(area, width: still.width, height: still.height)
        underlay = layout.extended ? HeroRender.extensionImage(still, area: area) : nil
        if layout.extended, underlay == nil { return nil }
        let drawn = Int((layout.width * Double(blur > 0 ? HeroRender.width : HeroRender.sharpWidth) / area.width).rounded())
        decodeWidth = min(AnimatedPlayback.heroWidth, max(drawn, 1))
        self.blur = blur
        self.area = area
    }

    /// Decoded frame [image], rendered.
    func frame(_ image: CGImage) -> CGImage? {
        HeroRender.frame(image, blur: blur, area: area, extension: underlay)
    }
}

/// An RGBA bitmap, 8 bits per channel, premultiplied, its first row at the top. What runs on every frame of an animated
/// game background is CoreGraphics' or Accelerate's work, never a loop over the pixels in Swift: unoptimized (a debug
/// build) such loops took about 100 ms a frame, and the background played at a few frames a second.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// Runs [body] with the pixels as a vImage buffer.
    private mutating func withBuffer(_ body: (vImage_Buffer) -> Void) {
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { bytes in
            body(vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4))
        }
    }

    /// Multiplies every row by its opacity, which [opacity] gives for row y: the same across the row (`left == right`) or
    /// running linearly from `left` (the first pixel) to `right` (the last one), within 0 to 1. The channels are rounded,
    /// or truncated without [rounded]. A row at full opacity is not touched, one at none is cleared.
    private mutating func fade(rounded: Bool, _ opacity: (_ y: Int) -> (left: Double, right: Double)) {
        let (w, h, count) = (width, height, width * 4)
        var scratch = [Double](repeating: 0, count: count + w)
        pixels.withUnsafeMutableBufferPointer { pixels in
            scratch.withUnsafeMutableBufferPointer { scratch in
                guard let first = pixels.baseAddress, let values = scratch.baseAddress else { return }
                let ramp = values + count
                var (low, high) = (0.0, 1.0)
                for y in 0..<h {
                    let (left, right) = opacity(y)
                    if left >= 1, right >= 1 { continue }
                    let row = first + y * count
                    if left <= 0, right <= 0 {
                        row.update(repeating: 0, count: count)
                        continue
                    }
                    vDSP_vfltu8D(row, 1, values, 1, vDSP_Length(count))
                    if left == right || w == 1 {
                        var k = min(max(left, 0), 1)
                        vDSP_vsmulD(values, 1, &k, values, 1, vDSP_Length(count))
                    } else {
                        var (start, step) = (left, (right - left) / Double(w - 1))
                        vDSP_vrampD(&start, &step, ramp, 1, vDSP_Length(w))
                        vDSP_vclipD(ramp, 1, &low, &high, ramp, 1, vDSP_Length(w))
                        for channel in 0..<4 { vDSP_vmulD(values + channel, 4, ramp, 1, values + channel, 4, vDSP_Length(w)) }
                    }
                    if rounded {
                        vDSP_vfixru8D(values, 1, row, 1, vDSP_Length(count))
                    } else {
                        vDSP_vfixu8D(values, 1, row, 1, vDSP_Length(count))
                    }
                }
            }
        }
    }

    /// Draws [image] into [rect], given from the top-left corner.
    mutating func draw(_ image: CGImage, in rect: CGRect) {
        let (w, h) = (width, height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: Self.space, bitmapInfo: Self.info) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: rect.minX, y: Double(h) - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    func image() -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: Self.space,
                       bitmapInfo: CGBitmapInfo(rawValue: Self.info), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// The pixels as 0xAARRGGBB with straight alpha.
    func argb() -> [UInt32] {
        stride(from: 0, to: pixels.count, by: 4).map { i in
            let a = UInt32(pixels[i + 3])
            func straight(_ c: UInt8) -> UInt32 { a == 0 ? 0 : min(255, (UInt32(c) * 255 + a / 2) / a) }
            return a << 24 | straight(pixels[i]) << 16 | straight(pixels[i + 1]) << 8 | straight(pixels[i + 2])
        }
    }

    /// Android's `ColorMatrix.setSaturation`: the luminance weights 0.213, 0.715, 0.072; a color never above its alpha.
    mutating func saturate(_ s: Double) {
        let inv = 1 - s
        let weights = [0.213 * inv, 0.715 * inv, 0.072 * inv]
        // Pixels are rows multiplied by the matrix (a source channel's row, a result channel's column), in 1/16384ths
        let divisor: Int32 = 1 << 14
        var matrix = [Int16](repeating: 0, count: 16)
        for from in 0..<3 {
            for to in 0..<3 { matrix[from * 4 + to] = Int16(((weights[from] + (from == to ? s : 0)) * Double(divisor)).rounded()) }
        }
        matrix[15] = Int16(divisor)
        let rounding = [Int32](repeating: divisor / 2, count: 4)
        withBuffer { buffer in
            var (src, dest) = (buffer, buffer)
            vImageMatrixMultiply_ARGB8888(&src, &dest, matrix, divisor, nil, rounding, vImage_Flags(kvImageNoFlags))
            vImageClipToAlpha_RGBA8888(&src, &dest, vImage_Flags(kvImageNoFlags))
        }
    }

    /// Blends every pixel toward [color] by [amount] and makes it opaque.
    mutating func tint(_ color: (r: Double, g: Double, b: Double), amount: Double) {
        let keep = 1 - amount
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8((Double(pixels[i]) * keep + color.r * amount).rounded())
            pixels[i + 1] = UInt8((Double(pixels[i + 1]) * keep + color.g * amount).rounded())
            pixels[i + 2] = UInt8((Double(pixels[i + 2]) * keep + color.b * amount).rounded())
            pixels[i + 3] = 255
        }
    }

    /// Fades the rows from [start] (opaque) to [end] (gone) along ``HeroGeometry/fadeStops``; rows below [end] are cleared.
    mutating func fadeRows(from start: Double, to end: Double) {
        let length = max(end - start, 1)
        fade(rounded: true) { y in
            let center = Double(y) + 0.5
            let k = center > start ? HeroGeometry.fadeOpacity((center - start) / length) : 1
            return (k, k)
        }
    }

    /// [top] drawn over this bitmap (both premultiplied, same size).
    mutating func composite(_ top: Bitmap) {
        top.pixels.withUnsafeBytes { above in
            withBuffer { below in
                // Read only: the top image is the blend's first source
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: above.baseAddress), height: below.height,
                                        width: below.width, rowBytes: below.rowBytes)
                var (under, dest) = (below, below)
                vImagePremultipliedAlphaBlend_BGRA8888(&src, &under, &dest, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    /// [passes] box blurs of [radius] pixels across and down (edges extended): about a Gaussian.
    mutating func boxBlur(radius: Int, passes: Int) {
        guard radius > 0 else { return }
        let (w, h) = (width, height)
        var scratch = [UInt8](repeating: 0, count: pixels.count)
        let kernel = UInt32(2 * radius + 1)
        pixels.withUnsafeMutableBytes { a in
            scratch.withUnsafeMutableBytes { b in
                var src = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                for _ in 0..<passes {
                    // Across, then down: two one-dimensional boxes, as Android's passes
                    vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, 1, kernel, nil, vImage_Flags(kvImageEdgeExtend))
                    vImageBoxConvolve_ARGB8888(&dst, &src, nil, 0, 0, kernel, 1, nil, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
    }

    /// Opaque in the top-right corner, gone in the bottom-left one (gradient stops 0.3 → 0.95, `fadeDiagonally`), along the
    /// diagonal between them.
    mutating func fadeDiagonally() {
        let (w, dx, dy) = (width, -Double(width), Double(height))
        let length2 = dx * dx + dy * dy
        func opacity(_ x: Int, _ y: Int) -> Double { (0.95 - (Double(x - w) * dx + Double(y) * dy) / length2) / 0.65 }
        fade(rounded: false) { y in (opacity(0, y), opacity(w - 1, y)) }
    }
}
