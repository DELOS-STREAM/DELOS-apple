import Foundation
import Testing
@testable import DelosMedia

/// The fixtures made by tools/media/make_fixtures.sh: two frames of 64 x 64 test pattern per codec.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// An Annex B stream split into pictures as the host sends them: each picture's slice with the units before it
    /// (the parameter sets travel with the first). The fixtures have one slice per picture.
    static func pictures(_ name: String, codec: VideoCodec) throws -> [Data] {
        var pictures: [Data] = []
        var current = Data()
        var sawSlice = false
        for unit in AnnexB.units(try data(name)) {
            let type = AnnexB.type(of: unit, codec: codec) ?? 0
            let slice = codec == .h264 ? (type == 1 || type == 5) : type < 32
            if slice, sawSlice {
                pictures.append(current)
                current = Data()
            }
            sawSlice = sawSlice || slice
            current.append(contentsOf: [0, 0, 0, 1])
            current.append(unit)
        }
        pictures.append(current)
        return pictures
    }
}
