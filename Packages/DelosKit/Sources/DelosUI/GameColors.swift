import Foundation

/// A game's three main colors (main, secondary, accent): their hues and how saturated they are (1 = as vivid as the
/// palette colors, down to 0.28 for nearly grey ones, up to 1.18 = fully saturated). `GameColors` of DELOS for Android.
public struct GameColors: Equatable, Sendable {
    public var hues: [Double]
    public var saturations: [Double]

    /// The three main colors of an image's pixels (`HeroBitmaps.dominantHues` of DELOS for Android); nil for a (nearly)
    /// grey image. [pixels] are 0xAARRGGBB with straight alpha. The pixels are grouped into buckets of 16 levels per
    /// channel, each one's average color judged in the perceptual CAM16 space (chroma, tone, hue): near-grey,
    /// near-black and near-white ones do not count. Each bucket's weight (its share × chroma², so a small vivid logo
    /// still counts) is summed per 15° of hue; the three strongest hue groups at least 30° apart win, each represented
    /// by its strongest bucket, as HSL hues with their own saturation. An image of one or two colors gets close shades
    /// of them (±14°).
    public static func dominant(_ pixels: [UInt32]) -> GameColors? {
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for c in pixels where c >> 24 >= 200 {
            let r = Int((c >> 16) & 255), g = Int((c >> 8) & 255), b = Int(c & 255)
            let bucket = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            let s = sums[bucket, default: (0, 0, 0, 0)]
            sums[bucket] = (s.r + r, s.g + g, s.b + b, s.n + 1)
        }
        guard !sums.isEmpty else { return nil }
        struct Cluster {
            let rgb: (r: Int, g: Int, b: Int)
            let weight: Double
            let bin: Int
        }
        // Buckets in a fixed order, so ties resolve the same way every time
        var clusters: [Cluster] = []
        for (_, s) in sums.sorted(by: { $0.key < $1.key }) {
            let rgb = (s.r / s.n, s.g / s.n, s.b / s.n)
            let hct = HCT(red: rgb.0, green: rgb.1, blue: rgb.2)
            guard hct.chroma >= minChroma, hct.tone >= 18, hct.tone <= 94 else { continue }
            clusters.append(Cluster(rgb: rgb, weight: Double(s.n) * hct.chroma * hct.chroma, bin: min(max(Int(hct.hue / 15), 0), 23)))
        }
        guard !clusters.isEmpty else { return nil }
        func binDistance(_ a: Int, _ b: Int) -> Int {
            let d = ((a - b) % 24 + 24) % 24
            return min(d, 24 - d)
        }
        var bins = [Double](repeating: 0, count: 24)
        for cluster in clusters { bins[cluster.bin] += cluster.weight }
        let groups = (0..<24).map { b in bins[(b + 23) % 24] * 0.5 + bins[b] + bins[(b + 1) % 24] * 0.5 }
        let top = groups.max() ?? 0
        var chosen: [Int] = []
        var usedBins: [Int] = []
        // Stable descending order, as Kotlin's sortedByDescending
        for b in (0..<24).sorted(by: { groups[$0] != groups[$1] ? groups[$0] > groups[$1] : $0 < $1 }) {
            if chosen.count == 3 || groups[b] < top * 0.08 { break }
            if usedBins.contains(where: { binDistance($0, b) < 2 }) { continue }
            var best: Int?
            for (i, cluster) in clusters.enumerated() where binDistance(cluster.bin, b) <= 1 && !chosen.contains(i) {
                if best == nil || cluster.weight > clusters[best!].weight { best = i }
            }
            guard let best else { continue }
            chosen.append(best)
            usedBins.append(b)
        }
        guard !chosen.isEmpty else { return nil }
        var hues: [Double] = []
        var saturations: [Double] = []
        for index in chosen {
            let (h, s, _) = Self.hsl(clusters[index].rgb)
            hues.append(h)
            // The backgrounds draw at about 85 % saturation: scaled to the color's own, never to grey, and up to full
            // saturation for really vivid colors (a deep red stays red instead of turning coral)
            saturations.append(min(max(s / 0.85, 0.28), 1.18))
        }
        while hues.count < 3 {
            hues.append((hues[0] + (hues.count == 1 ? 14 : 346)).truncatingRemainder(dividingBy: 360))
            saturations.append(saturations[0])
        }
        return GameColors(hues: hues, saturations: saturations)
    }

    /// The least chroma (CAM16) a color needs to count: below it, it reads as white, black or grey.
    static let minChroma = 16.0

    /// Hue (degrees), saturation and lightness (0...1) of an 8-bit color (`ColorUtils.colorToHSL`).
    static func hsl(_ rgb: (r: Int, g: Int, b: Int)) -> (Double, Double, Double) {
        let r = Double(rgb.r) / 255, g = Double(rgb.g) / 255, b = Double(rgb.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        var h: Double
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let s = delta / (1 - abs(2 * l - 1))
        return (h, s, l)
    }
}

/// Hue, chroma (CAM16 under the default viewing conditions) and tone (L* of CIELAB) of an sRGB color: the HCT space of
/// Google's material-color-utilities (`Hct.fromInt`, `Cam16.fromInt`, `ViewingConditions.DEFAULT`), which DELOS for
/// Android uses to judge colors.
struct HCT: Equatable {
    let hue: Double
    let chroma: Double
    let tone: Double

