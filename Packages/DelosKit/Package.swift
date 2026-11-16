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
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package", exact: "3.6.3000"),
    ],
    targets: [
        .target(name: "DelosCore", dependencies: ["CDelosCommon"], swiftSettings: strict),
        // The C streaming core. `core` is a symlink to the submodule ThirdParty/delos-common-c, because SwiftPM only
        // builds sources inside the package directory; the file list and defines follow the core's CMakeLists.txt.
        .target(
            name: "CDelosCommon",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")],
            sources: [
                "DelosLog.c",
                "core/src",
                "core/enet/callbacks.c",
                "core/enet/compress.c",
                "core/enet/host.c",
                "core/enet/list.c",
                "core/enet/packet.c",
                "core/enet/peer.c",
                "core/enet/protocol.c",
                "core/enet/unix.c",
                "core/nanors/rs.c",
                "core/nanors/deps/obl/oblas_common.c",
                "core/nanors/deps/obl/oblas_lite.c",
            ],
            cSettings: [
                .headerSearchPath("core/src"),
                .headerSearchPath("core/enet/include"),
                .headerSearchPath("core/nanors"),
                .headerSearchPath("core/nanors/deps"),
                .headerSearchPath("core/nanors/deps/obl"),
                .define("HAS_SOCKLEN_T"),
                .define("__APPLE_USE_RFC_3542"),
                .define("LC_DEBUG", .when(configuration: .debug)),
                .define("NDEBUG", .when(configuration: .release)),
                // The core is built warning-free by its own CMake flags; Apple's toolchain adds this check.
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
            ]
        ),
        // libopus, floating-point build. `opus` is a symlink to the submodule ThirdParty/opus; the file list follows
        // its opus_sources.mk, celt_sources.mk and silk_sources.mk, config/config.h replaces the generated config.
        .target(
            name: "COpus",
            exclude: [
                "opus/src/opus_demo.c",
                "opus/src/opus_compare.c",
                "opus/src/qext_compare.c",
                "opus/src/repacketizer_demo.c",
                "opus/celt/arm",
                "opus/celt/x86",
                "opus/celt/mips",
                "opus/celt/tests",
                "opus/celt/dump_modes",
                "opus/celt/opus_custom_demo.c",
                "opus/celt/mini_kfft.c",
                "opus/silk/arm",
                "opus/silk/x86",
                "opus/silk/mips",
                "opus/silk/xtensa",
                "opus/silk/tests",
                "opus/silk/fixed",
                "opus/silk/float/x86",
                "opus/src/meson.build",
                "opus/celt/meson.build",
                "opus/silk/meson.build",
            ],
            sources: ["opus/src", "opus/celt", "opus/silk", "neon"],
            cSettings: [
                .headerSearchPath("config"),
                .headerSearchPath("opus"),
                .headerSearchPath("opus/include"),
                .headerSearchPath("opus/celt"),
                .headerSearchPath("opus/silk"),
                .headerSearchPath("opus/silk/float"),
                .headerSearchPath("opus/silk/fixed"),
                .define("OPUS_BUILD"),
                .define("HAVE_CONFIG_H"),
                // Third-party code: Apple's 64-to-32 check, and the "compiling without optimization" note in debug.
                .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-#pragma-messages"]),
            ]
        ),
        .target(name: "DelosHost", dependencies: ["DelosCore"], swiftSettings: strict),
        .target(name: "DelosMedia", dependencies: ["DelosCore", "COpus"], swiftSettings: strict),
        .target(name: "DelosInput", dependencies: ["DelosCore"], swiftSettings: strict),
        .target(name: "DelosData", dependencies: ["DelosHost"], swiftSettings: strict),
        .target(
            name: "DelosUI",
            dependencies: ["DelosData", "DelosInput"],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .testTarget(name: "DelosCoreTests", dependencies: ["DelosCore", "CDelosCommon"], swiftSettings: strict),
        .testTarget(name: "DelosMediaTests", dependencies: ["DelosMedia", "COpus"], swiftSettings: strict),
        .testTarget(name: "DelosInputTests", dependencies: ["DelosInput"], swiftSettings: strict),
        .testTarget(name: "DelosUITests", dependencies: ["DelosUI"], swiftSettings: strict),
    ]
)
