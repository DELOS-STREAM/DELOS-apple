import Foundation
import Metal

public enum IDWTError: Error, CustomStringConvertible {
    case noDevice
    case compile(String)
    case missing(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .compile(let message): "shader compile failed: \(message)"
        case .missing(let what): "could not create \(what)"
        }
    }
}

/// The GPU side: band images of every level, decoded planes, and the dispatches of PyroWave's inverse transform.
/// Not thread safe; one owner.
public final class IDWTDecoder {
    public let device: any MTLDevice
    public let layout: PyramidLayout
    public let precision: MathPrecision
    public let planeFormat: MTLPixelFormat
    /// `bands[component][level]`: four layers LL, HL, LH, HH. Layer 0 of a level below the coarsest is written by the
    /// transform. `nil` where a component has no such level.
    public private(set) var bands: [[(any MTLTexture)?]]
    public private(set) var planes: [any MTLTexture]

    private struct EncodedPass {
        let pipeline: any MTLComputePipelineState
        let input: any MTLTexture
        let output: any MTLTexture
        var params: IDWTParams
        let level: Int
        let groups: MTLSize
    }

    private struct FillPass {
        let pipeline: any MTLComputePipelineState
        let texture: any MTLTexture
        let firstLayer: UInt32
        let layers: Int
    }

    private struct IDWTParams {
        var resolution: SIMD2<Int32>
        var invResolution: SIMD2<Float>
    }

    private struct FillParams {
        var firstLayer: UInt32
        var seed: UInt32
        var amplitude: Float
    }

    private var encodedPasses: [EncodedPass] = []
    private var fillPasses: [FillPass] = []

    public static func pixelFormat(level: Int, precision: MathPrecision) -> MTLPixelFormat {
        precision == .half || level < PyramidLayout.halfStoredLevels ? .r16Float : .r32Float
    }

