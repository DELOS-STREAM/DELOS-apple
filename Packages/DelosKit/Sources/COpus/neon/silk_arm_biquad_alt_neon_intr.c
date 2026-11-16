// Compiles opus/silk/arm/biquad_alt_neon_intr.c on arm64 only; SwiftPM cannot select sources by architecture.
#if defined(__aarch64__)
#include "../opus/silk/arm/biquad_alt_neon_intr.c"
#endif
