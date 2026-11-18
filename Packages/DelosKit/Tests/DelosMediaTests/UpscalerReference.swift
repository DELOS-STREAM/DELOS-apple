import simd
import Foundation
import Metal
import Testing
@testable import DelosMedia

/// An RGBA picture in floats, row 0 at the top, with the GPU's sampling rules (clamp to edge) on the CPU: the reference
/// the upscaler's own shaders are compared with (CAS written again in Swift).
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

/// The CPU version of the CAS pass, per output pixel.
enum UpscalerReference {
    /// `casFragment` at the picture's own size, per channel.
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
