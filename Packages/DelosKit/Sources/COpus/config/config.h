// Build configuration of libopus for DELOS (replaces the config.h that autotools, CMake or Meson generate).
// Floating-point build: every Apple CPU has a fast FPU, and the stream's audio is decoded to float.
// NEON intrinsics are always present on arm64, so they are presumed and no run-time CPU detection is built.
#ifndef DELOS_OPUS_CONFIG_H
#define DELOS_OPUS_CONFIG_H

#define VAR_ARRAYS 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define HAVE_STDINT_H 1

#if defined(__aarch64__)
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#define OPUS_ARM_PRESUME_NEON_INTR 1
#define OPUS_ARM_MAY_HAVE_AARCH64_NEON_INTR 1
#define OPUS_ARM_PRESUME_AARCH64_NEON_INTR 1
#endif

#endif
