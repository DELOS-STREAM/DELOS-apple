// Compiles opus/silk/arm/NSQ_neon.c on arm64 only; SwiftPM cannot select sources by architecture.
#if defined(__aarch64__)
#include "../opus/silk/arm/NSQ_neon.c"
#endif
