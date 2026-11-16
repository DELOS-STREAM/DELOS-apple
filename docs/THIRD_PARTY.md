# Third-party code and binaries

Every piece of code or binary that DELOS for Apple did not write is listed here with its origin, version, license and,
for binaries, checksum (rule of [ENGINEERING_RULES.md](ENGINEERING_RULES.md)).

## Source code

| Component | Path | Origin | Version | License |
|---|---|---|---|---|
| Moonlight for iOS/tvOS (reference app, to be removed) | `Limelight/`, `Moonlight TV/`, `Moonlight.xcodeproj`, storyboards | [moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) | fork point `02dc978` | GPL-3.0 |
| moonlight-common-c (submodule, to be replaced by the DELOS core) | `moonlight-common/moonlight-common-c` | [moonlight-stream/moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `f900dd47` | GPL-3.0 |
| X1Kit (submodule, to be removed) | `X1Kit` | [cgutman/X1Kit](https://github.com/cgutman/X1Kit) | `6e842ae9` | MIT |

## Swift packages

| Package | Origin | Version | Pin |
|---|---|---|---|
| OpenSSL-Package (binary OpenSSL for the C core) | [krzyzanowskim/OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) | 3.6.3000 | revision `a3809db22a45e3ff658377a24da252982a306b9b` |

## Prebuilt binaries (inherited, to be removed)

Moonlight ships these static libraries; they were built by the Moonlight project with
[cgutman/moonlight-mobile-deps](https://github.com/cgutman/moonlight-mobile-deps) (`libs/Build.txt`). The exact source
versions and build flags are not recorded. The new app does not use them: FFmpeg and SDL2 are replaced by Swift code
and system frameworks, and Opus is built from source. They are deleted together with the Moonlight reference app.

| Library | Size | Files (SHA-256) |
|---|---|---|
| FFmpeg (`libavcodec`, `libavformat`, `libavutil`) | 44 MB | see below |
| SDL2 | 14 MB | see below |
| Opus | 13 MB | see below |

```
c6d210e33c59f0cffadcc3825504a6a2bc4855934fec6aee3591f2be3398065a  libs/FFmpeg/lib/iOS/libavutil.a
6e9c99a06a9d4bd64634f487a3265eca15d956d59804f28ec64e3899312d86e4  libs/FFmpeg/lib/iOS/libavcodec.a
7a881ad35ae365806a446f194267ac761f3a6e52c65e00edc9f840b6a6388051  libs/FFmpeg/lib/iOS/libavformat.a
8dfc839e59d302abc617d3c80b45ccf4d4e52103b325bf4fd36fab0d9391a0cf  libs/FFmpeg/lib/tvOS/libavutil.a
e2d076305df91637c65137ae58278f4e19c6e6764f8f6611c7e40f538c0e954a  libs/FFmpeg/lib/tvOS/libavcodec.a
1f1a6230d78194b4103b18b85397182adb1a3ce25e337b5937038bbcea476484  libs/FFmpeg/lib/tvOS/libavformat.a
7226f796025e7b00a43a8286490a5ed4d08162ba26585d38774e5222a8b41b42  libs/FFmpeg/lib/tvOS-Sim/libavutil.a
2cff2bc2c6bb3538d0e480c1bae1ea81eaee8421becd18c9e031d6b863ae5f14  libs/FFmpeg/lib/tvOS-Sim/libavcodec.a
9d0dbb6080cd4dcdcb68a9dbf6fdbbdace3ffe6d6a3e8c729db68832005ca9ef  libs/FFmpeg/lib/tvOS-Sim/libavformat.a
3caab4eea739d5a2f8e0de6a9144e27feb7b840606e9cdead7836feece4e12d6  libs/FFmpeg/lib/iOS-Sim/libavutil.a
318fd5ca480e69d95d98dd26d53f38c7a020de0958bed505a801a12bdd9550cc  libs/FFmpeg/lib/iOS-Sim/libavcodec.a
0aa7ff175f943d7f1722bf51c5ca72f8d69208338e950f15c9a0321b495bd84c  libs/FFmpeg/lib/iOS-Sim/libavformat.a
8794ed9b30bfa9cf7992ca971a7ca86365cf4a575f44e83516d4969619b1c345  libs/SDL2/lib/iOS/libSDL2.a
03a7ad43107de430d3cee27b450eefa45ea68f7854989c6505942bc119359395  libs/SDL2/lib/tvOS/libSDL2.a
dffae42d16159c3eedf43aa8931ef35bd074d24d0efafcdb8604d7a7079e1c91  libs/SDL2/lib/tvOS-Sim/libSDL2.a
a68b763366f4d603180232227d086acc05575467e5012040dea776bd45cee91f  libs/SDL2/lib/iOS-Sim/libSDL2.a
a2fbb2ac4e2c11177c6a8ec696c5e3a097527811c58f49afde70edd60dacb213  libs/opus/lib/iOS/libopus.a
ac1dd3d9a80987283f3baeff2a4a3b249611c155a46ed8fb739e45822034b777  libs/opus/lib/tvOS/libopus.a
f935480c8a0d91a6365a6731493a3ff91c3d451d3339a2dfe6a89e120a6f7e1e  libs/opus/lib/tvOS-Sim/libopus.a
3296f7c993aba55396ba0e9efcd9cd12dc3c092c906d4af3de60a6fa74c2b32d  libs/opus/lib/iOS-Sim/libopus.a
```
