// The shader backgrounds Nebula, Plasma, Lava, Caustics, Bokeh and Orbit: line-by-line ports of the AGSL shaders in
// DELOS for Android (shell/ui/BackgroundShaders.kt, PRELUDE and SOURCES); keep both in step. Coordinates are pixels of
// the 960 x 540 background canvas (scaled to the screen by the caller). Contour lives in Contour.metal.
//
// Every shader takes: position, the pixel in points; unit, points per canvas pixel; res, the canvas size in canvas
// pixels; t, the background clock; c1, c2 and c3, the main, secondary and accent lights (lights() in Backdrop); glow,
// how strongly they light the theme color. Each returns a premultiplied color.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace {

// The uniforms of the AGSL prelude that every background shares
struct Lights {
    float3 c1;
    float3 c2;
    float3 c3;
    float glow;
};

Lights lights(half4 c1, half4 c2, half4 c3, float glow) {
    return Lights { float3(c1.rgb), float3(c2.rgb), float3(c3.rgb), glow };
}

// GLSL's mod(): the result takes the sign of y (Metal's fmod takes the sign of x)
float glslMod(float x, float y) { return x - y * floor(x / y); }
float2 glslMod(float2 x, float y) { return x - y * floor(x / y); }

// precise::sin: the hash needs the full precision of large arguments, as AGSL's highp sin gives it
float hash(float2 p) { return fract(precise::sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x), mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        a *= 0.5;
    }
    return v;
}

// The three colors by weight: 60 / 25 / 15 (main, secondary, accent). tri(): k around 0.5 is the main color,
// lower values lean to the secondary one, only the high end brings in the accent
float3 tri(float k, Lights l) { return mix(mix(l.c2, l.c1, clamp(k * 3.0 - 0.3, 0.0, 1.0)), l.c3, clamp(k * 2.5 - 1.55, 0.0, 1.0)); }

// pick(): the same weights for u in 0..1; (i + 0.5) * 0.618 keeps the colors of neighbouring items well spread
float3 pick(float u, Lights l) { return u < 0.6 ? l.c1 : (u < 0.85 ? l.c2 : l.c3); }

half4 emit(float3 col, float a, Lights l) {
    a = clamp(a * l.glow, 0.0, 1.0);
    return half4(half3(col * a), half(a));
}

} // namespace

// Soft clouds of the three colors drifting through each other
[[ stitchable ]] half4 delosNebula(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = fc / res.y;
    float2 q = float2(fbm(uv * 2.2 + t * 0.03), fbm(uv * 2.2 + float2(5.2, 1.3) - t * 0.025));
    float n = fbm(uv * 2.0 + q * 1.6 + float2(t * 0.02, 0.0));
    float3 col = mix(l.c1, l.c2, smoothstep(0.3, 0.9, q.x));
    col = mix(col, l.c3, smoothstep(0.45, 0.85, q.y) * 0.8);
    return emit(col, smoothstep(0.3, 0.95, n) * 0.9, l);
}

// Interfering sine waves mixing the three colors
[[ stitchable ]] half4 delosPlasma(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = fc / res.y * 3.0;
    float v = sin(uv.x + t * 0.4) + sin(uv.y * 1.3 - t * 0.3) + sin((uv.x + uv.y) * 0.7 + t * 0.25)
        + sin(length(uv - float2(2.6 + sin(t * 0.2), 1.5 + cos(t * 0.17))) * 1.6 - t * 0.5);
    v = v * 0.25 * 0.5 + 0.5;
    return emit(tri(v, l), 0.4 + 0.3 * sin(v * 12.566 + t * 0.5), l);
}

// A lava lamp: blobs that merge and part again
[[ stitchable ]] half4 delosLava(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = fc / res.y;
    float ax = res.x / res.y;
    float f = 0.0;
    float3 acc = float3(0.0);
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        float2 c = float2(ax * (0.5 + 0.42 * sin(t * (0.07 + fi * 0.013) + fi * 1.7)), 0.5 + 0.4 * cos(t * (0.06 + fi * 0.011) + fi * 2.3));
        float r = 0.09 + 0.04 * sin(fi * 3.1);
        float d = r * r / max(dot(uv - c, uv - c), 0.0001);
        f += d;
        float3 cc = pick(fract((fi + 0.5) * 0.618034), l);
        acc += cc * d;
    }
    float3 col = acc / max(f, 0.0001);
    return emit(col, smoothstep(0.9, 1.5, f) * 0.85 + smoothstep(0.25, 1.0, f) * 0.22, l);
}

