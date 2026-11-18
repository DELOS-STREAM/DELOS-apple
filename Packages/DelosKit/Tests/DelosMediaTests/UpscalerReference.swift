import simd
import Foundation
import Metal
import Testing
@testable import DelosMedia

/// An RGBA picture in floats, row 0 at the top, with the GPU's sampling rules (clamp to edge) on the CPU: the reference
/// the upscaler's shaders are compared with. The formulas are DELOS for Android's GLSL (app/src/main/assets/sgsr) and its
/// CPU reference `SharpenOnly.java`, written again in Swift.
struct ReferenceImage {
    var width: Int
    var height: Int
    var pixels: [SIMD4<Float>]

    init(width: Int, height: Int, pixel: (Int, Int) -> SIMD4<Float>) {
        self.width = width
        self.height = height
        pixels = (0..<height).flatMap { y in (0..<width).map { x in pixel(x, y) } }
    }

    func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// Bilinear sampling at `uv` (0–1).
    func sample(_ u: Float, _ v: Float) -> SIMD4<Float> {
        let x = u * Float(width) - 0.5, y = v * Float(height) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Float(x0), fy = y - Float(y0)
        let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
        let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// `textureGather` of one channel: (i0, j1), (i1, j1), (i1, j0), (i0, j0).
    func gather(_ u: Float, _ v: Float, _ channel: Int) -> SIMD4<Float> {
        let i0 = Int((u * Float(width) - 0.5).rounded(.down)), j0 = Int((v * Float(height) - 0.5).rounded(.down))
        return SIMD4(texel(i0, j0 + 1)[channel], texel(i0 + 1, j0 + 1)[channel], texel(i0 + 1, j0)[channel], texel(i0, j0)[channel])
    }

    /// The picture as an `rgba8Unorm` or `rgba16Float`-readable `rgba32Float` texture.
    func texture(_ device: any MTLDevice, format: MTLPixelFormat = .rgba8Unorm) throws -> any MTLTexture {
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        description.usage = [.shaderRead, .renderTarget]
        description.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: description))
        if format == .rgba8Unorm {
            let bytes = pixels.flatMap { p in (0..<4).map { UInt8((min(max(p[$0], 0), 1) * 255).rounded()) } }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        } else {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 16)
        }
        return texture
    }

    /// The same picture with its values rounded as an 8-bit texture holds them.
    var quantized: ReferenceImage {
        var copy = self
        copy.pixels = pixels.map { p in SIMD4((0..<4).map { (min(max(p[$0], 0), 1) * 255).rounded() / 255 }) }
        return copy
    }

    /// A deterministic pattern with edges, gradients and noise.
    static func pattern(width: Int, height: Int, seed: UInt32 = 7) -> ReferenceImage {
        var state = seed
        func noise() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        return ReferenceImage(width: width, height: height) { x, y in
            let edge: Float = (x / 5 + y / 7) % 2 == 0 ? 0.85 : 0.15
            let gradient = Float(x) / Float(width)
            return SIMD4(edge * 0.7 + noise() * 0.3, gradient * 0.6 + noise() * 0.2, (edge + gradient) * 0.4, 1)
        }.quantized
    }

    static func uniform(_ color: SIMD4<Float>, width: Int, height: Int) -> ReferenceImage {
        ReferenceImage(width: width, height: height) { _, _ in color }.quantized
    }
}

/// The CPU versions of the shaders, per output pixel.
enum UpscalerReference {
    /// `sharpen_only.frag` (`SharpenOnly.channel` per channel) at the picture's own size.
    static func sharpenOnly(_ image: ReferenceImage, sharpness: Float) -> ReferenceImage {
        ReferenceImage(width: image.width, height: image.height) { x, y in
            let e = image.texel(x, y)
            guard sharpness > 0 else { return SIMD4(e.x, e.y, e.z, 1) }
            let b = image.texel(x, y - 1), d = image.texel(x - 1, y), f = image.texel(x + 1, y), h = image.texel(x, y + 1)
            var out = SIMD4<Float>(0, 0, 0, 1)
            for c in 0..<3 {
                let mn = min(min(min(d[c], e[c]), min(f[c], b[c])), h[c])
                let mx = max(max(max(d[c], e[c]), max(f[c], b[c])), h[c])
                let amp = (min(mn, 1 - mx) / max(mx, 1e-4)).clamped(0, 1).squareRoot()
                let w = -amp * (0.2 * sharpness.clamped(0, 1).squareRoot())
                out[c] = (((b[c] + d[c] + f[c] + h[c]) * w + e[c]) / (1 + 4 * w)).clamped(0, 1)
            }
            return out
        }
    }

