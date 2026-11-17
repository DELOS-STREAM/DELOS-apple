/// How PyroWave lays out a frame (docs: pyrowave `bitstream.md`, "Wavelet transform" and "Image dimension alignment").
/// Pure arithmetic, no GPU: the tests pin it down.

public enum Chroma: String, Sendable, CaseIterable {
    case yuv420 = "420"
    case yuv444 = "444"
}

/// PyroWave's `PRECISION` 0 (`half` arithmetic) and 1 (`float` arithmetic; the Android default). Both store the
/// finest levels as 16-bit floats; precision 1 keeps the three coarsest levels, which are tiny, in 32 bits.
public enum MathPrecision: String, Sendable, CaseIterable {
    case half
    case float
}

public struct PyramidLayout: Sendable, Equatable {
    public static let levels = 5
    public static let components = 3
    public static let alignment = 1 << levels
    public static let minimumSize = 4 << levels
    /// Levels (counted from the finest, 0) that precision 1 stores as 16-bit floats.
    public static let halfStoredLevels = 2

    public let width: Int
    public let height: Int
    public let chroma: Chroma

    public init(width: Int, height: Int, chroma: Chroma) {
        precondition(width >= 1 && height >= 1 && width <= 1 << 14 && height <= 1 << 14, "size out of range")
        precondition(chroma == .yuv444 || (width % 2 == 0 && height % 2 == 0), "4:2:0 needs an even size")
        self.width = width
        self.height = height
        self.chroma = chroma
    }

    public var alignedWidth: Int { max(Self.align(width), Self.minimumSize) }
    public var alignedHeight: Int { max(Self.align(height), Self.minimumSize) }

    static func align(_ value: Int) -> Int { (value + alignment - 1) & ~(alignment - 1) }

    /// The size of every band of `level` (0 is the finest). The same for all components.
    public func bandSize(level: Int) -> (width: Int, height: Int) {
        (alignedWidth >> (level + 1), alignedHeight >> (level + 1))
    }

    /// The levels a component has bands for: 4:2:0 chroma has no finest level.
    public func levels(of component: Int) -> ClosedRange<Int> {
        component != 0 && chroma == .yuv420 ? 1...(Self.levels - 1) : 0...(Self.levels - 1)
    }

    /// The size of the decoded plane of a component.
    public func planeSize(of component: Int) -> (width: Int, height: Int) {
        component != 0 && chroma == .yuv420 ? (width / 2, height / 2) : (width, height)
    }

    /// One dispatch of the inverse transform: the four bands of `level` of `component` become the LL band of the
    /// next finer level, or the decoded plane when `writesPlane`.
    public struct Pass: Equatable, Sendable {
        public let component: Int
        public let level: Int
        public let writesPlane: Bool
        /// Threadgroups along the band image's rows and along its columns (a threadgroup covers 16 x 16 band samples).
        public let groupsAlongRows: Int
        public let groupsAlongColumns: Int
    }

    /// The dispatches of one frame in execution order: coarsest level first, the components of a level together.
    public func passes() -> [Pass] {
        var result: [Pass] = []
        for level in stride(from: Self.levels - 1, through: 0, by: -1) {
            let size = bandSize(level: level)
            for component in 0..<Self.components where levels(of: component).contains(level) {
                let finalLevel = level == 0 || (level == 1 && component != 0 && chroma == .yuv420)
                result.append(Pass(
                    component: component, level: level, writesPlane: finalLevel,
                    groupsAlongRows: (size.height + 15) / 16, groupsAlongColumns: (size.width + 15) / 16))
            }
        }
        return result
    }

    /// Samples of band data one frame's inverse transform reads (every band of every level).
    public var bandSampleCount: Int {
        var total = 0
        for component in 0..<Self.components {
            for level in levels(of: component) {
                let size = bandSize(level: level)
                total += 4 * size.width * size.height
            }
        }
        return total
    }
}
