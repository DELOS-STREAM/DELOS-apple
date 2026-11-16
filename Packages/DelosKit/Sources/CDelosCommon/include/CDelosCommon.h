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
