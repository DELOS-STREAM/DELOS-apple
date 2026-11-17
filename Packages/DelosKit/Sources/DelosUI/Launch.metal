// The launch tunnel: a line-by-line port of the AGSL shader HYPERSPACE_SHADER in DELOS for Android
// (shell/ui/HyperspaceTunnel.kt, constants in HyperspaceConfig.kt); keep both in step. position is the pixel in points,
// resolution the size of the drawn area in points; the Swift side (LaunchTunnel) works out time, the travel integral and
// the smoothed progress, and passes the three palette accents already weighted by their gains. Returns a premultiplied color.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace {

constant float2 kCenter = float2(0.5, 0.5);
constant float kDepth = 0.28;
constant float kThroat = 0.045;
constant float kWallGain = 0.62;
constant float kSpokes = 44.0;
constant float kBandFrequency = 5.2;
constant float kSwirl = 0.22;
constant float kVelocity = 0.9;
constant float kAcceleration = 2.6;
constant float kStreakLength = 0.78;
constant float kAberration = 0.0016;
constant float kOpeningAcceleration = 5.5;
constant float kCloudDensity = 0.48;
constant float kCloudFlashGain = 0.11;
constant float kCloudRim = 0.028;
constant float kCloudSize = 0.19;
constant float kCloudDrift = 0.04;
constant float kEdgeBloom = 0.16;
constant float kSpeedDecay = 3.2;
constant float kContrast = 1.12;
constant float kExposure = 1.55;
constant float kIrisStart = 0.68;
constant float kIrisEnd = 0.88;
constant float kIrisSoftness = 0.055;
constant float kZoomStart = 0.10;
constant float kZoomEnd = 1.0;
constant float kZoomScale = 11.0;
constant float kOpeningSeconds = 2.2;
constant float kLensPinch = 1.15;
constant int kStreakCount = 24;
constant int kCloudCount = 24;

// GLSL's mod(): the result takes the sign of y
float glslMod(float x, float y) { return x - y * floor(x / y); }

// precise::sin: the hash needs the full precision of large arguments, as AGSL's highp sin gives it
float hashN(float n) { return fract(precise::sin(n * 127.1 + 311.7) * 43758.5453); }

float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    return length(p - a - ab * clamp(dot(p - a, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0));
}

}

