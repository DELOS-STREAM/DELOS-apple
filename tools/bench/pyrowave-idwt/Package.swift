// swift-tools-version: 6.2
// Micro-benchmark for issue #13 (docs/PYROWAVE_APPLE.md): the inverse wavelet transform of PyroWave as a Metal compute
// kernel, timed on the GPU of this Mac. A command-line tool and its tests; nothing here is part of the app.
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "PyroWaveIDWT",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "IDWTKit", swiftSettings: strict),
        .executableTarget(name: "idwt-bench", dependencies: ["IDWTKit"], swiftSettings: strict),
        .testTarget(name: "IDWTKitTests", dependencies: ["IDWTKit"], swiftSettings: strict),
    ]
)