    /// `supersample_present.frag` at the picture's own size (each sample on a texel).
    static func supersamplePresent(_ image: ReferenceImage, strength: Float) -> ReferenceImage {
        ReferenceImage(width: image.width, height: image.height) { x, y in
            let center = image.texel(x, y)
            guard strength > 0 else { return SIMD4(center.x, center.y, center.z, 1) }
            let l = image.texel(x - 1, y), r = image.texel(x + 1, y), d = image.texel(x, y - 1), u = image.texel(x, y + 1)
            var out = SIMD4<Float>(0, 0, 0, 1)
            for c in 0..<3 {
                let low = min(center[c], min(min(l[c], r[c]), min(d[c], u[c])))
                let high = max(center[c], max(max(l[c], r[c]), max(d[c], u[c])))
                let limit = min(0.06, (high - low) * 0.25)
                let detail = center[c] - (l[c] + r[c] + d[c] + u[c]) * 0.25
                out[c] = (center[c] + (detail * strength * 0.375).clamped(-limit, limit)).clamped(0, 1)
            }
            return out
        }
    }

    private static func lanczos2(_ x: Float) -> Float {
        var wA = x - 4
        let wB = x * wA - wA
        wA *= wA
        return wB * wA
    }

    private static func direction(_ left: SIMD4<Float>, _ right: SIMD4<Float>) -> SIMD2<Float> {
        let rxlz = right.x - left.z, rwly = right.w - left.y
        let delta = SIMD2(rxlz + rwly, rxlz - rwly)
        return delta / (delta.x * delta.x + 3.075740e-05 + delta.y * delta.y).squareRoot()
    }

    /// The four gathers of the shader around `uv`: left, right, upDown, the fraction, at stream size `size`.
    private static func neighbourhood(
        _ image: ReferenceImage, u: Float, v: Float, gather: (Float, Float) -> SIMD4<Float>
    ) -> (left: SIMD4<Float>, right: SIMD4<Float>, upDown: SIMD4<Float>, pl: SIMD2<Float>, coord: SIMD2<Float>) {
        let rcp = SIMD2<Float>(1 / Float(image.width), 1 / Float(image.height))
        let imgCoord = SIMD2(u * Float(image.width), v * Float(image.height)) + SIMD2(-0.5, 0.5)
        let pixel = SIMD2(imgCoord.x.rounded(.down), imgCoord.y.rounded(.down))
        var coord = pixel * rcp
        let left = gather(coord.x, coord.y)
        coord.x += rcp.x
        let right = gather(coord.x + rcp.x, coord.y)
        let up = gather(coord.x, coord.y - rcp.y), down = gather(coord.x, coord.y + rcp.y)
        return (left, right, SIMD4(up.w, up.z, down.y, down.x), imgCoord - pixel, coord)
    }

    /// `sgsr1.frag` (Standard) drawing `image` into `width` × `height`.
    static func sgsr1(_ image: ReferenceImage, width: Int, height: Int) -> ReferenceImage {
        let enabled = width >= image.width && height >= image.height
        return ReferenceImage(width: width, height: height) { x, y in
            let u = (Float(x) + 0.5) / Float(width), v = (Float(y) + 0.5) / Float(height)
            var color = image.sample(u, v)
            color.w = 1
            guard enabled else { return color }
            var (left, right, upDown, pl, _) = neighbourhood(image, u: u, v: v) { image.gather($0, $1, 1) }
            let edgeVote = abs(left.z - left.y) + abs(color.y - left.y) + abs(color.y - left.z)
            guard edgeVote > 8.0 / 255.0 else { return color }
            let mean = (left.y + left.z + right.x + right.w) * 0.25
            left -= mean; right -= mean; upDown -= mean
            let centre = color.y - mean
            let sum = [left, right, upDown].map { abs($0.x) + abs($0.y) + abs($0.z) + abs($0.w) }.reduce(0, +)
            let sumMean = 1.014185e+01 / sum
            let std = sumMean * sumMean
            let dir = direction(left, right)
            func weight(_ dx: Float, _ dy: Float, _ c: Float) -> SIMD2<Float> {
                let edgeDis = dx * dir.y + dy * dir.x
                let w = lanczos2(dx * dx + dy * dy + edgeDis * edgeDis * ((c * c * std).clamped(0, 1) * 0.7 - 1))
                return SIMD2(w, w * c)
            }
            var a = weight(pl.x, pl.y + 1, upDown.x)
            a += weight(pl.x - 1, pl.y + 1, upDown.y)
            a += weight(pl.x - 1, pl.y - 2, upDown.z)
            a += weight(pl.x, pl.y - 2, upDown.w)
            a += weight(pl.x + 1, pl.y - 1, left.x)
            a += weight(pl.x, pl.y - 1, left.y)
            a += weight(pl.x, pl.y, left.z)
            a += weight(pl.x + 1, pl.y, left.w)
            a += weight(pl.x - 1, pl.y - 1, right.x)
            a += weight(pl.x - 2, pl.y - 1, right.y)
            a += weight(pl.x - 2, pl.y, right.z)
            a += weight(pl.x - 1, pl.y, right.w)
            let maxY = max(max(left.y, left.z), max(right.x, right.w)), minY = min(min(left.y, left.z), min(right.x, right.w))
            let delta = ((2 * a.y / a.x).clamped(minY, maxY) - centre).clamped(-23.0 / 255.0, 23.0 / 255.0)
            return SIMD4((color.x + delta).clamped(0, 1), (color.y + delta).clamped(0, 1), (color.z + delta).clamped(0, 1), 1)
        }
    }