    public init(device: any MTLDevice, layout: PyramidLayout, precision: MathPrecision, tenBitPlanes: Bool = false) throws {
        self.device = device
        self.layout = layout
        self.precision = precision
        self.planeFormat = tenBitPlanes ? .r16Unorm : .r8Unorm

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: IDWTShaders.source, options: nil)
        } catch {
            throw IDWTError.compile("\(error)")
        }

        func texture(_ descriptor: MTLTextureDescriptor, _ what: String) throws -> any MTLTexture {
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw IDWTError.missing(what) }
            return texture
        }

        bands = Array(repeating: Array(repeating: nil, count: PyramidLayout.levels), count: PyramidLayout.components)
        for component in 0..<PyramidLayout.components {
            for level in layout.levels(of: component) {
                let size = layout.bandSize(level: level)
                let descriptor = MTLTextureDescriptor()
                descriptor.textureType = .type2DArray
                descriptor.pixelFormat = Self.pixelFormat(level: level, precision: precision)
                descriptor.width = size.width
                descriptor.height = size.height
                descriptor.arrayLength = 4
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                bands[component][level] = try texture(descriptor, "band image \(component)/\(level)")
            }
        }

        planes = []
        for component in 0..<PyramidLayout.components {
            let size = layout.planeSize(of: component)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: planeFormat, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            planes.append(try texture(descriptor, "plane \(component)"))
        }

        var pipelines: [String: any MTLComputePipelineState] = [:]
        func pipeline(_ name: String, dcShift: Bool? = nil) throws -> any MTLComputePipelineState {
            let key = "\(name)/\(dcShift.map(String.init) ?? "-")"
            if let cached = pipelines[key] { return cached }
            let function: any MTLFunction
            if var shift = dcShift {
                let constants = MTLFunctionConstantValues()
                constants.setConstantValue(&shift, type: .bool, index: 0)
                function = try library.makeFunction(name: name, constantValues: constants)
            } else {
                guard let plain = library.makeFunction(name: name) else { throw IDWTError.missing("function \(name)") }
                function = plain
            }
            let state = try device.makeComputePipelineState(function: function)
            pipelines[key] = state
            return state
        }

        let math = precision == .half ? "h" : "f"
        for pass in layout.passes() {
            guard let input = bands[pass.component][pass.level] else { throw IDWTError.missing("input of a pass") }
            let output: any MTLTexture
            let outputFormat: MTLPixelFormat
            if pass.writesPlane {
                output = planes[pass.component]
                outputFormat = .r16Float  // the kernel writes half; the plane's format is unorm
            } else {
                guard let array = bands[pass.component][pass.level - 1],
                    let view = array.makeTextureView(
                        pixelFormat: array.pixelFormat, textureType: .type2D, levels: 0..<1, slices: 0..<1)
                else { throw IDWTError.missing("view of the next level") }
                output = view
                outputFormat = array.pixelFormat
            }
            let inputKind = input.pixelFormat == .r32Float ? "f" : "h"
            let outputKind = outputFormat == .r32Float ? "f" : "h"
            let state = try pipeline("idwt_\(inputKind)_\(outputKind)_\(math)", dcShift: pass.writesPlane)
            let size = layout.bandSize(level: pass.level)
            // PyroWave transposes on load: the resolution is (height, width).
            let params = IDWTParams(
                resolution: SIMD2(Int32(size.height), Int32(size.width)),
                invResolution: SIMD2(1 / Float(size.height), 1 / Float(size.width)))
            encodedPasses.append(EncodedPass(
                pipeline: state, input: input, output: output, params: params, level: pass.level,
                groups: MTLSize(width: pass.groupsAlongRows, height: pass.groupsAlongColumns, depth: 1)))
        }

        // What the dequantisation pass would write: every coded band once.
        for component in 0..<PyramidLayout.components {
            for level in layout.levels(of: component) {
                guard let array = bands[component][level] else { continue }
                let coarsest = level == PyramidLayout.levels - 1
                fillPasses.append(FillPass(
                    pipeline: try pipeline(array.pixelFormat == .r32Float ? "fill_f" : "fill_h"),
                    texture: array, firstLayer: coarsest ? 0 : 1, layers: coarsest ? 4 : 3))
            }
        }
    }

    /// Threadgroup size of the inverse transform kernel.
    static let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)

    /// Writes pseudo-random coefficients into every coded band (see `IDWTShaders`).
    public func encodeFill(on encoder: any MTLComputeCommandEncoder, seed: UInt32, amplitude: Float = 0.05) {
        for pass in fillPasses {
            var params = FillParams(firstLayer: pass.firstLayer, seed: seed, amplitude: amplitude)
            encoder.setComputePipelineState(pass.pipeline)
            encoder.setTexture(pass.texture, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<FillParams>.size, index: 0)
            let groups = MTLSize(width: (pass.texture.width + 15) / 16, height: (pass.texture.height + 15) / 16, depth: pass.layers)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
    }

    /// One frame of the inverse transform: coarsest level to the planes. With `barrierBetweenLevels` the encoder is
    /// meant to be concurrent and a texture barrier separates the levels, the pattern of PyroWave's Vulkan path
    /// (the three components of a level are independent); a serial encoder needs none.
    public func encodeIDWT(on encoder: any MTLComputeCommandEncoder, barrierBetweenLevels: Bool) {
        var currentLevel = PyramidLayout.levels - 1
        for var pass in encodedPasses {
            if pass.level != currentLevel {
                if barrierBetweenLevels { encoder.memoryBarrier(scope: .textures) }
                currentLevel = pass.level
            }
            encoder.setComputePipelineState(pass.pipeline)
            encoder.setTexture(pass.input, index: 0)
            encoder.setTexture(pass.output, index: 1)
            encoder.setBytes(&pass.params, length: MemoryLayout<IDWTParams>.size, index: 0)
            encoder.dispatchThreadgroups(pass.groups, threadsPerThreadgroup: Self.threadsPerGroup)
        }
    }

    // MARK: Test support: upload and read back

    /// Uploads one band image layer, rounding to the texture's format (16-bit or 32-bit float). Returns the values as
    /// the GPU sees them so a reference can start from the same coefficients.
    @discardableResult
    public func upload(_ plane: Plane, component: Int, level: Int, layer: Int, queue: any MTLCommandQueue) throws -> Plane {
        guard let texture = bands[component][level] else { throw IDWTError.missing("band image \(component)/\(level)") }
        precondition(plane.width == texture.width && plane.height == texture.height)
        let isHalf = texture.pixelFormat == .r16Float
        let stride = isHalf ? 2 : 4
        let count = plane.values.count
        guard let staging = device.makeBuffer(length: count * stride, options: .storageModeShared) else {
            throw IDWTError.missing("staging buffer")
        }
        var rounded = plane
        if isHalf {
            let pointer = staging.contents().bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count {
                pointer[i] = Float16(plane.values[i])
                rounded.values[i] = Double(pointer[i])
            }
        } else {
            let pointer = staging.contents().bindMemory(to: Float.self, capacity: count)
            for i in 0..<count {
                pointer[i] = Float(plane.values[i])
                rounded.values[i] = Double(pointer[i])
            }
        }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw IDWTError.missing("blit encoder")
        }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: plane.width * stride,
            sourceBytesPerImage: count * stride, sourceSize: MTLSize(width: plane.width, height: plane.height, depth: 1),
            to: texture, destinationSlice: layer, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return rounded
    }

    /// The decoded plane as values in [0, 1].
    public func readPlane(_ component: Int, queue: any MTLCommandQueue) throws -> Plane {
        let texture = planes[component]
        let bytesPerPixel = planeFormat == .r16Unorm ? 2 : 1
        let count = texture.width * texture.height
        guard let buffer = device.makeBuffer(length: count * bytesPerPixel, options: .storageModeShared),
            let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { throw IDWTError.missing("readback buffer") }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * bytesPerPixel,
            destinationBytesPerImage: count * bytesPerPixel)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var values = [Double](repeating: 0, count: count)
        if bytesPerPixel == 2 {
            let pointer = buffer.contents().bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count { values[i] = Double(pointer[i]) / 65535 }
        } else {
            let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: count)
            for i in 0..<count { values[i] = Double(pointer[i]) / 255 }
        }
        return Plane(width: texture.width, height: texture.height, values: values)
    }

    /// Runs one frame of the inverse transform and waits for it.
    public func runOnce(queue: any MTLCommandQueue) throws {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw IDWTError.missing("compute encoder")
        }
        encodeIDWT(on: encoder, barrierBetweenLevels: false)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }
}