// Light dancing on the bottom of a pool
[[ stitchable ]] half4 delosCaustics(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = fc / res;
    float2 p = glslMod(fc / res.y * 4.0, 6.28318) - 250.0;
    float2 i = p;
    float c = 1.0;
    float inten = 0.005;
    for (int n = 0; n < 4; n++) {
        float tt = t * 0.22 * (1.0 - (3.5 / float(n + 1)));
        i = p + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
    }
    c /= 4.0;
    c = 1.17 - pow(c, 1.4);
    float v = clamp(pow(abs(c), 8.0), 0.0, 1.0);
    float3 col = mix(mix(l.c2, l.c1, smoothstep(0.0, 0.7, uv.y)), l.c3, v * 0.5);
    return emit(col, v * 0.9 + 0.12 * (1.0 - uv.y), l);
}

// Out-of-focus lights drifting slowly
[[ stitchable ]] half4 delosBokeh(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = fc / res.y;
    float ax = res.x / res.y;
    float3 acc = float3(0.0);
    float aa = 0.0;
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float s = hash(float2(fi, 1.3));
        float2 c = float2(fract(hash(float2(fi, 7.1)) + t * (0.003 + 0.008 * s)) * (ax + 0.3) - 0.15,
                          fract(hash(float2(fi, 3.7)) - t * (0.002 + 0.006 * s)) * 1.3 - 0.15);
        float r = 0.04 + 0.11 * s;
        float d = length(uv - c);
        float m = (1.0 - smoothstep(r * 0.8, r, d)) * (0.3 + 0.7 * (1.0 - s));
        m += smoothstep(r * 0.75, r * 0.96, d) * (1.0 - smoothstep(r * 0.96, r, d)) * 0.35;
        float3 cc = pick(fract((fi + 0.5) * 0.618034), l);
        acc += cc * m * 0.4;
        aa += m * 0.4;
    }
    float a = clamp(aa, 0.0, 1.0);
    return emit(acc / max(aa, 0.0001), a, l);
}

// Thin orbits around a glowing center, with a light travelling each of them
[[ stitchable ]] half4 delosOrbit(float2 position, half4 color, float unit, float2 res, float t, half4 c1, half4 c2, half4 c3, float glow) {
    Lights l = lights(c1, c2, c3, glow);
    float2 fc = position / unit;
    float2 uv = (fc - res * float2(0.64, 0.5)) / res.y;
    float2 e = float2(uv.x * 0.94 + uv.y * 0.34, (uv.y * 0.94 - uv.x * 0.34) * 2.1);
    float r = length(e);
    float ang = atan2(e.y, e.x);
    float3 col = l.c1 * exp(-r * 7.0) * 0.8;
    float a = exp(-r * 7.0) * 0.5;
    for (int k = 1; k < 8; k++) {
        float fk = float(k);
        float rr = 0.1 * fk;
        float line = 1.0 - smoothstep(0.0, 0.0035 + 0.001 * fk, abs(r - rr));
        float pa = glslMod(t * (0.35 / fk) + fk * 1.3, 6.28318) - 3.14159;
        float da = abs(glslMod(ang - pa + 3.14159, 6.28318) - 3.14159);
        float trail = exp(-da * 3.0) * (1.0 - smoothstep(0.0, 0.01, abs(r - rr)));
        // AGSL: exp(-pow((r - rr) / 0.01, 2.0)). pow() of a negative base is undefined in Metal (NaN with fast math),
        // so the square is written out: the same Gaussian across the ring
        float dr = (r - rr) / 0.01;
        float spark = exp(-da * da * 300.0) * exp(-(dr * dr));
        float3 cc = pick(fract((fk + 0.5) * 0.618034), l);
        float v = line * 0.28 + trail * 0.45 + spark * 1.4;
        col += cc * v;
        a += v;
    }
    return emit(col / max(a, 0.0001), a, l);
}