    /// SGSR 2's reconstruction of a frame that starts the history (`sgsr2_video.frag` with reset 1): the 3 × 3 Lanczos
    /// upsample clamped to the neighbourhood's colours.
    static func temporalReset(_ image: ReferenceImage, width: Int, height: Int) -> ReferenceImage {
        ReferenceImage(width: width, height: height) { x, y in
            let uv = SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
            let size = SIMD2(Float(image.width), Float(image.height))
            let input = SIMD2(Int(uv.x * size.x), Int(uv.y * size.y))
            let offset = SIMD2(Float(input.x), Float(input.y)) + 0.5 - uv * size
            var sum = SIMD3<Float>(repeating: 0), total: Float = 0
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for dy in -1...1 {
                for dx in -1...1 {
                    let c = image.texel(input.x + dx, input.y + dy)
                    let colour = SIMD3(c.x, c.y, c.z)
                    let o = offset + SIMD2(Float(dx), Float(dy))
                    let base = ((o.x * o.x + o.y * o.y) * 0.25).clamped(0, 1)
                    let yy = base - 1
                    let w = (0.75 * yy + yy * yy) * yy * yy
                    sum += colour * w
                    total += w
                    low = simd_min(low, colour)
                    high = simd_max(high, colour)
                }
            }
            let result: SIMD3<Float>
            if abs(total) > 1e-6 {
                result = simd_clamp(sum / total, low, high)
            } else {
                let s = image.sample(uv.x, uv.y)
                result = SIMD3(s.x, s.y, s.z)
            }
            return SIMD4(result, 0)
        }
    }
}

extension Float {
    func clamped(_ low: Float, _ high: Float) -> Float { Swift.min(Swift.max(self, low), high) }
}

/// Runs one of the upscaler's fragment passes on the GPU into an `rgba32Float` target and reads it back.
enum UpscalerGPU {
    static func drawer() throws -> MetalFrameDrawer { try #require(MetalFrameDrawer()) }

    static func target(_ device: any MTLDevice, width: Int, height: Int, format: MTLPixelFormat = .rgba32Float) throws -> any MTLTexture {
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        return try #require(device.makeTexture(descriptor: description))
    }

    static func read(_ texture: any MTLTexture) -> ReferenceImage {
        var floats = [SIMD4<Float>](repeating: .zero, count: texture.width * texture.height)
        texture.getBytes(&floats, bytesPerRow: texture.width * 16, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return ReferenceImage(width: texture.width, height: texture.height) { x, y in floats[y * texture.width + x] }
    }

    static func run<Uniforms: BitwiseCopyable>(
        _ fragment: String, source: ReferenceImage, width: Int, height: Int, uniforms: Uniforms
    ) throws -> ReferenceImage {
        let drawer = try drawer()
        let input = try source.texture(drawer.device)
        let output = try target(drawer.device, width: width, height: height)
        let command = try #require(drawer.queue.makeCommandBuffer())
        #expect(drawer.cache.draw(fragment, into: output, textures: [input], uniforms: uniforms, commandBuffer: command))
        command.commit()
        command.waitUntilCompleted()
        return read(output)
    }

    /// Pixels whose RGB channels differ by more than `above`.
    static func mismatches(_ a: ReferenceImage, _ b: ReferenceImage, above: Float) -> Int {
        zip(a.pixels, b.pixels).filter { p, q in max(abs(p.x - q.x), abs(p.y - q.y), abs(p.z - q.z)) > above }.count
    }

    /// The mean absolute difference of the RGB channels.
    static func meanDifference(_ a: ReferenceImage, _ b: ReferenceImage) -> Float {
        zip(a.pixels, b.pixels).map { p, q in (abs(p.x - q.x) + abs(p.y - q.y) + abs(p.z - q.z)) / 3 }.reduce(0, +) / Float(a.pixels.count)
    }

    /// The largest difference of the RGB channels of two pictures of one size.
    static func difference(_ a: ReferenceImage, _ b: ReferenceImage) -> Float {
        zip(a.pixels, b.pixels).map { p, q in max(abs(p.x - q.x), abs(p.y - q.y), abs(p.z - q.z)) }.max() ?? .infinity
    }
}
