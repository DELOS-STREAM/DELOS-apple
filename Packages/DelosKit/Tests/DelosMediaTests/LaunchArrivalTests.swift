import CoreVideo
import Foundation
import Metal
import Testing
@testable import DelosMedia

private func values(_ pose: ArrivalPose) -> [Float] {
    [pose.scaleX, pose.scaleY, pose.skew, pose.warp, pose.blur, pose.chromatic]
}

/// The largest difference of the three channels.
private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return max(abs(d.x), abs(d.y), abs(d.z))
}

private func expectPose(_ opening: Double, _ expected: [Float], tolerance: Float) {
    let actual = values(LaunchArrival.pose(opening: opening))
    for (a, e) in zip(actual, expected) { #expect(abs(a - e) <= tolerance, "opening \(opening): \(actual) vs \(expected)") }
}

@Suite struct LaunchArrivalPoseTests {
    @Test func thePassRunsFromFiftyFivePercentUntilTheOpeningIsComplete() {
        #expect(!LaunchArrival.shouldActivate(0))
        #expect(!LaunchArrival.shouldActivate(0.549))
        #expect(LaunchArrival.shouldActivate(0.55))
        #expect(LaunchArrival.shouldActivate(0.6))
        #expect(LaunchArrival.shouldActivate(0.999))
        #expect(!LaunchArrival.shouldActivate(1))
        #expect(!LaunchArrival.shouldActivate(.nan))
        #expect(!LaunchArrival.shouldActivate(.infinity))
    }

    @Test func theNumbersAreAndroids() {
        #expect(LaunchArrival.activateAt == 0.55 && LaunchArrival.settleStart == 0.68)
        #expect(LaunchArrival.initialZoom == 1.18 && LaunchArrival.decay == 6)
        #expect(LaunchArrival.springDamping == 3.8 && LaunchArrival.springFrequency == 15)
        #expect(LaunchArrival.squish == 0.10 && LaunchArrival.springZoom == 0.025)
        #expect(LaunchArrival.warp == 70 && LaunchArrival.blur == 20 && LaunchArrival.chromatic == 9)
    }

    @Test func thePictureWaitsZoomedAndBlurredUntilTheLateAperture() {
        for opening in [0, 0.25, 0.5, 0.68] {
            expectPose(opening, [1.18, 1.18, 0, 0, 20, 0], tolerance: 1e-6)
        }
    }

    /// The vectors of Android's `LaunchArrivalTest.arrivalMatchesTheApprovedVisibleSpringPose`, same tolerance.
    @Test func theSpringMatchesAndroidsApprovedPose() {
        expectPose(0.72, [1.2326705, 1.0984540, 0.005695637, 41.533218, 16.532829, 2.9644082], tolerance: 0.0002)
        expectPose(0.76, [1.0706805, 1.1196314, -0.002121894, -15.473235, 11.156508, 4.714538], tolerance: 0.0002)
    }

    /// Android's formula evaluated in double precision at further points of the settling.
    @Test func theSettlingMatchesAndroidsFormula() {
        expectPose(0.75, [1.1037842, 1.1172900, -0.0005819, -4.2436725, 12.4480186, 4.3913574], tolerance: 1e-5)
        expectPose(0.8, [1.0424162, 1.0737775, -0.0014122, -10.2980331, 6.8509496, 5.3018244], tolerance: 1e-5)
        expectPose(0.9, [1.0077224, 1.0192876, -0.0005461, -3.9825537, 1.6567582, 3.2794117], tolerance: 1e-5)
        expectPose(0.99, [1.0001957, 1.0000572, 0.0000066, 0.0484646, 0.0121257, 0.0082108], tolerance: 1e-5)
    }

    @Test func theDisplacementReversesWhileZoomAndFocusSettle() {
        let first = LaunchArrival.pose(opening: 0.72), rebound = LaunchArrival.pose(opening: 0.76)
        let next = LaunchArrival.pose(opening: 0.84)
        #expect(first.warp > 0 && rebound.warp < 0 && next.warp > 0)
        #expect(first.scaleX > first.scaleY && rebound.scaleX < rebound.scaleY)
        #expect(abs(next.warp) < abs(first.warp))
        #expect(next.blur < rebound.blur)
    }

    @Test func theBlurOnlyFallsAndEverythingStaysBounded() {
        var previous = Float.infinity
        for step in 0..<1000 {
            let pose = LaunchArrival.pose(opening: Double(step) / 1000)
            #expect(values(pose).allSatisfy { $0.isFinite })
            #expect(pose.scaleX > 0.95 && pose.scaleX < 1.4 && pose.scaleY > 0.95 && pose.scaleY < 1.4)
            #expect(pose.blur >= 0 && pose.blur <= 20 && pose.blur <= previous + 0.0001)
            #expect(pose.chromatic >= 0 && pose.chromatic <= 9)
            previous = pose.blur
        }
    }

    @Test func invalidNegativeAndCompleteOpeningsAreTheExactIdentity() {
        for opening in [-1, -0.001, 1, 2, .nan, .infinity] {
            #expect(LaunchArrival.pose(opening: opening) == .identity)
        }
        let almost = LaunchArrival.pose(opening: 0.99999)
        #expect(abs(almost.scaleX - 1) < 0.00001 && abs(almost.scaleY - 1) < 0.00001)
        #expect(almost.blur < 0.0001 && almost.chromatic < 0.0001)
    }

    @Test func aRunCountsItsOpeningOnTheRenderersClock() {
        let run = ArrivalRun(start: 10, duration: 2.2)
        #expect(run.opening(at: 10) == 0)
        #expect(abs(run.opening(at: 11.1) - 0.5) < 1e-12)
        #expect(run.opening(at: 12.21) >= 1)
        #expect(run.opening(at: 9) < 0)
        #expect(ArrivalRun(start: 10, duration: 0).opening(at: 10) == 1)
    }

    @Test func theUniformsMatchTheShadersLayout() {
        #expect(MemoryLayout<ArrivalUniforms>.stride == 48)
        let uniforms = ArrivalUniforms(pose: LaunchArrival.pose(opening: 0.72), width: 1920, height: 1080)
        #expect(uniforms.sourceSize == SIMD2(1920, 1080) && uniforms.presentationSize == uniforms.sourceSize)
        #expect(uniforms.pose.x == LaunchArrival.pose(opening: 0.72).scaleX)
        #expect(uniforms.effects == SIMD2(LaunchArrival.pose(opening: 0.72).blur, LaunchArrival.pose(opening: 0.72).chromatic))
    }
}

/// The arrival pass on the GPU against a CPU reference of `arrivalFragment`.
@Suite struct ArrivalRenderingTests {
    private let size = 64

    private func target(_ drawer: MetalFrameDrawer, format: MTLPixelFormat) throws -> any MTLTexture {
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        return try #require(drawer.device.makeTexture(descriptor: description))
    }

    /// Draws `buffer` into a BGRA target, returns its pixels as RGB 0…1, row by row.
    private func draw(
        _ drawer: MetalFrameDrawer, _ buffer: CVPixelBuffer, conversion: ColorConversion, arrival: ArrivalPose?
    ) throws -> [SIMD3<Double>] {
        let texture = try target(drawer, format: .bgra8Unorm)
        let command = try #require(drawer.queue.makeCommandBuffer())
        #expect(drawer.draw(buffer, conversion: conversion, into: texture, commandBuffer: command, arrival: arrival))
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return (0..<(size * size)).map { i in
            SIMD3(Double(bytes[i * 4 + 2]), Double(bytes[i * 4 + 1]), Double(bytes[i * 4])) / 255
        }
    }

    /// `arrivalFragment` on the CPU for a pose without blur (mip level 0): bilinear, clamped, top-left coordinates.
    private func reference(_ source: [SIMD3<Double>], pose: ArrivalPose, x: Int, y: Int) -> SIMD3<Double> {
        let side = Double(size)
        func filtered(_ q: SIMD2<Double>) -> SIMD3<Double> {
            let c = SIMD2(min(max(q.x, 0.5 / side), 1 - 0.5 / side), min(max(q.y, 0.5 / side), 1 - 0.5 / side))
            let u = c.x * side - 0.5, v = c.y * side - 0.5
            let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down))
            let fx = u - Double(x0), fy = v - Double(y0)
            func texel(_ x: Int, _ y: Int) -> SIMD3<Double> { source[min(max(y, 0), size - 1) * size + min(max(x, 0), size - 1)] }
            let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
            let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
        var p = SIMD2((Double(x) + 0.5) / side, (Double(y) + 0.5) / side) - 0.5
        p.y -= p.x * Double(pose.skew)
        p /= SIMD2(Double(pose.scaleX), Double(pose.scaleY))
        p += SIMD2(sin(p.y * 8) * cos(p.x * 3), sin(p.x * 7) * cos(p.y * 3)) * Double(pose.warp) * 0.45 / side
        p += 0.5
        guard pose.chromatic >= 0.05 else { return filtered(p) }
        let split = SIMD2(1.0, 0.2) * Double(pose.chromatic) / side
        return SIMD3(filtered(p - split).x, filtered(p).y, filtered(p + split).z)
    }

    /// A picture with structure in both directions, limited-range BT.709 gray levels.
    private func pattern() throws -> (buffer: CVPixelBuffer, source: [SIMD3<Double>], conversion: ColorConversion) {
        let conversion = ColorConversion(matrix: .bt709, range: .limited)
        func luma(_ x: Int, _ y: Int) -> Int { 16 + Int(219 * (0.5 + 0.5 * sin(Double(x) * 0.3) * cos(Double(y) * 0.2))) }
        let buffer = try PixelBuffers.make(
            width: size, height: size, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            luma: luma, chroma: { _, _ in (128, 128) })
        // The arrival's RGB texture is 8-bit: the reference samples the same quantised texels
        let source = (0..<(size * size)).map { i in
            let rgb = conversion.rgb(y: luma(i % size, i / size), cb: 128, cr: 128)
            return (rgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)) * 255).rounded(.toNearestOrEven) / 255
        }
        return (buffer, source, conversion)
    }

    /// Spring poses (blur taken out, which the mip levels do): warp, skew, squash and the RGB split on the GPU agree with
    /// the CPU reference within 0.012 per channel (two 8-bit steps: the RGB texture and the target).
    @Test(arguments: [0.72, 0.76, 0.8, 0.9])
    func theSpringPoseAgreesWithTheCPUReference(opening: Double) throws {
        let drawer = try #require(MetalFrameDrawer())
        let (buffer, source, conversion) = try pattern()
        var pose = LaunchArrival.pose(opening: opening)
        pose.blur = 0
        let pixels = try draw(drawer, buffer, conversion: conversion, arrival: pose)
        var worst = 0.0
        for y in 0..<size {
            for x in 0..<size {
                worst = max(worst, distance(pixels[y * size + x], reference(source, pose: pose, x: x, y: y)))
            }
        }
        #expect(worst <= 0.012, "largest difference \(worst)")
        // And the pose really moved the picture
        let plain = try draw(drawer, buffer, conversion: conversion, arrival: nil)
        #expect(zip(plain, pixels).contains { distance($0, $1) > 0.05 })
    }

    /// The blur reads the mip levels: at the initial pose (20 source pixels) a one-pixel checkerboard is its average.
    @Test func theBlurReadsTheMipLevels() throws {
        let drawer = try #require(MetalFrameDrawer())
        let buffer = try PixelBuffers.make(
            width: size, height: size, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            luma: { x, y in (x + y) % 2 == 0 ? 0 : 255 }, chroma: { _, _ in (128, 128) })
        let conversion = ColorConversion(matrix: .bt709, range: .full)
        let plain = try draw(drawer, buffer, conversion: conversion, arrival: nil)
        #expect(plain[0].y < 0.02 && plain[1].y > 0.98)
        let blurred = try draw(drawer, buffer, conversion: conversion, arrival: LaunchArrival.pose(opening: 0.6))
        for (x, y) in [(10, 10), (31, 32), (50, 20), (5, 60)] {
            #expect(distance(blurred[y * size + x], SIMD3(repeating: 0.5)) < 0.03)
        }
    }

    /// The identity pose through the pass is the plain picture (8-bit target and texture).
    @Test func theIdentityPoseIsThePlainPicture() throws {
        let drawer = try #require(MetalFrameDrawer())
        let (buffer, _, conversion) = try pattern()
        let plain = try draw(drawer, buffer, conversion: conversion, arrival: nil)
        let posed = try draw(drawer, buffer, conversion: conversion, arrival: .identity)
        #expect(zip(plain, posed).allSatisfy { distance($0, $1) <= 1.5 / 255 })
    }

    /// HDR: a 10-bit BT.2020 PQ picture goes through a half-float texture into a half-float target and keeps its encoded
    /// values (within 0.002, the half floats' step).
    @Test func tenBitPQKeepsItsEncodedValuesThroughThePass() throws {
        let drawer = try #require(MetalFrameDrawer())
        let conversion = ColorConversion(matrix: .bt2020, range: .limited, transfer: .pq, bitDepth: 10)
        let buffer = try PixelBuffers.make(
            width: size, height: size, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            luma: { x, y in 64 + (x * 13 + y * 3) % 876 }, chroma: { _, _ in (300, 700) })
        func render(_ arrival: ArrivalPose?) throws -> [Float16] {
            let texture = try target(drawer, format: .rgba16Float)
            let command = try #require(drawer.queue.makeCommandBuffer())
            #expect(drawer.draw(buffer, conversion: conversion, into: texture, commandBuffer: command, arrival: arrival))
            command.commit()
            command.waitUntilCompleted()
            var pixels = [Float16](repeating: 0, count: size * size * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            return pixels
        }
        let plain = try render(nil), posed = try render(.identity)
        #expect(plain.contains { $0 > 0.6 })
        #expect(zip(plain, posed).allSatisfy { abs(Float($0) - Float($1)) <= 0.002 })
    }
}

