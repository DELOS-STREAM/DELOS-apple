# PyroWave on Apple

## Purpose

Issue #13: can DELOS for Apple decode PyroWave, and how. PyroWave is the intra-only wavelet codec of the Vibepollo host
that DELOS for Android decodes with Vulkan compute shaders. This document is the result of a research spike: it reads
the Android decoder, compares the two ways to run it on Apple GPUs (MoltenVK over the existing Vulkan decoder, or a port
of its compute shaders to Metal), measures what can be measured on a Mac without a host, and recommends one. Nothing of
PyroWave is in the app yet: the core carries the fields (`VideoFormats.pyroWave`, `PyroWaveSettings`,
`DecodeUnit.pyroWaveCriticalPackets`), `VideoOutput.codec(for: .pyroWave)` is `nil`, and the app never offers it.

Paths of the Android repository are relative to its checkout (`app/src/main/jni/pyrowave/`, the vendored tree).
Evidence marked `[INFERENCE]` was not measured or read in a source.

## How the Android decoder works

PyroWave is vendored from [Nonary/moonlight-qt](https://github.com/Nonary/moonlight-qt) `e4693208`, the official
Vibepollo client, which carries [Themaister/pyrowave](https://github.com/Themaister/pyrowave) `186f0393` and
[Themaister/Granite](https://github.com/Themaister/Granite) `b6cffd5c`; the core pins the same bit stream
(`PYROWAVE_BITSTREAM_ID "186f0393"`, which has no version field, so host and client must match). Both are MIT.

A frame is a set of independent 32 × 32 coefficient blocks (`bitstream/bitstream.md`): CDF 9/7 wavelet, five levels,
bit-plane payload with no entropy coder, so a lost packet costs detail, not the frame. Decoding has one CPU and two
GPU stages:

| Stage | Where | What it does |
|---|---|---|
| Frame parsing | `jni/pyrowave-renderer/pyrowaveframing.cpp` (503 lines, GPL-3.0 from Nonary) | Splits the core's decode unit (buffers marked `BUFFER_TYPE_LOST` / `BUFFER_TYPE_RECORD_START`, `pyrowaveCriticalPackets`) into runs of whole records; rejects malformed ones; marks the frame partial |
| Packet indexing and upload | `pyrowave_decoder.cpp` `push_packet`, `decode_packet`, `upload_payload` | Copies each record into one payload vector, keeps a per-block offset table (`block_index`, 24 bits), uploads both with `vkCmdUpdateBuffer` |
| Dequantisation | `shaders/wavelet_dequant.comp` (434 lines), 128 threads per block | Per level, component and band (42 dispatches for 4:2:0, 48 for 4:4:4): one threadgroup unpacks the bit planes of a 32 × 32 block, scans the sign bits across the subgroups, scales, and writes fp16/fp32 coefficients into an `image2DArray` (layers LL, HL, LH, HH) |
| Inverse wavelet transform | `shaders/idwt.comp` (214 lines), 64 threads per 32 × 32 output block | Per level, coarsest first, 13 dispatches for 4:2:0 (15 for 4:4:4), with a barrier per level: gathers the four bands with a mirrored-repeat sampler into threadgroup memory, runs the lifting steps down the rows, transposes while storing, and again for the other direction; the finest level writes the planes (`R8_UNORM`, or `R16_UNORM` for 10 bits) |

Android's default arithmetic is `PYROWAVE_PRECISION=1`: 16-bit storage (fp16 for the two finest levels, fp32 below),
32-bit arithmetic, and 16-bit threadgroup memory when the device has `shaderFloat16`. A second path, `idwt.frag`, does
the transform in render passes; Granite picks it only for Qualcomm and Arm GPUs (`device_prefers_fragment_path`).
The Android renderer (`pyrowave_renderer.cpp`, 4154 lines) is mostly not decoding: swapchain, upscaler, P010 output,
launch arrival. An Apple client needs only the decoder, whose C API (`pyrowave.h`) is about 2000 lines of Granite glue.

## What the decoder needs

Measured on this Mac (Apple M6, MoltenVK 1.4.2) by `tools/bench/moltenvk-probe`, which asks the real driver:

| Need | Source in the decoder | MoltenVK 1.4.2 on M6 | Metal |
|---|---|---|---|
| Subgroup operations: basic, vote, ballot, arithmetic, shuffle, shuffle-relative | `Decoder::init` refuses a device without all six | All six reported (`0x6ff`), subgroup size 32. Arithmetic needs Apple GPU family 7 (A14, M1) or newer (`MVKDevice.mm`: `simdReduction`); family 6 has shuffles only | `simd_prefix_inclusive_sum`, `simd_shuffle_up`, `simd_ballot`, `popcount`: same hardware floor [INFERENCE: a threadgroup-memory scan, which `wavelet_dequant.comp` already has as `scan_subgroups_fallback`, would lower it] |
| Required subgroup size (`VK_EXT_subgroup_size_control`) | `supports_subgroup_size_log2`, `enable_subgroup_size_control` | Feature reported, but `requiredSubgroupSizeStages` is 0: a size cannot be requested. The vendored Granite has a MoltenVK branch that uses the native size instead | Not needed: the width is fixed at 32 on Apple GPUs |
| `shaderFloat16`, 16-bit shared memory | `idwt.comp` `FP16` variant | Present | `half`, `half2` |
| 8-bit storage or texel buffers | `use_readonly_texel_buffer`: chosen when `maxTexelBufferElements` ≥ 16 Mi and the vendor is not AMD, Intel or NVIDIA | `storageBuffer8BitAccess` present; `maxTexelBufferElements` 134,217,728, so texel buffers (mode 1) are used; `R8/R16/R32_UINT` texel buffers present | `device const uchar*` loads: no texel-buffer detour needed |
| Storage images without a format | `shaderStorageImageWriteWithoutFormat` | Present; `R16_SFLOAT`, `R32_SFLOAT`, `R8_UNORM`, `R16_UNORM` all sampled and storage | `texture2d<half, access::write>` on `r16Float`, `r32Float`, `r8Unorm`, `r16Unorm` |
| `sampler2DArray`, `textureGather`, mirrored repeat | `idwt.comp` | Works (the transform ran and the pipelines compiled) | `gather` on `texture2d_array`, `address::mirrored_repeat`: ported and verified, see below |
| Synchronization2 (a hard requirement of Granite) | `context.cpp` | Present | Not applicable |
| Events, push descriptors | Granite | Not supported by MoltenVK; Granite emulates events with barriers under `__APPLE__` | Not applicable |
| External memory (`AHardwareBuffer`, DMA-BUF) for the P010 and GL hand-over | Android only | Not needed; hand-over to a Metal renderer would use `VK_EXT_metal_objects` (listed by MoltenVK; not exercised here) | Native |

Nothing the compute path needs is missing on either route. The extensions Granite uses opportunistically and MoltenVK
lacks (video queues, DMA-BUF, mesh shaders, Android hardware buffers) are not used by the decoder.

## The two routes

| | MoltenVK over the Vulkan decoder | Metal port of the compute shaders |
|---|---|---|
| Feasibility | Proven on this Mac: PyroWave's own SPIR-V (extracted from `slangmosh.hpp`) creates its pipelines and runs through MoltenVK. The vendored tree already has Apple code: it opens `libMoltenVK.dylib`, sets `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`, emulates events, and special-cases `VK_DRIVER_ID_MOLTENVK` (patch 0011, "macos-portability", named in `VENDOR-moonlight-qt.txt`) | Proven for the inverse transform: a port of `idwt.comp` to MSL matches an independent CPU CDF 9/7 reference (tests below). The dequantiser (434 lines) is not ported; every construct in it has a direct MSL equivalent [INFERENCE: nothing was compiled] |
| iOS and tvOS | MoltenVK links statically; no Vulkan loader (which tvOS lacks). Granite's `Context::init_loader(PFN_vkGetInstanceProcAddr)` takes a pointer but `pyrowave_create_device` passes `nullptr`, so a patch is needed; today it would `dlopen("libMoltenVK.dylib")` | Native on all three platforms |
| Missing features | None for the compute path (table above) | None |
| New binary dependency | MoltenVK 1.4.2 (Apache-2.0, compatible with GPL-3.0), release `v1.4.2`, tag commit `db66022459ffb663aa2b50f6b018bc2e124f5edf`: `MoltenVK-ios.tar` (34,535,424 bytes) SHA-256 `b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1`, `MoltenVK-macos.tar` SHA-256 `f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e`, and for tvOS only `MoltenVK-all.tar` (180,474,368 bytes) SHA-256 `562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276` (checksums as GitHub lists them; the macOS one was recomputed here), or a build from source with its pinned SPIRV-Cross and glslang. A [THIRD_PARTY.md](THIRD_PARTY.md) row per platform | None. The derived kernels keep the MIT notice of Hans-Kristian Arntzen |
| New source | The vendored tree: 49 of Granite's 94 C++ files plus four of pyrowave, volk and the Vulkan headers (6.9 MB in all, `Android.mk` lists the build); C++ in an app whose rules call the streaming core its only C code. The SPIR-V (`slangmosh.hpp`) is generated and cannot be regenerated from the Android repo (review finding V2 there): it needs the Granite slangmosh generator and a recorded provenance | About 2,000 lines of Swift and MSL [INFERENCE]: two kernels (214 + 434 lines of GLSL), a three-plane variant of `videoFragment` (the existing shader takes two planes), a Swift port of the host side (`pyrowave_decoder.cpp` 1,076 lines, `pyrowaveframing.cpp` 503 lines) |
| Upkeep | Follows the vendored tree: a new host bit stream means re-vendoring | A fork of the shader logic: a bit stream change (`PYROWAVE_BITSTREAM_ID`) needs a re-port. Android's vendored GLSL is not upstream: Nonary's patches 0001 to 0011 changed `wavelet_dequant.comp` and `block_packing.comp` (0010 states that it changes no decoded value), so a port starts from the vendored files |
| Dependency health | Khronos has deprecated MoltenVK: the repository "is now maintained by the community on a best-effort basis", it is not Vulkan-conformant, and it is still recommended for iOS ([README](https://github.com/KhronosGroup/MoltenVK), [LunarG, Oct. 2026](https://www.lunarg.com/the-state-of-vulkan-on-apple-oct-2026/)). KosmicKrisp, the conformant replacement, needs Metal 4 and macOS 26, and LunarG has no iOS build enabled ([Mesa](https://docs.mesa3d.org/drivers/kosmickrisp.html)) | The platform API |
| Cold start | The first pipeline of each module took 108 ms (inverse transform) and 94 ms (dequantiser) on the first run of a new executable, 2 – 4 ms on later runs (Metal's shader cache): SPIR-V to MSL to a Metal library at run time. A pipeline cache can store the MSL | A `.metallib` built with the app: pipeline creation without source compilation [INFERENCE: not measured] |
| Hand-over to `MetalRenderer` | `VK_EXT_metal_objects` to export the plane textures, plus a fence or `MTLSharedEvent` [not exercised] | The planes are Metal textures already |
| Test against Android | Same shaders: identical results | Not bit-exact by design ("The decoding process is not bit-exact", `bitstream.md`); compare with golden frames decoded by the MoltenVK route within a tolerance |
| Devices | A14 / M1 and newer (iPhone 12, iPad Air 4, Apple TV 4K 3rd generation (A15), Macs); Apple TV 4K 2nd generation (A12) and A13 devices cannot offer it | The same hardware floor; lower only with the threadgroup scan [INFERENCE] |

## Measurements

Both measurements time only the inverse wavelet transform with random coefficients in every band image, at 1080p
(aligned 1920 × 1088) and 4K (3840 × 2176), 8-bit planes, back to back, 700 frames after 100 warm-up frames.
Machine: Apple M6, 12 GPU cores, Metal 4, Apple GPU family 10, macOS 27.2, while other jobs of the same machine were
running (load average about 15): the GPU was shared, so the tails (p95, p99, maximum) are inflated and only the medians
and the throughput are meaningful. Every figure is milliseconds per frame, three runs each.

| Configuration | Metal port, serial encoder | Metal port, concurrent encoder with a barrier per level | MoltenVK, PyroWave's own SPIR-V |
|---|---|---|---|
| 1080p 4:2:0 | 0.26 – 0.28 | 0.22 | 0.40 – 0.42 |
| 1080p 4:4:4 | 0.49 – 0.50 | 0.48 – 0.49 | 0.62 – 0.73 |
| 4K 4:2:0 | 1.06 – 1.08 | 1.03 – 1.21 | 1.12 – 1.38 |
| 4K 4:4:4 | 2.18 – 2.36 | 2.29 – 2.31 | 2.54 – 2.58 |

All with PyroWave's default arithmetic (fp32 math, fp16 storage and threadgroup memory, fp32 for the three coarsest
levels). 16-bit arithmetic (`PRECISION 0`) was 0 – 10 % faster (1080p 4:2:0, Metal, serial: 0.202 ms against 0.224 ms
median in the first matrix). The throughput is first frame start to last frame end of a queue that never runs empty;
the MoltenVK figure is the wall time of the queue, because its timestamp queries read near zero for single frames.

A decoder does not run back to back: it runs once per frame interval, and an idle GPU clocks down. Metal port, serial
encoder, per command buffer (GPU time) and from commit to the end of the GPU work (what the frame waits):

| Configuration | Pacing | GPU median | GPU p95 | Commit to done, median | Commit to done, p95 |
|---|---|---|---|---|---|
| 1080p 4:2:0 | back to back | 0.22 | 0.55 | not meaningful | not meaningful |
| 1080p 4:2:0 | 120 Hz | 0.28 | 0.88 | 0.47 | 1.29 |
| 1080p 4:2:0 | 60 Hz | 0.26 | 0.67 | 0.40 | 0.86 |
| 4K 4:2:0 | 120 Hz | 0.79 | 1.34 | 0.98 | 1.61 |
| 4K 4:2:0 | 60 Hz | 0.65 | 1.28 | 0.88 | 1.53 |
| 1080p 4:2:0 + coefficient writes | 120 Hz | 0.31 | 0.84 | 0.49 | 1.02 |
| 4K 4:2:0 + coefficient writes | 120 Hz | 1.28 | 2.04 | 1.41 | 2.23 |

"Coefficient writes" is a stand-in for the dequantisation pass, not the pass: a kernel that writes pseudo-random
coefficients into every coded band, as the dequantiser writes every band once (0.08 ms at 1080p and 0.45 ms at 4K
alone, back to back). It moves the same bytes but does none of the bit unpacking, so it bounds the memory side only.
In the 4:2:0 runs the largest single frame was 3.3 ms; 4K 4:4:4 peaked at 4.4 ms. The band data of one frame is 8.3 MB of fp16
at 1080p 4:2:0 and 33.4 MB at 4K (16.7 and 66.8 MB for 4:4:4).

### Estimate for A16 and M5 [INFERENCE]

The kernels are limited by arithmetic and threadgroup memory, not by memory bandwidth (the transform moves a few tens of
MB per frame), so time scales with GPU cores and clock. The M6 here has 12 cores, the A16 five (the Apple TV 4K 3rd
generation's A15 also five), the M5 ten. At equal clock the A16 is 12 / 5 = 2.4 times slower; a phone clocks lower,
say up to 3.5 times. That gives for the inverse transform at 1080p 4:2:0 about 0.5 – 1.0 ms on an A16 (0.22 – 0.28 ms
on the M6) and about 0.26 – 0.34 ms on an M5; at 4K 4:2:0 about 2.5 – 4.2 ms on an A16 and 1.2 – 1.5 ms on an M5. The
dequantiser was not measured. If it costs one to two times the inverse transform, a whole frame decodes in about
1 – 3 ms at 1080p on an A16: 12 – 36 % of the 8.33 ms of a 120 fps frame, before drawing and presenting. 4K on an A16
(about 5 – 13 ms) does not fit 120 fps and is tight at 60 fps (16.7 ms). Real devices were not touched; the numbers
need a device run before they are quoted as results.

## Recommendation

Port the compute shaders to Metal, and keep MoltenVK out of the app. Use MoltenVK only as an offline oracle.

- Speed does not decide it. Both routes are far inside the budget at 1080p: the transform takes 0.22 – 0.28 ms (Metal)
  and 0.40 – 0.42 ms (MoltenVK) on the M6, and the estimate for the weakest supported phone is 1 – 3 ms of 8.33 ms.
  The Metal port took 4 – 45 % less time on this Mac, which is not a reason by itself.
- MoltenVK would add a deprecated, non-conformant translation layer, three platform builds of a binary with its own
  provenance rows, 49 C++ files (the rules call the streaming core the only C code of the app), a
  patch to Granite's loader for iOS and tvOS, a run-time SPIR-V-to-MSL compile of about 100 ms per pipeline at start,
  and a generated SPIR-V blob without a reproducible origin. In return it would save the port and decode exactly as
  Android does.
- The Metal port has no new binary, builds with the shaders the app already ships (`VideoShaders.metal`), draws into the
  existing `MetalRenderer` without an interop layer, and the hardest kernel to get right, the transform with its mirrored
  gather and transposing stores, is done and checked against an independent reference. What it costs is the dequantiser,
  the host code and the discipline to follow the bit stream: a host with another `PYROWAVE_BITSTREAM_ID` needs a re-port.

Steps, in order:

1. Port `wavelet_dequant.comp` (the scans become `simd_prefix_inclusive_sum`; the payload is read as `uchar`, `ushort`
   and `uint` from one buffer). Check its output against the MoltenVK route fed with the same frame: PyroWave's
   `pyrowave-encode` makes frames, and `tools/bench/moltenvk-probe` shows how to run the real shaders on a Mac.
2. Port the host side and the frame parser to Swift with tests that use those frames, including frames with lost
   packets (`BUFFER_TYPE_LOST`) and a missing record header.
3. Add a three-plane variant of `videoFragment`, offer `VideoFormats.pyroWave` only where the Metal device reports
   Apple GPU family 7 or newer, and make 10-bit planes (`r16Unorm`) feed the existing EDR path.
4. Measure on a real iPhone and an Apple TV with the owner, with a host on the LAN; this is where the estimate above is
   replaced by a number.

## Verification

| What | How | Result |
|---|---|---|
| The Metal inverse transform against an independent CPU reference | `cd tools/bench/pyrowave-idwt && swift test`: a test image is padded, transformed by the double-precision CDF 9/7 in `CDF97Reference.swift` (written from the bit stream specification, not from the shader), its coefficients are rounded to 16 or 32 bits and uploaded, the kernel decodes them, and the planes are compared with the CPU inverse of the same coefficients and with the original image. Six size, chroma and arithmetic cases (200 × 136 and 416 × 270 are not multiples of 32 and exercise padding and cropping; 416 × 270 makes the apron cross threadgroups on every level) × three components, 10-bit planes | Pass. Largest difference to the reference 0.0011 (float arithmetic) and 0.0042 (half arithmetic); PSNR to the reference 75.4 – 76.0 dB (float) and 64.7 – 65.4 dB (half). The thresholds in the test are 0.006 and 70 / 60 dB |
| The test can fail | One lifting constant in the shader changed from 0.4435 to 0.41 | The kernel test failed with 54 issues; reverted |
| The layout arithmetic and the CPU reference | Same package: aligned and band sizes, passes of 4:2:0 and 4:4:4, threadgroup coverage, 1-D and 2-D round trip to 1e-10, a constant signal has no high-pass | Pass (11 tests in 3 suites; the kernel test has six cases) |
| PyroWave's own shaders on MoltenVK | `sh tools/bench/moltenvk-probe/run.sh <Android checkout>`: downloads MoltenVK 1.4.2, checks its SHA-256, cuts the SPIR-V out of `slangmosh.hpp`, links the probe against `libMoltenVK.dylib`, prints the features, creates the pipelines and times the transform | All needed features present; the inverse-transform and dequantiser pipelines were created; the transform ran at the throughput above. The probe is a command-line tool; no app was started |
| The figures | `cd tools/bench/pyrowave-idwt && swift build -c release && .build/release/idwt-bench --matrix`, `--size`, `--chroma`, `--math`, `--paced-hz`, `--with-fill`, `--fill-only`, `--concurrent` | The tables above, on one Mac |
| The probe's first version had no data in the band images | MoltenVK timed 0.19 ms (1080p 4:2:0) on never-written memory, against 0.31 – 0.42 ms with random coefficients | The faster figure is not used; reading never-written GPU memory is cheaper than reading data |

### Not verified

- Decoding of a real PyroWave bit stream: no host was used, no `pyrowave-encode` frame was decoded, and the Metal
  dequantiser does not exist. The kernel was tested on coefficients made by the CPU reference.
- Any run on an iPhone, iPad, Apple TV or on the M5 or A16 themselves. The estimate for them is arithmetic on core
  counts. The iOS and tvOS simulators were not used: they would run on this Mac's GPU and say nothing about the devices.
- The speed of the dequantiser, and therefore of a whole decode, on any hardware.
- Pipeline creation from a precompiled metallib (the cold start of the Metal route), thermals, power and the 120 fps
  behaviour of a full stream with a real host.
- MoltenVK on iOS and tvOS (only the macOS build was run), `VK_EXT_metal_objects` hand-over, building Granite with
  Xcode 27, and building MoltenVK from source. Whether Vibepollo's macOS client uses MoltenVK in the field was not checked;
  only the patch note in the vendored `VENDOR-moonlight-qt.txt` and the Apple code in the vendored tree were read.
- The tails of all timings: the GPU was shared with other jobs during every run.
- A device older than family 7 with a threadgroup-memory scan, and 10-bit (`r16Unorm`) output at speed (the tests
  decode 10-bit planes; the timings use 8-bit ones).
