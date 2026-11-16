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
        let w = blur > 0 ? width : sharpWidth
        let h = height(area, width: w)
        let scale = Double(w) / area.width
        let layout = HeroGeometry.layout(area, width: source.width, height: source.height)
        var out: Bitmap
        let hues: GameColors?
        if layout.extended {
            guard let extensionImage = extensionBitmap(source, area: area)?.image(),
                  var composed = Bitmap(width: w, height: h),
                  var band = Bitmap(width: w, height: h) else { return nil }
            composed.draw(extensionImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            let top = layout.top * scale, bottom = layout.bottom * scale, fade = layout.fade * scale
            band.draw(source, in: CGRect(x: layout.left * scale, y: top, width: layout.width * scale, height: layout.height * scale))
            band.fadeRows(from: bottom - fade, to: bottom)
            composed.composite(band)
            composed.saturate(saturation)
            out = composed
            hues = coverCrop(source, width: w, height: h).map { GameColors.dominant($0.argb()) } ?? nil
        } else {
            guard let crop = coverCrop(source, width: w, height: h) else { return nil }
            out = crop
            hues = GameColors.dominant(crop.argb())
        }
        // CSS blur(σ) in stage pixels at this scale; three box blurs approximate a Gaussian
        let radius = Int((Double(blur) * scale).rounded())
        if radius > 0 { out.boxBlur(radius: radius, passes: 3) }
        out.fadeDiagonally()
        guard let image = out.image() else { return nil }
        return Result(image: image, colors: hues)
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

/// An RGBA bitmap, 8 bits per channel, premultiplied, its first row at the top.
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

    /// Android's `ColorMatrix.setSaturation`: the luminance weights 0.213, 0.715, 0.072.
    mutating func saturate(_ s: Double) {
        let inv = 1 - s
        let r = 0.213 * inv, g = 0.715 * inv, b = 0.072 * inv
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[i]), green = Double(pixels[i + 1]), blue = Double(pixels[i + 2])
            let limit = Double(pixels[i + 3])
            func clamp(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), limit).rounded()) }
            pixels[i] = clamp((r + s) * red + g * green + b * blue)
            pixels[i + 1] = clamp(r * red + (g + s) * green + b * blue)
            pixels[i + 2] = clamp(r * red + g * green + (b + s) * blue)
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
        for y in 0..<height {
            let center = Double(y) + 0.5
            guard center > start else { continue }
            let k = HeroGeometry.fadeOpacity((center - start) / length)
            for i in stride(from: y * width * 4, to: (y + 1) * width * 4, by: 1) {
                pixels[i] = UInt8((Double(pixels[i]) * k).rounded())
            }
        }
    }

    /// [top] drawn over this bitmap (both premultiplied, same size).
    mutating func composite(_ top: Bitmap) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let keep = 255 - Int(top.pixels[i + 3])
            for c in 0..<4 {
                pixels[i + c] = UInt8(min(255, Int(top.pixels[i + c]) + (Int(pixels[i + c]) * keep + 127) / 255))
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

    /// Opaque in the top-right corner, gone in the bottom-left one (gradient stops 0.3 → 0.95, `fadeDiagonally`).
    mutating func fadeDiagonally() {
        let dx = -Double(width), dy = Double(height)
        let length2 = dx * dx + dy * dy
        for y in 0..<height {
            for x in 0..<width {
                let t = (Double(x - width) * dx + Double(y) * dy) / length2
                let a = min(max((0.95 - t) / 0.65, 0), 1)
                guard a < 1 else { continue }
                let i = (y * width + x) * 4
                for c in 0..<4 { pixels[i + c] = UInt8(Double(pixels[i + c]) * a) }
            }
        }
    }
}
