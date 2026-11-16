// Formats the core's printf-style log messages for Swift (see include/CDelosCommon.h).
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>

#include "CDelosCommon.h"

static _Atomic(DelosCommonLogSink) logSink;

void DelosCommonSetLogSink(DelosCommonLogSink sink) {
    atomic_store(&logSink, sink);
}

static void forwardLogMessage(const char *format, ...) {
    DelosCommonLogSink sink = atomic_load(&logSink);
    if (sink == NULL) {
        return;
    }

    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    sink(message);
}

ConnListenerLogMessage DelosCommonLogForwarder(void) {
    return forwardLogMessage;
}