/// The arrival in the pipeline: driven by the renderer's clock at each refresh's presentation time.
@Suite struct ArrivalPipelineTests {
    private struct Setup {
        let clock: VirtualClock
        let pipeline: MetalPipeline
        let plain: [UInt8]
    }

    /// One fixture frame decoded and shown at the refresh at 0.1 s; the picture stays on screen.
    private func setup() throws -> Setup {
        let clock = VirtualClock()
        let pipeline = try #require(MetalPipeline(pacing: .phaseLock, fps: 60, clock: clock.reading))
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        let sample = try stream.sample(0)
        #expect(pipeline.enqueue(sample))
        pipeline.waitForDecodes()
        clock.set(0.1)
        pipeline.tick(RefreshTick(presentation: 0.1, refresh: 1.0 / 60, drawable: nil))
        let plain = try #require(pipeline.offscreenPixels()).bytes
        return Setup(clock: clock, pipeline: pipeline, plain: plain)
    }

    private func tick(_ setup: Setup, at time: Double) -> [UInt8]? {
        setup.clock.set(time - 1.0 / 60)
        setup.pipeline.tick(RefreshTick(presentation: time, refresh: 1.0 / 60, drawable: nil))
        return setup.pipeline.offscreenPixels()?.bytes
    }

    @Test func theStillPictureIsPosedWhileTheArrivalRunsAndPlainExactlyWhenItEnds() throws {
        let s = try setup()
        defer { s.pipeline.invalidate() }
        s.clock.set(1)
        s.pipeline.startArrival(duration: 2.2)
        // Under the opaque tunnel the picture is not drawn again
        #expect(tick(s, at: 1 + 0.5 * 2.2) == s.plain)
        // From 55 % on, every refresh draws the last frame posed (zoomed, blurred, then settling)
        let waiting = try #require(tick(s, at: 1 + 0.6 * 2.2))
        #expect(waiting != s.plain)
        let settling = try #require(tick(s, at: 1 + 0.76 * 2.2))
        #expect(settling != s.plain && settling != waiting)
        // At the end the picture is drawn plainly once more: byte for byte the picture without the arrival
        #expect(tick(s, at: 1 + 2.2) == s.plain)
        #expect(tick(s, at: 1 + 2.3) == s.plain)
    }

    @Test func aCancelledArrivalShowsThePlainPictureAtTheNextRefresh() throws {
        let s = try setup()
        defer { s.pipeline.invalidate() }
        s.clock.set(1)
        s.pipeline.startArrival(duration: 2.2)
        #expect(tick(s, at: 1 + 0.7 * 2.2) != s.plain)
        s.pipeline.cancelArrival()
        #expect(tick(s, at: 1 + 0.71 * 2.2) == s.plain)
    }

    @Test func withoutAnArrivalNothingChanges() throws {
        let s = try setup()
        defer { s.pipeline.invalidate() }
        #expect(tick(s, at: 2) == s.plain)
    }
}
