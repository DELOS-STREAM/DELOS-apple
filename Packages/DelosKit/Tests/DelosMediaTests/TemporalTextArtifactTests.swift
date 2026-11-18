import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import DelosMedia

/// Text over independently moving content, at the original iPad-sized lab's input/output sizes. The noise and scene
/// are deterministic; neither a host nor a stream is involved. Optional PNGs contain the actual presented output.
@Suite(.serialized) struct TemporalTextArtifactTests {
    private static let width = 1440, height = 1080, outputWidth = 2752, outputHeight = 2064
    private static let scale = CGFloat(outputWidth) / CGFloat(width)

    private func texture(
        _ drawer: MetalFrameDrawer, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> any MTLTexture {
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        description.storageMode = .shared
        description.usage = usage
        return try #require(drawer.device.makeTexture(descriptor: description))
    }

    private func read<T: BitwiseCopyable>(
        _ texture: any MTLTexture, drawer: MetalFrameDrawer, channels: Int, zero: T
    ) throws -> [T] {
        let shared = try self.texture(drawer, texture.pixelFormat, texture.width, texture.height, usage: [.shaderRead])
        let command = try #require(drawer.queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed && command.error == nil)
        var result = [T](repeating: zero, count: texture.width * texture.height * channels)
        result.withUnsafeMutableBytes { bytes in
            shared.getBytes(
                bytes.baseAddress!, bytesPerRow: texture.width * channels * MemoryLayout<T>.stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    private func dispatch(
        _ name: String, textures: [any MTLTexture], size: (Int, Int), drawer: MetalFrameDrawer,
        encoder: any MTLComputeCommandEncoder
    ) throws {
        encoder.setComputePipelineState(try #require(drawer.cache.compute(name)))
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        encoder.dispatchThreadgroups(
            MTLSize(width: (size.0 + 7) / 8, height: (size.1 + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    /// Known motion separates the upsampling/masking regression from the optical-flow estimator. Zero fits the static
    /// glyph exactly, whereas it must not replace the known motion of a moving glyph or background.
    @Test(arguments: [false, true], [false, true])
    func motionSelectionAndBoundaryRejection(movingGlyph: Bool, mixedGrid: Bool) throws {
        let drawer = try UpscalerGPU.drawer()
        let w = 64, h = 40
        func background(_ x: Int, _ y: Int) -> Float {
            0.35 + 0.08 * sin(Float(x) * 0.3 + Float(y) * 0.13) + 0.08 * cos(Float(y) * 0.17)
        }
        func glyph(_ x: Int, _ y: Int) -> Bool {
            (20..<24).contains(x) && (8..<32).contains(y) ||
                (32..<36).contains(x) && (8..<32).contains(y) ||
                (20..<36).contains(x) && (18..<22).contains(y)
        }
        let previous = ReferenceImage(width: w, height: h) { x, y in
            let v: Float = glyph(x, y) ? 0.95 : background(x, y)
            return SIMD4(v, v, v, 1)
        }
        let current = ReferenceImage(width: w, height: h) { x, y in
            let v: Float = glyph(x + (movingGlyph ? 4 : 0), y) ? 0.95 : background(x + 4, y)
            return SIMD4(v, v, v, 1)
        }
        let before = try previous.texture(drawer.device, format: .rgba32Float)
        let now = try current.texture(drawer.device, format: .rgba32Float)
        let backward = try texture(drawer, .rgba32Float, 8, 5)
        var b = [SIMD4<Float>](repeating: SIMD4(4, 0, 0, 1), count: 40)
        if mixedGrid {
            for y in 0..<5 { for x in 0..<8 where x % 2 == 0 { b[y * 8 + x].x = 0 } }
        }
        backward.replace(region: MTLRegionMake2D(0, 0, 8, 5), mipmapLevel: 0, withBytes: &b, bytesPerRow: 8 * 16)
        let forward = try texture(drawer, .rgba32Float, 8, 5)
        var f = [SIMD4<Float>](repeating: SIMD4(-4, 0, 0, 1), count: 40)
        forward.replace(region: MTLRegionMake2D(0, 0, 8, 5), mipmapLevel: 0, withBytes: &f, bytesPerRow: 8 * 16)
        let scene = try ReferenceImage.uniform(.zero, width: 1, height: 1).texture(drawer.device)
        let vectors = try texture(drawer, .rg16Float, w, h)
        let raw = try texture(drawer, .r8Unorm, w, h)
        let mask = try texture(drawer, .r16Float, w, h)
        let command = try #require(drawer.queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        var size = SIMD2<Int32>(Int32(w), Int32(h))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
        try dispatch("videoMotion", textures: [vectors, raw, now, before, backward, forward, scene],
                     size: (w, h), drawer: drawer, encoder: encoder)
        try dispatch("videoReactiveMask", textures: [mask, raw, vectors, now],
                     size: (w, h), drawer: drawer, encoder: encoder)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed && command.error == nil)
        let motion: [Float16] = try read(vectors, drawer: drawer, channels: 2, zero: Float16.zero)
        let rejection: [Float16] = try read(mask, drawer: drawer, channels: 1, zero: Float16.zero)
        let edge = 10 * w + (movingGlyph ? 16 : 20)
        #expect(abs(Float(motion[edge * 2]) - (movingGlyph ? 4 : 0)) < 0.001)
        if movingGlyph { #expect(Float(rejection[edge]) < 0.01) }
        let backgroundPixel = 12 * w + 48
        #expect(abs(Float(motion[backgroundPixel * 2]) - 4) < 0.001)
        #expect(Float(rejection[backgroundPixel]) < 0.01)
    }

    /// The boundary pass must preserve existing rejection, including a one-pixel disocclusion and a whole-frame cut.
    /// Odd dimensions also exercise the partial threadgroups and their clamped border loads.
    @Test func boundaryPassPreservesRejectionAndSeparatesContrastFromFlatNoise() throws {
        let drawer = try UpscalerGPU.drawer()
        let w = 67, h = 43, boundary = 33
        let raw = try texture(drawer, .r8Unorm, w, h)
        let motion = try texture(drawer, .rg16Float, w, h)
        let output = try texture(drawer, .r16Float, w, h)
        var vectors = [Float16](repeating: 0, count: w * h * 2)
        for y in 0..<h { for x in 0..<w { vectors[(y * w + x) * 2] = x < boundary ? 0 : 4 } }
        motion.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &vectors, bytesPerRow: w * 4)
        for contrast in [false, true] {
            let luma = try ReferenceImage(width: w, height: h) { x, y in
                let value: Float = contrast ? (x < boundary ? 0.3 : 0.9)
                    : 0.5 + Float((x * 17 + y * 23) % 11 - 5) / 500
                return SIMD4(value, value, value, 1)
            }.texture(drawer.device, format: .rgba32Float)
            for cut in [false, true] {
                var pixels = [UInt8](repeating: cut ? 255 : 0, count: w * h)
                pixels[20 * w + 20] = 255
                raw.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: w)
                let command = try #require(drawer.queue.makeCommandBuffer())
                let encoder = try #require(command.makeComputeCommandEncoder())
                try dispatch("videoReactiveMask", textures: [output, raw, motion, luma],
                             size: (w, h), drawer: drawer, encoder: encoder)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                #expect(command.status == .completed && command.error == nil)
                let result: [Float16] = try read(output, drawer: drawer, channels: 1, zero: Float16.zero)
                #expect(result.enumerated().allSatisfy { i, value in
                    let edge = contrast && (i % w == boundary - 1 || i % w == boundary)
                    let expected: Float = edge ? 1 : Float(pixels[i]) / 255
                    return abs(Float(value) - expected) < 0.001
                })
            }
        }
    }

    private struct SceneUniforms {
        var offset: SIMD2<Float>
        var pixel: Float
        var noise: Float
        var seed: UInt32
        var samples: Int32
        var occluder: Float
    }

    // The deterministic multiscale background from ScratchTextLab, retained as a regression fixture rather than a bench.
    private static let sceneSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct SceneUniforms { float2 offset; float pixel; float noise; uint seed; int samples; float occluder; };
    static float hash(uint2 q, uint s) {
        uint h = q.x * 0x9E3779B1u ^ q.y * 0x85EBCA77u ^ s * 0xC2B2AE3Du;
        h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
        return float(h & 0xFFFFFFu) / 16777216.0;
    }
    static float noise(float2 p, uint s) {
        float2 i = floor(p), f = p - i;
        f = f * f * (3.0 - 2.0 * f);
        uint2 q = uint2(int2(i) + 65536);
        return mix(mix(hash(q, s), hash(q + uint2(1, 0), s), f.x),
                   mix(hash(q + uint2(0, 1), s), hash(q + uint2(1, 1), s), f.x), f.y);
    }
    static float3 background(float2 p) {
        float v = 0.40 * noise(p / 53.0, 1) + 0.24 * noise(p / 21.0, 2) + 0.16 * noise(p / 8.3, 3)
            + 0.12 * noise(p / 3.7, 4) + 0.08 * noise(p / 1.9, 5);
        float region = noise(p / 170.0, 6);
        float stripes = step(0.5, fract((p.x * 0.8 + p.y * 0.6) / 29.0));
        v = mix(v, v * 0.5 + 0.05, stripes * step(0.55, region));
        float tint = noise(p / 97.0, 7);
        return clamp(float3(v * (0.75 + 0.5 * tint), v * (1.05 - 0.2 * tint), 0.15 + v * (1.1 - 0.6 * tint)), 0.0, 1.0);
    }
    kernel void textScene(texture2d<float, access::write> output [[texture(0)]], texture2d<float> overlay [[texture(1)]],
                          constant SceneUniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float3 sum = float3(0.0);
        for (int b = 0; b < u.samples; b++) for (int a = 0; a < u.samples; a++) {
            float2 p = (float2(gid) + (float2(a, b) + 0.5) / float(u.samples)) * u.pixel;
            sum += background(p + u.offset);
        }
        float3 color = sum / float(u.samples * u.samples);
        float4 over = overlay.read(gid);
        color = color * (1.0 - over.a) + over.rgb;
        // A foreground bar sweeps across the glyphs; the exposed picture must not retain their old bright footprint.
        float2 p = (float2(gid) + 0.5) * u.pixel;
        if (u.occluder >= 0.0) {
            float coverage = clamp((42.0 - abs(p.x - u.occluder)) / u.pixel + 0.5, 0.0, 1.0);
            color = mix(color, float3(0.09, 0.13, 0.17), coverage);
        }
        color += (float3(hash(gid, u.seed), hash(gid, u.seed + 77u), hash(gid, u.seed + 154u)) - 0.5) * u.noise;
        output.write(float4(clamp(color, 0.0, 1.0), 1.0), gid);
    }
    """

    /// Actual antialiased font outlines, not a binary bitmap. `grow` builds the same edge/halo/core regions as the lab.
    private func hud(width: Int, height: Int, scale: CGFloat, shift: CGPoint, grow: CGFloat? = nil) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: shift.x, y: shift.y)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) throws {
                let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
                let characters = Array(string.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
                var advances = [CGSize](repeating: .zero, count: glyphs.count)
                CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
                let path = CGMutablePath()
                var pen = x
                for (glyph, advance) in zip(glyphs, advances) {
                    var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pen, ty: y)
                    if let shape = CTFontCreatePathForGlyph(font, glyph, &transform) { path.addPath(shape) }
                    pen += advance.width
                }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.addPath(path)
                context.fillPath()
                if let grow, grow > 0 {
                    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                    context.setLineWidth(2 * grow)
                    context.setLineJoin(.round)
                    context.addPath(path)
                    context.strokePath()
                }
            }
            try text("HP 87/100   MP 42/60   LV 23", x: 48, y: 64, size: 15, bold: true)
            try text("Quest: Find the lost sword of Aldric (2/5)", x: 48, y: 106, size: 11)
            try text("Objective updated: return to the village elder", x: 48, y: 122, size: 11)
            try text("118 FPS   8.4 ms   12.3 Mbps   HEVC 1440x1080", x: 560, y: 40, size: 10)
            let rows = [
                "The gate ahead is sealed by an old ward. Collect three",
                "sigils from the watchtowers to break it, or find another",
                "way around through the flooded mines (requires rope).",
                "Hint: guards change shift at dusk; the east wall is low.",
                "Inventory: 3x Healing Potion, 1x Rope, 12x Iron Arrow",
                "Press [E] to interact - Hold [Q] to open the wheel",
            ]
            for (i, row) in rows.enumerated() { try text(row, x: 860, y: 420 + 16 * CGFloat(i), size: 12) }
            try text("The quick brown fox jumps over the lazy dog 0123456789", x: 360, y: 980, size: 22, bold: true)
            try text("AMMO 30/120", x: 1180, y: 1010, size: 26, bold: true)
        }
        return bytes
    }

    private struct Regions {
        var edge: [Int] = [], halo: [Int] = [], core: [Int] = [], far: [Int] = [], trail: [Int] = []
    }

    private func regions(shift: CGPoint, previous: [UInt8]?, occluder: Float) throws -> (Regions, [UInt8]) {
        let w = Self.outputWidth, h = Self.outputHeight
        let masks = try [CGFloat(0), 1.5, 8, 24].map { try hud(width: w, height: h, scale: Self.scale, shift: shift, grow: $0) }
        var result = Regions()
        for y in 40..<(h - 40) { for x in 40..<(w - 40) {
            let i = y * w + x, a = i * 4 + 3
            let covered = occluder >= 0 && abs(Float(x) / Float(Self.scale) - occluder) < 43
            if masks[1][a] > 127 { result.edge.append(i) }
            else if masks[2][a] > 127 { result.halo.append(i) }
            else if masks[3][a] < 128, x % 4 == 0, y % 4 == 0 { result.far.append(i) }
            if masks[0][a] > 240, !covered { result.core.append(i) }
            if let previous, previous[a] > 127, masks[0][a] < 8 || covered { result.trail.append(i) }
        } }
        return (result, masks[0])
    }

    private func error(_ a: [Float16], _ b: [Float16], at indices: [Int]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var sum: Float = 0
        for i in indices { for c in 0..<3 { sum += abs(Float(a[i * 4 + c]) - Float(b[i * 4 + c])) } }
        return sum / Float(indices.count * 3)
    }

    private struct Metrics {
        var edge: Float = 0, halo: Float = 0, far: Float = 0, trail: Float = 0, flicker: Float = 0
        var frames = 0, flickerFrames = 0
        mutating func add(_ output: [Float16], truth: [Float16], previous: [Float16]?, regions: Regions, test: TemporalTextArtifactTests) {
            edge += test.error(output, truth, at: regions.edge)
            halo += test.error(output, truth, at: regions.halo)
            far += test.error(output, truth, at: regions.far)
            trail += test.error(output, truth, at: regions.trail)
            if let previous {
                flicker += test.error(output, previous, at: regions.core)
                flickerFrames += 1
            }
            frames += 1
        }
        func summary(_ name: String) -> String {
            String(format: "%@ edge %.5f halo %.5f far %.5f trail %.5f core-flicker %.5f", name,
                   edge / Float(frames), halo / Float(frames), far / Float(frames), trail / Float(frames),
                   flicker / Float(max(flickerFrames, 1)))
        }
    }

    private func save(_ values: [Float16], name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DELOS_TEMPORAL_TEXT_ARTIFACTS"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bytes = values.map { UInt8((Float($0).clamped(0, 1) * 255).rounded()) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: Self.outputWidth, height: Self.outputHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Self.outputWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test(.enabled(if: MetalFXSupport.system.spatial && MetalFXSupport.system.temporal), arguments: [false, true])
    func presentedTextOverPanAndMovingGlyphOcclusion(hdr: Bool) throws {
        let drawer = try UpscalerGPU.drawer()
        let library = try drawer.device.makeLibrary(source: Self.sceneSource, options: nil)
        let pipeline = try drawer.device.makeComputePipelineState(function: #require(library.makeFunction(name: "textScene")))
        let w = Self.width, h = Self.height, ow = Self.outputWidth, oh = Self.outputHeight
        let format: MTLPixelFormat = hdr ? .rgba16Float : .rgba8Unorm
        let input = try texture(drawer, format, w, h, usage: MetalUpscaler.sourceUsage.union(.shaderWrite))
        let truth = try texture(drawer, .rgba16Float, ow, oh)
        let overlayIn = try texture(drawer, .rgba8Unorm, w, h, usage: [.shaderRead])
        let overlayOut = try texture(drawer, .rgba8Unorm, ow, oh, usage: [.shaderRead])
        let targets = try (0..<2).map { _ in try texture(drawer, .rgba16Float, ow, oh, usage: [.shaderRead, .renderTarget]) }
        func render(_ target: any MTLTexture, overlay: any MTLTexture, uniforms: SceneUniforms) throws {
            let command = try #require(drawer.queue.makeCommandBuffer())
            let encoder = try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(target, index: 0)
            encoder.setTexture(overlay, index: 1)
            var uniforms = uniforms
            encoder.setBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: (target.width + 7) / 8, height: (target.height + 7) / 8, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed && command.error == nil)
        }
        let scenarios: [(String, SIMD2<Float>, Float, Bool)] = [
            ("clean-pan", SIMD2(2.37, 1.23), 0, false),
            ("noisy-pan", SIMD2(2.37, 1.23), 0.06, false),
            ("noisy-static", SIMD2(0, 0), 0.06, false),
            ("slow-pan", SIMD2(0.37, 0.23), 0.06, false),
            ("moving-occlusion", SIMD2(2.37, 1.23), 0.06, true),
        ]
        for (name, step, noise, moving) in scenarios {
            let scalers = [MetalUpscaler(cache: drawer.cache, support: .system), MetalUpscaler(cache: drawer.cache, support: .system)]
            var metrics = [Metrics(), Metrics()]
            var previousPictures: [[Float16]?] = [nil, nil]
            var previousHUD: [UInt8]?
            var maskMean: Float = 0, maskFrames = 0
            for frame in 0..<18 {
                let shift = moving ? CGPoint(x: CGFloat(frame) * 1.37, y: -CGFloat(frame) * 0.41) : .zero
                let occluder: Float = moving ? 20 + Float(frame) * 13.3 : -1
                let hudIn = try hud(width: w, height: h, scale: 1, shift: shift)
                let hudOut = try hud(width: ow, height: oh, scale: Self.scale, shift: shift)
                overlayIn.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: hudIn, bytesPerRow: w * 4)
                overlayOut.replace(region: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0, withBytes: hudOut, bytesPerRow: ow * 4)
                let offset = step * Float(frame) + SIMD2<Float>(4096, 4096)
                try render(input, overlay: overlayIn, uniforms: SceneUniforms(
                    offset: offset, pixel: 1, noise: noise, seed: UInt32(frame + 1), samples: 4, occluder: occluder))
                if frame >= 6 {
                    try render(truth, overlay: overlayOut, uniforms: SceneUniforms(
                        offset: offset, pixel: Float(w) / Float(ow), noise: 0, seed: 0, samples: 3, occluder: occluder))
                }
                var outputs: [[Float16]] = []
                for (i, mode) in [UpscalerMode.spatial, .temporal].enumerated() {
                    let command = try #require(drawer.queue.makeCommandBuffer())
                    let made = try #require(scalers[i].upscale(
                        source: input, mode: mode, presentation: (ow, oh), supersamplingLevel: 1,
                        frameTime: 1 + Double(frame) / 60, hdr: hdr, commandBuffer: command))
                    #expect(made.texture.width == ow && made.texture.height == oh)
                    #expect(scalers[i].present(
                        made, sharpness: 0.5, into: targets[i], viewport: nil, crop: MetalPipelineCache.wholePicture,
                        commandBuffer: command))
                    command.commit()
                    command.waitUntilCompleted()
                    #expect(command.status == .completed && command.error == nil)
                    if frame >= 6 { outputs.append(try read(targets[i], drawer: drawer, channels: 4, zero: Float16.zero)) }
                }
                guard frame >= 6 else { continue }
                let reference: [Float16] = try read(truth, drawer: drawer, channels: 4, zero: Float16.zero)
                let (areas, coverage) = try regions(shift: shift, previous: previousHUD, occluder: occluder)
                #expect(!areas.edge.isEmpty && !areas.halo.isEmpty && !areas.far.isEmpty)
                for i in 0..<2 {
                    #expect(outputs[i].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                    metrics[i].add(outputs[i], truth: reference, previous: moving ? nil : previousPictures[i], regions: areas, test: self)
                    previousPictures[i] = outputs[i]
                }
                if moving, frame > 6 { #expect(!areas.trail.isEmpty) }
                previousHUD = coverage
                let motion = try #require(scalers[1].motion)
                let mask: [Float16] = try read(motion.reactiveMask, drawer: drawer, channels: 1, zero: Float16.zero)
                maskMean += mask.reduce(Float.zero) { $0 + Float($1) } / Float(mask.count)
                maskFrames += 1
                if frame == 17 {
                    let prefix = "\(name)-\(hdr ? "half-float" : "sdr")"
                    try save(reference, name: prefix + "-truth")
                    try save(outputs[0], name: prefix + "-spatial")
                    try save(outputs[1], name: prefix + "-temporal")
                }
            }
            print("TEMPORAL-TEXT \(drawer.device.name) \(name) \(hdr ? "half-float/HDR flag" : "SDR") \(w)x\(h)->\(ow)x\(oh)")
            print(metrics[0].summary("spatial"))
            print(metrics[1].summary("temporal"))
            print("TEMPORAL-TEXT reactive-mask mean \(maskMean / Float(maskFrames))")
            // Halo and old glyph footprints are the reported defect. Edge reconstruction is printed separately: matching
            // Spatial's overall text cleanliness remains a parent GPU/image review gate, not a claim made by this test.
            #expect(metrics[1].halo <= metrics[0].halo + Float(metrics[0].frames) / 255)
            if moving { #expect(metrics[1].trail <= metrics[0].trail + Float(metrics[0].frames) / 255) }
            else { #expect(metrics[1].flicker <= metrics[0].flicker + Float(metrics[0].flickerFrames) / 255) }
            // A mask-everything workaround loses both of these temporal benefits on the compressed-video fixture.
            #expect(maskMean / Float(maskFrames) < 0.5)
            if noise > 0 { #expect(metrics[1].far < metrics[0].far * 0.95) }
        }
    }
}
