#include "CDelosCommon.h"
#include "../core/src/Limelight-internal.h"

int DelosCommonGetStreamEncryption(void) {
    return ((EncryptionFeaturesEnabled & SS_ENC_VIDEO) ? DELOS_STREAM_ENCRYPTION_VIDEO : 0) |
        (AudioEncryptionEnabled ? DELOS_STREAM_ENCRYPTION_AUDIO : 0);
}