[[ stitchable ]] half4 delosHyperspace(
    float2 position, half4 currentColor, float2 resolution, float time, float progress, float opening, float travelBase,
    float3 bg, float3 gold, float3 cyan, float3 indigo
) {
    float2 uv = position / resolution;
    float aspect = resolution.x / resolution.y;
    float2 screen = (uv - kCenter) * float2(aspect, 1.0);
    float o = clamp(opening, 0.0, 1.0);
    // Revealed pixels skip all 48 streak/cloud iterations
    if (o >= 1.0) return half4(0.0h);
    float iris = clamp((o - kIrisStart) / (kIrisEnd - kIrisStart), 0.0, 1.0);
    iris = iris * iris * iris * (iris * (iris * 6.0 - 15.0) + 10.0);
    float apertureRadius = mix(-(kIrisSoftness + 0.001), length(float2(aspect, 1.0)) * 0.5 + kIrisSoftness + 0.01, iris);
    float opacity = smoothstep(apertureRadius - kIrisSoftness, apertureRadius + kIrisSoftness, length(screen));
    if (opacity <= 0.0) return half4(0.0h);

    // Pure accelerating tunnel zoom
    float zoomPhase = clamp((o - kZoomStart) / (kZoomEnd - kZoomStart), 0.0, 1.0);
    float expansion = zoomPhase * zoomPhase;
    float zoom = 1.0 + (kZoomScale - 1.0) * expansion;
    screen /= zoom;
    float baseSpeed = kVelocity + progress * progress * kAcceleration;
    float k = kSpeedDecay;
    float t = time;
    // Integrated exponential acceleration/deceleration, continuous at exit takeover
    float travel = travelBase + kOpeningSeconds *
        (baseSpeed * o + 3.0 * kOpeningAcceleration * (1.0 - (1.0 + k * o) * exp(-k * o)) / (k * k));

    float2 q = screen * (1.0 + kLensPinch * float2(screen.y * screen.y, screen.x * screen.x));
    float theta = atan2(abs(q.y), abs(q.x) + 0.000001);
    float r = length(q);
    float depth = kDepth / (r + 0.065);
    float wall = smoothstep(kThroat, 0.14, r) * (1.0 - smoothstep(1.12, 1.75, r));
    float turn = sin(depth * 0.8 + travel * 0.30) * kSwirl;
    float groove = 0.5 + 0.5 * cos(theta * kSpokes + turn + sin(depth * 1.7) * 0.55);
    float ribs = pow(max(groove, 0.0), 32.0);
    float wave = 0.5 + 0.5 * cos(depth * kBandFrequency + travel * 3.4);
    float bands = pow(max(wave, 0.0), 12.0);
    float glow = 0.035 + 0.14 * groove + 0.28 * bands;
    float3 tint = mix(indigo, cyan, 0.5 + 0.5 * cos(theta * 2.0));
    float3 color = bg * 0.16 + tint * wall * glow * kWallGain;
    color += cyan * wall * ribs * (0.065 + 0.19 * progress);
    color += gold * wall * pow(max(0.5 + 0.5 * cos(depth * kBandFrequency + travel * 3.4 + 0.24), 0.0), 28.0) * 0.12;
    color += indigo * exp(-r * 4.0) * 0.08;

    float2 mirrored = float2(abs(q.x), q.y);
    for (int i = 0; i < kStreakCount; i++) {
        float fi = float(i);
        float angle = hashN(fi + 1.0) * 6.2831853;
        float2 direction = float2(abs(cos(angle)), sin(angle));
        float z = fract(hashN(fi + 19.0) + travel * (0.12 + hashN(fi + 53.0) * 0.10));
        float radius = 0.045 + pow(z, 2.8) * 2.1;
        float tail = radius * (0.06 + progress * progress * kStreakLength + o * 1.1);
        float2 a = direction * radius, b = direction * (radius + tail);
        float width = 0.0005 + radius * 0.0008;
        float d = segmentDistance(mirrored, a, b);
        float core = exp(-d * d / (width * width));
        float bloom = exp(-d * 125.0) * 0.07;
        // The prototype's fine streak accent, not RGB separation of the stream
        float splitDistance = segmentDistance(mirrored + float2(kAberration * radius, 0.0), a, b) / (width * 0.8);
        float split = exp(-splitDistance * splitDistance);
        float3 streak = glslMod(fi, 6.0) < 1.0 ? gold : (glslMod(fi, 6.0) > 4.0 ? indigo : cyan);
        float gain = smoothstep(0.04, 0.16, radius) * (1.0 - smoothstep(1.8, 4.0, radius)) * (0.45 + 0.8 * progress);
        color += (streak * (core + bloom) + float3(0.08, 0.015, 0.16) * split) * gain;
    }

    // Unzoomed viewport-periphery light, before cloud occlusion
    float2 framePoint = (uv - kCenter) * float2(aspect, 1.0);
    float edge = smoothstep(0.28, 0.93, length(framePoint));
    float edgeAngle = atan2(framePoint.y, framePoint.x);
    float sweep = pow(0.5 + 0.5 * sin(edgeAngle * 2.0 - t * 0.72), 6.0);
    float counter = pow(0.5 + 0.5 * cos(edgeAngle * 3.0 + t * 0.43 + 1.2), 8.0);
    color += (cyan * sweep + indigo * counter + gold * counter * 0.18) * edge * kEdgeBloom;

    for (int j = 0; j < kCloudCount; j++) {
        // Independent seeds, one jittered angular stratum per puff; deliberately not mirrored
        float f = float(j), seed = hashN(f + 231.0), layer = glslMod(f, 3.0);
        float z = fract(hashN(f + 87.0) + travel * kCloudDrift * (0.6 + layer * 0.22));
        float angle = (f + hashN(f + 141.0)) * 6.2831853 / float(kCloudCount);
        float radius = 0.13 + pow(z, 1.6) * (1.05 + layer * 0.10);
        float2 center = float2(cos(angle), sin(angle)) * radius;
        float size = (0.025 + pow(z, 1.8) * kCloudSize) * (0.70 + layer * 0.45);
        float2 local = (q - center) / float2(size * (1.5 + seed * 0.8), size * (0.7 + seed * 0.35));
        if (dot(local, local) > 12.0) continue;
        local.x += 0.22 * sin(local.y * 2.6 + seed * 11.0) + 0.10 * cos(local.y * 4.1 - seed * 7.0);
        float body = exp(-dot(local, local) * 1.35);
        float2 lobe = local - float2(0.65, -0.24);
        body += 0.55 * exp(-dot(lobe, lobe) * 2.1);
        lobe = local + float2(0.55, 0.28);
        body += 0.38 * exp(-dot(lobe, lobe) * 2.4);
        float detail = 0.72 + 0.28 * sin(local.x * 7.3 + sin(local.y * 6.2 + seed * 13.0) + t * 0.14);
        float billow = (0.52 + 0.48 * sin(local.x * 3.1 + sin(local.y * 3.5 + seed * 9.0) + seed * 17.0)) * detail;
        float pulse = pow(max(0.0, sin(t * (1.35 + seed * 0.55) + seed * 31.0)), 5.0);
        float envelope = pow(max(0.0, sin(z * 3.14159265)), 1.5);
        float density = body * billow * envelope;
        float3 shadow = mix(bg * 0.075, indigo * 0.012, seed);
        float veil = clamp(density * kCloudDensity * (1.35 + pulse * kCloudFlashGain), 0.0, 0.91);
        color = mix(color, shadow, veil);
        float rimOffset = (body - 0.32) * 7.0;
        float rim = exp(-rimOffset * rimOffset) * billow * envelope;
        color += mix(indigo, cyan, seed) * rim * kCloudRim * (0.5 + 0.5 * pulse);
    }

    float throat = 1.0 - smoothstep(0.015, 0.075, r);
    color *= 1.0 - throat * 0.94;
    color *= 1.0 - smoothstep(0.86, 1.5, r) * 0.30;
    // WebGL gl_FragCoord was bottom-up; preserve its grain seed without flipping the tunnel
    float2 grainCoord = float2(position.x, resolution.y - position.y);
    color += float3((hashN(dot(grainCoord, float2(1.0, 31.0))) - 0.5) * 0.002);
    color = pow(max(float3(0.0), 1.0 - exp(-color * kExposure)), float3(kContrast));
    return half4(half3(color * opacity), half(opacity));
}
