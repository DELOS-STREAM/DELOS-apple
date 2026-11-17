#include <metal_stdlib>
using namespace metal;

// Draws a decoded two-plane 4:2:0 picture: Y' in an r8 / r16 texture, CbCr in an rg8 / rg16 texture at half size.
// ColorConversion.uniforms (Swift) fills `VideoUniforms`; keep the two in step.

struct VideoUniforms {
    float4 column0;
    float4 column1;
    float4 column2;
    // luma offset, luma scale, chroma offset, chroma scale
    float4 range;
    // x: 0 SDR, 1 PQ, 2 HLG
    float4 transfer;
};

struct VideoVertex {
    float4 position [[position]];
    float2 coordinate;
};

// One triangle that covers the viewport; the viewport is the aspect-fitted rectangle of the picture.
vertex VideoVertex videoVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    VideoVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.coordinate = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 videoFragment(VideoVertex in [[stage_in]],
                              texture2d<float> luma [[texture(0)]],
                              texture2d<float> chroma [[texture(1)]],
                              constant VideoUniforms &u [[buffer(0)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float y = (luma.sample(linearClamp, in.coordinate).r - u.range.x) * u.range.y;
    float2 cbcr = (chroma.sample(linearClamp, in.coordinate).rg - u.range.z) * u.range.w;
    float3 yuv = float3(y, cbcr);
    float3 rgb = u.column0.xyz * yuv.x + u.column1.xyz * yuv.y + u.column2.xyz * yuv.z;
    // The transfer function stays as encoded (u.transfer.x tells which one it is): the layer's colour space tag makes
    // the system match it to the display. HDR tone mapping and linearising for upscalers start here.
    return float4(saturate(rgb), 1.0);
}

// The stream's arrival at the end of the launch scene (arrival.frag of DELOS for Android, line by line): the converted
// picture is in `source` with its mip levels; the pose zooms, skews and waves it, the blur reads a mip level and the
// RGB split samples the channels apart. ArrivalUniforms (Swift, LaunchArrival.swift) fills `ArrivalUniforms`; keep the
// two in step.
struct ArrivalUniforms {
    // scale x, scale y, skew, warp
    float4 pose;
    // blur, chromatic (source pixels)
    float2 effects;
    float2 sourceSize;
    float2 presentationSize;
};

static float3 arrivalFiltered(texture2d<float> source, constant ArrivalUniforms &u, float2 p) {
    constexpr sampler trilinearClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // Texture coordinates are top-left here, as the pose's: no flip
    p = clamp(p, 0.5 / u.sourceSize, 1.0 - 0.5 / u.sourceSize);
    float pixelScale = max(u.presentationSize.x / u.sourceSize.x, u.presentationSize.y / u.sourceSize.y);
    return source.sample(trilinearClamp, p, level(log2(1.0 + u.effects.x * pixelScale))).rgb;
}

fragment float4 arrivalFragment(VideoVertex in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant ArrivalUniforms &u [[buffer(0)]]) {
    float2 p = in.coordinate - 0.5;
    p.y -= p.x * u.pose.z;
    p /= u.pose.xy;
    p += float2(sin(p.y * 8.0) * cos(p.x * 3.0), sin(p.x * 7.0) * cos(p.y * 3.0)) * u.pose.w * 0.45 / u.sourceSize;
    p += 0.5;
    float3 rgb;
    if (u.effects.y < 0.05) {
        rgb = arrivalFiltered(source, u, p);
    } else {
        float2 split = float2(1.0, 0.2) * u.effects.y / u.sourceSize;
        rgb = float3(arrivalFiltered(source, u, p - split).r, arrivalFiltered(source, u, p).g,
                     arrivalFiltered(source, u, p + split).b);
    }
    return float4(rgb, 1.0);
}
