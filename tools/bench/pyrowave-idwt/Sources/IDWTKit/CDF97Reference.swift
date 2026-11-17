/// A slow double-precision CPU reference of PyroWave's wavelet transform: CDF 9/7 lifting (ITU-T T.800 F.4.8.2) with
/// whole-sample symmetric extension, written from the specification of the bit stream, not from the shader. The tests
/// compare the Metal kernel with it.
public enum CDF97 {
    static let alpha = -1.586134342059924
    static let beta = -0.052980118572961
    static let gamma = 0.882911075530934
    static let delta = 0.443506852043971
    static let k = 1.230174104914001
    /// Lifting reads two samples either side, four steps deep.
    static let margin = 4

    /// Whole-sample symmetric extension. Keeps the parity of the index when `count` is even.
    static func mirror(_ index: Int, count: Int) -> Int {
        var j = index
        if j < 0 { j = -j }
        if j >= count { j = 2 * (count - 1) - j }
        return j
    }

    /// Analysis of one signal of even length. The result is interleaved: low-pass at even, high-pass at odd positions.
    public static func forward(_ x: [Double]) -> [Double] {
        let n = x.count
        precondition(n >= 2 && n % 2 == 0)
        var e = (0..<(n + 2 * margin)).map { x[mirror($0 - margin, count: n)] }
        for j in stride(from: 1, to: e.count - 1, by: 2) { e[j] += alpha * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 2, to: e.count - 2, by: 2) { e[j] += beta * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 3, to: e.count - 3, by: 2) { e[j] += gamma * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 4, to: e.count - 4, by: 2) { e[j] += delta * (e[j - 1] + e[j + 1]) }
        return (0..<n).map { $0 % 2 == 0 ? e[$0 + margin] / k : e[$0 + margin] * k }
    }

    /// Synthesis: the exact inverse of `forward`, in the order of the shader (scale, then delta, gamma, beta, alpha).
    public static func inverse(_ y: [Double]) -> [Double] {
        let n = y.count
        precondition(n >= 2 && n % 2 == 0)
        var e = (0..<(n + 2 * margin)).map { y[mirror($0 - margin, count: n)] }
        for j in 0..<e.count { e[j] = j % 2 == 0 ? e[j] * k : e[j] / k }
        for j in stride(from: 2, to: e.count - 1, by: 2) { e[j] -= delta * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 3, to: e.count - 2, by: 2) { e[j] -= gamma * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 4, to: e.count - 3, by: 2) { e[j] -= beta * (e[j - 1] + e[j + 1]) }
        for j in stride(from: 5, to: e.count - 4, by: 2) { e[j] -= alpha * (e[j - 1] + e[j + 1]) }
        return (0..<n).map { e[$0 + margin] }
    }
}

/// A row-major image of doubles.
public struct Plane: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var values: [Double]

    public init(width: Int, height: Int, values: [Double]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, _ value: (Int, Int) -> Double) {
        var values = [Double](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { values[y * width + x] = value(x, y) } }
        self.init(width: width, height: height, values: values)
    }

    public subscript(x: Int, y: Int) -> Double {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    /// The top-left `width` x `height` part.
    public func cropped(width w: Int, height h: Int) -> Plane {
        Plane(width: w, height: h) { self[$0, $1] }
    }

    /// Grows the plane by repeating its last column and row (the encoder's clamp-to-edge padding).
    public func padded(width w: Int, height h: Int) -> Plane {
        Plane(width: w, height: h) { self[min($0, width - 1), min($1, height - 1)] }
    }
}

/// The four bands one decomposition level produces, each half the size of its input.
public struct Bands: Sendable, Equatable {
    public var ll: Plane
    public var hl: Plane  // horizontal high-pass, vertical low-pass
    public var lh: Plane  // horizontal low-pass, vertical high-pass
    public var hh: Plane

    /// The bands in layer order of the GPU image array: LL, HL, LH, HH.
    public var layers: [Plane] { [ll, hl, lh, hh] }
}

public enum Wavelet2D {
    public static func forward(_ plane: Plane) -> Bands {
        precondition(plane.width % 2 == 0 && plane.height % 2 == 0)
        var rows = plane
        for y in 0..<plane.height {
            let line = CDF97.forward((0..<plane.width).map { plane[$0, y] })
            for x in 0..<plane.width { rows[x, y] = line[x] }
        }
        var both = rows
        for x in 0..<plane.width {
            let line = CDF97.forward((0..<plane.height).map { rows[x, $0] })
            for y in 0..<plane.height { both[x, y] = line[y] }
        }
        let w = plane.width / 2
        let h = plane.height / 2
        return Bands(
            ll: Plane(width: w, height: h) { both[2 * $0, 2 * $1] },
            hl: Plane(width: w, height: h) { both[2 * $0 + 1, 2 * $1] },
            lh: Plane(width: w, height: h) { both[2 * $0, 2 * $1 + 1] },
            hh: Plane(width: w, height: h) { both[2 * $0 + 1, 2 * $1 + 1] })
    }

    public static func inverse(_ bands: Bands) -> Plane {
        let w = 2 * bands.ll.width
        let h = 2 * bands.ll.height
        var interleaved = Plane(width: w, height: h) { x, y in
            let source = (x % 2 == 0 ? (y % 2 == 0 ? bands.ll : bands.lh) : (y % 2 == 0 ? bands.hl : bands.hh))
            return source[x / 2, y / 2]
        }
        for x in 0..<w {
            let line = CDF97.inverse((0..<h).map { interleaved[x, $0] })
            for y in 0..<h { interleaved[x, y] = line[y] }
        }
        for y in 0..<h {
            let line = CDF97.inverse((0..<w).map { interleaved[$0, y] })
            for x in 0..<w { interleaved[x, y] = line[x] }
        }
        return interleaved
    }

    /// `levelCount` decomposition levels of `plane`, finest first. `result[i + 1]` decomposes `result[i].ll`.
    public static func forwardPyramid(_ plane: Plane, levelCount: Int) -> [Bands] {
        var result: [Bands] = []
        var current = plane
        for _ in 0..<levelCount {
            let bands = forward(current)
            result.append(bands)
            current = bands.ll
        }
        return result
    }

    /// Reverses `forwardPyramid`, using only the coarsest level's LL band; the finer LL bands are rebuilt.
    public static func inversePyramid(_ pyramid: [Bands]) -> Plane {
        var current = inverse(pyramid[pyramid.count - 1])
        for level in stride(from: pyramid.count - 2, through: 0, by: -1) {
            var bands = pyramid[level]
            bands.ll = current
            current = inverse(bands)
        }
        return current
    }
}
