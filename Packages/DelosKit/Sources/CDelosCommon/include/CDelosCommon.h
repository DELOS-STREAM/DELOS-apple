// The public API of the streaming core delos-common-c (ThirdParty/delos-common-c) as the Clang module CDelosCommon,
// plus the log forwarder of DelosLog.c.
#include "../core/src/Limelight.h"

/// Receives one formatted log message of the core.
typedef void (*DelosCommonLogSink)(const char *message);

/// Sets the function that receives the core's log lines; NULL discards them.
void DelosCommonSetLogSink(DelosCommonLogSink sink);

/// The variadic logMessage callback for CONNECTION_LISTENER_CALLBACKS. Swift cannot define a C variadic function,
/// so this C function formats the message and passes it to the sink.
ConnListenerLogMessage DelosCommonLogForwarder(void);

/// SS_HDR_METADATA flattened: Swift cannot import its anonymous nested structs.
typedef struct {
    uint16_t primaryX[3]; // red, green, blue; normalized to 50,000
    uint16_t primaryY[3];
    uint16_t whitePointX;
    uint16_t whitePointY;
    uint16_t maxDisplayLuminance; // nits
    uint16_t minDisplayLuminance; // 1/10000th of a nit
    uint16_t maxContentLightLevel; // nits
    uint16_t maxFrameAverageLightLevel; // nits
} DelosHdrMetadata;

/// LiGetHdrMetadata into the flat struct: false when the host's HDR mode is off or it sent no metadata.
bool DelosCommonGetHdrMetadata(DelosHdrMetadata *out);

/// The stream encryption the running connection negotiated (`MoonBridge.getStreamEncryption` of DELOS for Android,
/// simplejni.c:251): video in bit 0, audio in bit 1. Read it once the connection has started.
#define DELOS_STREAM_ENCRYPTION_VIDEO 1
#define DELOS_STREAM_ENCRYPTION_AUDIO 2
int DelosCommonGetStreamEncryption(void);
