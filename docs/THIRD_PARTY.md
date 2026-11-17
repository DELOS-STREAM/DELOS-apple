# Third-party code and binaries

Every piece of code or binary that DELOS for Apple did not write is listed here with its origin, version, license and,
for binaries, checksum (rule of [ENGINEERING_RULES.md](ENGINEERING_RULES.md)).

## Source code

| Component | Path | Origin | Version | License |
|---|---|---|---|---|
| delos-common-c, the DELOS streaming core (submodule; built as `CDelosCommon`) | `ThirdParty/delos-common-c` | [Meitoncz/Delos-common-c](https://github.com/Meitoncz/Delos-common-c) | `8c208139e841c9f5fffe6e4f1606bfdf922c9707` (`master`) | GPL-3.0 |
| ENet, fork for moonlight-common-c (submodule of delos-common-c) | `ThirdParty/delos-common-c/enet` | [cgutman/enet](https://github.com/cgutman/enet) | `98dbb897ac4a7208038e0782cddedf89dcf0723a` | MIT |
| nanors, Reed-Solomon FEC (submodule of delos-common-c) | `ThirdParty/delos-common-c/nanors` | [sleepybishop/nanors](https://github.com/sleepybishop/nanors) | `a9b1636f9c98dbfdd0daeaf6982ccd24d1c30f29` | MIT |
| libopus (submodule; built as `COpus`) | `ThirdParty/opus` | [xiph/opus](https://github.com/xiph/opus) | `v1.6.1`, `22244de5a79bd1d6d623c32e72bf1954b56235be` | BSD-3-Clause |

## Derived code

| Code | Derived from | License |
|---|---|---|
| `tools/bench/pyrowave-idwt` (`IDWTShaders.swift`): the inverse wavelet transform kernel of the benchmark, ported from GLSL to Metal Shading Language | `shaders/idwt.comp` and `dwt_common.h` of [Themaister/pyrowave](https://github.com/Themaister/pyrowave) `186f0393b77f7755953b5ecde994bb1cec2e4155`, Copyright (c) 2025 Hans-Kristian Arntzen, as vendored by DELOS for Android | MIT; the notice is kept in the file |

`tools/bench/moltenvk-probe/run.sh` downloads MoltenVK 1.4.2 (Apache-2.0) into a temporary directory, checks its SHA-256 and
deletes it; nothing of MoltenVK or of PyroWave's SPIR-V is stored in this repository.

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

## Avatars

The sixteen profile avatars and their badge colors in `Packages/DelosKit/Sources/DelosUI/Resources/Avatars/` are copied
byte for byte from DELOS for Android (`app/src/main/assets/avatars/`, last changed in commit `726693e0`). They were
made for DELOS with an image generator (gpt-image-2) and imported by Android's `tools/avatars/import.py`, which also
writes `avatars.json` (docs/gui/START_AND_HOME.md of DELOS for Android, "Profile avatars"). Original to DELOS, project
license.

| File | SHA-256 |
|---|---|
| `avatars.json` | `aaa653a43e96ee9ab2f0f31b5758944361d70c632e492c40d0c6c04d63c8c849` |
| `calm.webp` | `3afad9fde877b4e6f063a0058b60c905dee6daa01b2c960b9e265189652d421e` |
| `cat.webp` | `6ea41f27a13f7b87c64a3cdf515bc41fd5c6586e1bf18647bda9e0f0a112725d` |
| `dragon.webp` | `5cc719fc9791bdf654b796ca1e71d3f7183f7ed34c2ce2a991ccea846c5ae8b8` |
| `fox.webp` | `ce235917d1a204307161e349d535ccd03807264dee4583c610e5fdc65103dcd7` |
| `ghost.webp` | `f351fb9170f806663f98c1b64fce9ea0985d318448208207fd13ef63d8d7438c` |
| `hacker.webp` | `43dcf913641a2c600a9f59e3887c8feec73c250c00e774254071def60cdbd34e` |
| `knight.webp` | `f06bc34aa6897d1c2069ca35d5688a4c3801af4d41bf5889c8d258086c9b0778` |
| `owl.webp` | `6e02116ad7b3ab12125145897213c8ae5d41fc88fd6876b3409f25141dd56bc1` |
| `player.webp` | `3645227cff9cb95c3208051c4d316f6b7e5eee7b114a63843fbda073cba7c17a` |
| `racer.webp` | `142cc01e9d0b47fc9976a20c6290c897d6a12ba7f4765d1748c5a9ef925864b0` |
| `robot.webp` | `1b39100b8ead3f9b52636c75158366c7a8946f37bf1d821c520bddc780c9a260` |
| `sailor.webp` | `34dac01f10135b4ab6b8a6792d72b487ae38cc82caaa8211e786caf284af51b1` |
| `spark.webp` | `5a7bb3654c11d77ff942e88ecd8a6060d1c541e4637d294f0d39f5612be80bb0` |
| `voyager.webp` | `087d5e4b9c0f0a43cda1e677b6714789c783f1707aa0c9487ac4cff163d626cc` |
| `wizard.webp` | `e67bf9eeda7b75d86b88e6e61ff6254bd181cee8aee68fdbfb5b79730fe3ebb0` |
| `wolf.webp` | `2391c5bffa9aa0e26bd33addba8ecea90537f00d7fa45c2e4b1aa3f033dd9747` |

## Game metadata services

The metadata data layer ports DELOS for Android's `GameMetadata`, policy and clients (project GPL-3.0).
IGDB, PCGamingWiki and Steam tags are requested through the private DELOS metadata Worker, never with embedded
provider credentials. HowLongToBeat is requested directly; its website is not an official public API and can change.
Provider content remains subject to each service's terms. No service response is embedded in the app.

The HLTB search flow and payload derive from [howlongtobeatpy](https://github.com/ScrappyCocco/HowLongToBeat-PythonAPI)
1.0.24, `HTMLRequests.py`, commit `4275a452b9ccd230b7c2a82b8d1a5d851285eb14`, MIT, Copyright (c) 2018 Michele.
The complete MIT notice is retained in `MetadataHowLongToBeat.swift`. Offline metadata test fixtures cite the
corresponding Android client tests in their Swift test files.

## Swift packages

| Package | Origin | Version | Pin |
|---|---|---|---|
| OpenSSL-Package (binary OpenSSL for the C core) | [krzyzanowskim/OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) | 3.6.3000 (exact, `Packages/DelosKit/Package.swift`) | revision `a3809db22a45e3ff658377a24da252982a306b9b`; its binary target `OpenSSL.xcframework.zip` (from [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL/releases/tag/3.6.3000)) has SHA-256 `6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c`, which SwiftPM verifies |

