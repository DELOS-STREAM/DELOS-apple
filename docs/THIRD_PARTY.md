# Third-party code and binaries

Every piece of code or binary that DELOS for Apple did not write is listed here with its origin, version, license and,
for binaries, checksum (rule of [ENGINEERING_RULES.md](ENGINEERING_RULES.md)).

## Source code

| Component | Path | Origin | Version | License |
|---|---|---|---|---|
| Moonlight for iOS/tvOS (reference app, to be removed) | `Limelight/`, `Moonlight TV/`, `Moonlight.xcodeproj`, storyboards | [moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) | fork point `02dc978` | GPL-3.0 |
| moonlight-common-c (submodule, to be replaced by the DELOS core) | `moonlight-common/moonlight-common-c` | [moonlight-stream/moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `f900dd47` | GPL-3.0 |
| X1Kit (submodule, to be removed) | `X1Kit` | [cgutman/X1Kit](https://github.com/cgutman/X1Kit) | `6e842ae9` | MIT |
| delos-common-c, the DELOS streaming core (submodule; built as `CDelosCommon`) | `ThirdParty/delos-common-c` | [Meitoncz/Delos-common-c](https://github.com/Meitoncz/Delos-common-c) | `8c208139e841c9f5fffe6e4f1606bfdf922c9707` (`master`) | GPL-3.0 |
| ENet, fork for moonlight-common-c (submodule of delos-common-c) | `ThirdParty/delos-common-c/enet` | [cgutman/enet](https://github.com/cgutman/enet) | `98dbb897ac4a7208038e0782cddedf89dcf0723a` | MIT |
| nanors, Reed-Solomon FEC (submodule of delos-common-c) | `ThirdParty/delos-common-c/nanors` | [sleepybishop/nanors](https://github.com/sleepybishop/nanors) | `a9b1636f9c98dbfdd0daeaf6982ccd24d1c30f29` | MIT |
| libopus (submodule; built as `COpus`) | `ThirdParty/opus` | [xiph/opus](https://github.com/xiph/opus) | `v1.6.1`, `22244de5a79bd1d6d623c32e72bf1954b56235be` | BSD-3-Clause |

## Fonts

Copied byte for byte from DELOS for Android (`app/src/main/res/font/`), where `tools/fonts/subset_fonts.py` makes them
from verified sources; the licence files are next to them in `Packages/DelosKit/Sources/DelosUI/Resources/Licenses/`.
`tools/fonts/sync_symbols.py` generates `Symbols.swift` from the same Android build.

| File (in `Packages/DelosKit/Sources/DelosUI/Resources/Fonts/`) | Source | Version | License | SHA-256 |
|---|---|---|---|---|
| `unbounded.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/unbounded` | commit `e7db6ca603fd4862010383ff17ffd6cc4ffac1c0` | OFL-1.1 | `af82d541d5007a370b0fd6e05d573ae7214fb0b5c1ece3327c17ebd971bf19d1` |
| `figtree.ttf` | google/fonts `ofl/figtree` | same commit | OFL-1.1 | `723c2843a782299a5473cbbe9ad44b685fe0994d17a4b7dc75e4644ae695e962` |
| `phosphor_regular.ttf` (subset) | [phosphor-icons/web](https://github.com/phosphor-icons/web) | `v2.1.2` | MIT | `8bd032eee68c9fba5e822d613d26d874ad3bf2f4866d1182b349995dc31faf63` |
| `phosphor_fill.ttf` (subset) | phosphor-icons/web | `v2.1.2` | MIT | `79723fd6a2025abee9e17ef6d06c46afc31542f7282a390afd3fbce07db4c3fa` |

## Sounds

The five interface sounds in `Packages/DelosKit/Sources/DelosUI/Resources/Sounds/` are copied byte for byte from DELOS
for Android (`app/src/main/res/raw/`), where `tools/sounds/make_ui_sounds.py` generates them with the Python standard
library. Original to DELOS, project license.

| File | SHA-256 |
|---|---|
| `ui_back.wav` | `86bae9cbe479da868cf6618c91ccb54bdb235b6f637cd7eb59120f8b16893063` |
| `ui_error.wav` | `f1f61cb7b44c6a890d523028c1496fdfe612bd6f9fca9cc0df1ae2ac7555ae16` |
| `ui_move.wav` | `441a2145027ebbdf2a3730276f19523eee03b10af95d5b58d4fa68b05d011429` |
| `ui_open.wav` | `6aaa9375991c24123c5f582bd3431acba8a6e0d691bb2aae2bf363641e2c769e` |
| `ui_select.wav` | `c896cdcc6cf480adb352d6db7680b1f2068fd0eff364904b0db44c46baf7cc47` |

## Test fixtures

Made by `tools/media/make_fixtures.sh` with FFmpeg 9.0.2 (libx264, libx265, SVT-AV1 4.3.0) from FFmpeg's built-in
`testsrc2` pattern: two frames of 64 × 64 per codec. The encoders are not bit-exact across versions, so the files are
kept with their checksums. Original to DELOS, project license.

| File (in `Packages/DelosKit/Tests/DelosMediaTests/Fixtures/`) | SHA-256 |
|---|---|
| `frames.h264` | `5ce19cb9470c4b3b04eac095b076b0d6432a441be45fefc785f6e78407550e56` |
| `frames.hevc` | `5dec7f31032adf7be32d92ae91615ca25900db8ecfc22f921558c1970c6dd6a1` |
| `frames.obu` | `af07a43a263e20c5514a74e2a66886b233eea5468bb9752df6cf22a2c654ec40` |
| `frames-10bit.obu` | `0601e1db7791b230c89745325a100dd4392c8645ccf99478c2e5acfd41d5f2ac` |

## Swift packages

| Package | Origin | Version | Pin |
|---|---|---|---|
| OpenSSL-Package (binary OpenSSL for the C core) | [krzyzanowskim/OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) | 3.6.3000 (exact, `Packages/DelosKit/Package.swift`) | revision `a3809db22a45e3ff658377a24da252982a306b9b`; its binary target `OpenSSL.xcframework.zip` (from [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL/releases/tag/3.6.3000)) has SHA-256 `6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c`, which SwiftPM verifies |

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