    init(red: Int, green: Int, blue: Int) {
        let r = Self.linearized(red), g = Self.linearized(green), b = Self.linearized(blue)
        let x = 0.41233895 * r + 0.35762064 * g + 0.18051042 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.01932141 * r + 0.11916382 * g + 0.95034478 * b
        let vc = ViewingConditions.standard
        let rC = 0.401288 * x + 0.650173 * y - 0.051461 * z
        let gC = -0.250268 * x + 1.204414 * y + 0.045854 * z
        let bC = -0.002079 * x + 0.048952 * y + 0.953127 * z
        func adapted(_ c: Double, _ d: Double) -> Double {
            let scaled = d * c
            let af = pow(vc.fl * abs(scaled) / 100, 0.42)
            return (scaled < 0 ? -1 : scaled > 0 ? 1 : 0) * 400 * af / (af + 27.13)
        }
        let rA = adapted(rC, vc.rgbD[0]), gA = adapted(gC, vc.rgbD[1]), bA = adapted(bC, vc.rgbD[2])
        let a = (11 * rA - 12 * gA + bA) / 11
        let bb = (rA + gA - 2 * bA) / 9
        let u = (20 * rA + 20 * gA + 21 * bA) / 20
        let p2 = (40 * rA + 20 * gA + bA) / 20
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 } else if hue >= 360 { hue -= 360 }
        let ac = p2 * vc.nbb
        let j = 100 * pow(ac / vc.aw, vc.c * vc.z)
        let huePrime = hue < 20.14 ? hue + 360 : hue
        let eHue = 0.25 * (cos(huePrime * .pi / 180 + 2) + 3.8)
        let p1 = 50000.0 / 13 * eHue * vc.nc * vc.ncb
        let t = p1 * (a * a + bb * bb).squareRoot() / (u + 0.305)
        let alpha = pow(t, 0.9) * pow(1.64 - pow(0.29, vc.n), 0.73)
        self.hue = hue
        chroma = alpha * (j / 100).squareRoot()
        tone = 116 * Self.labF(y / 100) - 16
    }

    /// An 8-bit sRGB channel as linear light, 0...100.
    static func linearized(_ channel: Int) -> Double {
        let n = Double(channel) / 255
        return (n <= 0.040449936 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)) * 100
    }

    static func labF(_ t: Double) -> Double {
        let e = 216.0 / 24389, kappa = 24389.0 / 27
        return t > e ? cbrt(t) : (kappa * t + 16) / 116
    }

    static func yFromLstar(_ lstar: Double) -> Double {
        let e = 216.0 / 24389, kappa = 24389.0 / 27
        let ft = (lstar + 16) / 116
        let ft3 = ft * ft * ft
        return 100 * (ft3 > e ? ft3 : (116 * ft - 16) / kappa)
    }

    /// `ViewingConditions.DEFAULT`: D65, an adapting luminance of 200/π · Y(L* 50) / 100, a background of L* 50, an
    /// average surround, no discounting of the illuminant.
    struct ViewingConditions {
        let n, aw, nbb, ncb, c, nc, fl, z: Double
        let rgbD: [Double]

        static let standard: ViewingConditions = {
            let white = [95.047, 100.0, 108.883]
            let adapting = 200 / Double.pi * HCT.yFromLstar(50) / 100
            let surround = 2.0
            let rW = white[0] * 0.401288 + white[1] * 0.650173 + white[2] * -0.051461
            let gW = white[0] * -0.250268 + white[1] * 1.204414 + white[2] * 0.045854
            let bW = white[0] * -0.002079 + white[1] * 0.048952 + white[2] * 0.953127
            let f = 0.8 + surround / 10
            let c = f >= 0.9 ? 0.59 + (0.69 - 0.59) * ((f - 0.9) * 10) : 0.525 + (0.59 - 0.525) * ((f - 0.8) * 10)
            let d = min(max(f * (1 - (1 / 3.6) * exp((-adapting - 42) / 92)), 0), 1)
            let rgbD = [d * (100 / rW) + 1 - d, d * (100 / gW) + 1 - d, d * (100 / bW) + 1 - d]
            let k = 1 / (5 * adapting + 1)
            let k4 = k * k * k * k
            let k4F = 1 - k4
            let fl = k4 * adapting + 0.1 * k4F * k4F * cbrt(5 * adapting)
            let n = HCT.yFromLstar(50) / white[1]
            let z = 1.48 + n.squareRoot()
            let nbb = 0.725 / pow(n, 0.2)
            let factors = [rgbD[0] * rW, rgbD[1] * gW, rgbD[2] * bW].map { pow(fl * $0 / 100, 0.42) }
            let rgbA = factors.map { 400 * $0 / ($0 + 27.13) }
            let aw = (2 * rgbA[0] + rgbA[1] + 0.05 * rgbA[2]) * nbb
            return ViewingConditions(n: n, aw: aw, nbb: nbb, ncb: nbb, c: c, nc: f, fl: fl, z: z, rgbD: rgbD)
        }()
    }
}
