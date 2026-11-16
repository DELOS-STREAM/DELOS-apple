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
