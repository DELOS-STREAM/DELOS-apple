// swift-tools-version: 6.2
// The code of DELOS for Apple below the app target. One module per layer; the dependency direction is
// App → DelosUI → DelosData → DelosHost → DelosCore, and DelosMedia and DelosInput depend only on DelosCore
// (docs/ARCHITECTURE.md). Nothing below DelosUI imports SwiftUI.
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "DelosKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DelosUI", targets: ["DelosUI"]),
        .library(name: "DelosData", targets: ["DelosData"]),
        .library(name: "DelosHost", targets: ["DelosHost"]),
        .library(name: "DelosCore", targets: ["DelosCore"]),
        .library(name: "DelosMedia", targets: ["DelosMedia"]),
        .library(name: "DelosInput", targets: ["DelosInput"]),
    ],
    targets: [
        .target(name: "DelosCore", swiftSettings: strict),
        .target(name: "DelosHost", dependencies: ["DelosCore"], swiftSettings: strict),
        .target(name: "DelosMedia", dependencies: ["DelosCore"], swiftSettings: strict),
        .target(name: "DelosInput", dependencies: ["DelosCore"], swiftSettings: strict),
        .target(name: "DelosData", dependencies: ["DelosHost"], swiftSettings: strict),
        .target(
            name: "DelosUI",
            dependencies: ["DelosData", "DelosInput"],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .testTarget(name: "DelosDataTests", dependencies: ["DelosData"], swiftSettings: strict),
        .testTarget(name: "DelosInputTests", dependencies: ["DelosInput"], swiftSettings: strict),
        .testTarget(name: "DelosUITests", dependencies: ["DelosUI"], swiftSettings: strict),
    ]
)
