#include "CDelosCommon.h"

bool DelosCommonGetHdrMetadata(DelosHdrMetadata *out) {
    SS_HDR_METADATA raw;
    if (!LiGetHdrMetadata(&raw)) {
        return false;
    }
    for (int i = 0; i < 3; i++) {
        out->primaryX[i] = raw.displayPrimaries[i].x;
        out->primaryY[i] = raw.displayPrimaries[i].y;
    }
    out->whitePointX = raw.whitePoint.x;
    out->whitePointY = raw.whitePoint.y;
    out->maxDisplayLuminance = raw.maxDisplayLuminance;
    out->minDisplayLuminance = raw.minDisplayLuminance;
    out->maxContentLightLevel = raw.maxContentLightLevel;
    out->maxFrameAverageLightLevel = raw.maxFrameAverageLightLevel;
    return true;
}
