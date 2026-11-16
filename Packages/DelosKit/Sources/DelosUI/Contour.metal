// The Contour background: topographic lines over slowly shifting terrain, every fourth line stronger, like on a map.
// A line-by-line port of the AGSL shader BackgroundKind.CONTOUR in DELOS for Android (shell/ui/BackgroundShaders.kt);
// keep both in step. Coordinates are pixels of the 960 x 540 background canvas (scaled to the screen by the caller).
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float contourField(float2 p, float2 res, float t) {
    return sin(p.x * 0.0062 + t * 0.07) + sin(p.y * 0.0081 - t * 0.05 + p.x * 0.002) + 0.7 * sin((p.x - p.y) * 0.0047 + t * 0.09)
        + 0.5 * cos(length(p - float2(res.x * 0.66, res.y * 0.5)) * 0.011 - t * 0.12);
}

// position: the pixel in points; unit: points per canvas pixel; res: the canvas size in canvas pixels; c1 and c2: the
// colors of the lowest and the highest level; dark: 1 in the dark theme. Returns a premultiplied color.
[[ stitchable ]] half4 delosContour(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, float dark) {
    float2 fc = position / unit;
    float f = contourField(fc, res, t);
    float2 grad = float2(contourField(fc + float2(1.0, 0.0), res, t) - f, contourField(fc + float2(0.0, 1.0), res, t) - f);
    float k = (f + 2.8) / 0.35;
    float level = floor(k + 0.5);
    if (level < 0.0 || level > 16.0) return half4(0.0);
    // Distance to the nearest line in canvas pixels: the field's distance divided by its slope
    float dist = abs(k - level) * 0.35 / max(length(grad), 0.0001);
    bool major = fmod(level, 4.0) < 0.5;
    float width = major ? 1.7 : 1.0;
    float line = 1.0 - smoothstep(width * 0.5 - 0.45, width * 0.5 + 0.45, dist);
    float u = level / 16.0;
    float a = ((major ? 0.46 : 0.16) + u * (dark > 0.5 ? 0.18 : 0.14)) * line;
    float3 col = mix(float3(c1.rgb), float3(c2.rgb), u * (0.4 + 0.6 * u));
    return half4(half3(col * a), half(a));
}
