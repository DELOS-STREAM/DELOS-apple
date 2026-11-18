#include <metal_stdlib>
using namespace metal;

// The upscaler's own passes around MetalFX (MetalUpscaler.swift): the contrast-adaptive sharpen of Sharpen only and of
// the MetalFX modes' presentation, and for MetalFX Temporal the motion of decoded video, which has no renderer's motion
// vectors: a luma pyramid, pyramidal optical flow on an 8-pixel grid, a whole-frame cut detector, and the per-pixel motion
// and reactive mask textures the temporal scaler reads. Every pass works in texel index space (row 0 of a texture is row 0
// of its picture, y down), as MetalFX's motion vectors do. MetalUpscaler (Swift) fills the uniforms; keep the two in step.

struct VideoVertex {
    float4 position [[position]];
    float2 coordinate;
};

constexpr sampler upscaleLinear(filter::linear, address::clamp_to_edge);

// MARK: Contrast-adaptive sharpen

struct CASUniforms {
    // 1 / width, 1 / height of the sampled texture: the distance of the cross's samples
    float2 texelSize;
    // The sharpness, 0-1; 0 samples the picture unchanged
    float strength;
};

// FidelityFX CAS (MIT, AMD) on the five-sample cross at a scale factor of 1, per channel, in the encoded domain (SDR
// gamma, or HDR's PQ/HLG values as decoded). Sharpen only runs it at the stream's size; the MetalFX modes run it while
// sampling the scaler's output into the picture's place on the view.
fragment float4 casFragment(VideoVertex in [[stage_in]],
                            texture2d<float> ps0 [[texture(0)]],
                            constant CASUniforms &u [[buffer(0)]]) {
    float2 uv = in.coordinate, stepSize = u.texelSize;
    float3 e = ps0.sample(upscaleLinear, uv, level(0)).rgb;
    float3 result = e;
    if (u.strength > 0.0) {
        float3 b = ps0.sample(upscaleLinear, uv - float2(0, stepSize.y), level(0)).rgb;
        float3 d = ps0.sample(upscaleLinear, uv - float2(stepSize.x, 0), level(0)).rgb;
        float3 f = ps0.sample(upscaleLinear, uv + float2(stepSize.x, 0), level(0)).rgb;
        float3 h = ps0.sample(upscaleLinear, uv + float2(0, stepSize.y), level(0)).rgb;
        float3 mn = min(min(min(d, e), min(f, b)), h);
        float3 mx = max(max(max(d, e), max(f, b)), h);
        float3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, float3(1e-4)), 0.0, 1.0));
        // 1/5 is CAS's strongest peak; the square root keeps 50 % close to CAS's default of 0.154
        float3 w = -amp * (0.2 * sqrt(clamp(u.strength, 0.0, 1.0)));
        result = clamp(((b + d + f + h) * w + e) / (1.0 + 4.0 * w), 0.0, 1.0);
    }
    return float4(result, 1.0);
}

// MARK: Motion of decoded video (MetalFX Temporal's inputs)

// The luma (Rec. 709 weights) of the stream's RGB picture: level 0 of the pyramid the flow reads
fragment float4 videoLumaFragment(VideoVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float3 c = source.sample(upscaleLinear, in.coordinate, level(0)).rgb;
    return float4(dot(c, float3(0.2126, 0.7152, 0.0722)), 0, 0, 1);
}

struct FlowUniforms {
    int level;
    int coarsest;
    int2 levelSize;
};

// Bilinear within one pyramid level, the level chosen by the caller
constexpr sampler pyramidLinear(filter::linear, mip_filter::nearest, address::clamp_to_edge);

// The previous picture at `position` (pixels of the pyramid level `lod`), from that level, as the current picture is read
static float flowPrevious(texture2d<float> previousLuma, float2 position, float2 levelSize, int lod) {
    return previousLuma.sample(pyramidLinear, (position + 0.5) / levelSize, level(float(lod))).r;
}

// Pyramidal Lucas-Kanade flow on an 8-pixel grid, from `currentLuma` to `previousLuma`: RG = where the cell's centre was in
// the previous picture, relative to now, in pixels of this level; B = residual; A = confidence. The coarsest level starts
// from zero motion, every finer one from twice the coarser level's.
kernel void videoFlow(texture2d<float, access::write> flowOutput [[texture(0)]],
                      texture2d<float> currentLuma [[texture(1)]],
                      texture2d<float> previousLuma [[texture(2)]],
                      texture2d<float> coarseFlow [[texture(3)]],
                      constant FlowUniforms &u [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    int2 cell = int2(gid);
    if (any(cell >= int2(flowOutput.get_width(), flowOutput.get_height()))) return;
    int2 center = min(cell * 8 + int2(4), u.levelSize - 1);
    float2 motion = float2(0.0);
    if (u.coarsest == 0) {
        // Grid centers are at 4,12,..., rather than at uniformly stretched image boundaries.
        float2 parentPixel = (float2(center) + 0.5) * 0.5 - 0.5;
        float2 gridUv = (parentPixel / 8.0) / float2(coarseFlow.get_width(), coarseFlow.get_height());
        motion = coarseFlow.sample(upscaleLinear, gridUv, level(0)).xy * 2.0;
    }
    float2 levelSize = float2(u.levelSize);
    float residual = 0.0, quality = 0.0;
    for (int iteration = 0; iteration < 6; iteration++) {
        float3 matrix = float3(0.0);
        float2 rhs = float2(0.0);
        residual = 0.0;
        for (int y = -3; y <= 3; y += 2) for (int x = -3; x <= 3; x += 2) {
            int2 p = clamp(center + int2(x, y), int2(0), u.levelSize - 1);
            float2 q = float2(p) + motion;
            float value = flowPrevious(previousLuma, q, levelSize, u.level);
            float2 gradient = 0.5 * float2(flowPrevious(previousLuma, q + float2(1, 0), levelSize, u.level) - flowPrevious(previousLuma, q - float2(1, 0), levelSize, u.level),
                                           flowPrevious(previousLuma, q + float2(0, 1), levelSize, u.level) - flowPrevious(previousLuma, q - float2(0, 1), levelSize, u.level));
            float difference = currentLuma.read(uint2(p), uint(u.level)).r - value;
            matrix += float3(gradient.x * gradient.x, gradient.x * gradient.y, gradient.y * gradient.y);
            rhs += gradient * difference;
            residual += abs(difference);
        }
        float determinant = matrix.x * matrix.z - matrix.y * matrix.y;
        quality = determinant / max((matrix.x + matrix.z) * (matrix.x + matrix.z), 1e-10);
        if (determinant < 1e-8) break;
        float2 delta = float2(matrix.z * rhs.x - matrix.y * rhs.y, matrix.x * rhs.y - matrix.y * rhs.x) / determinant;
        motion += delta / max(1.0, length(delta) / 2.0);
        if (dot(delta, delta) < 0.0001) break;
    }
    residual /= 16.0;
    float2 position = float2(center) + motion;
    float valid = all(position >= float2(0)) && all(position < levelSize) ? 1.0 : 0.0;
    flowOutput.write(float4(motion, residual, valid * smoothstep(0.001, 0.025, quality) * exp(-32.0 * residual)), uint2(cell));
}

// A conservative whole-frame cut detector on an 8 × 8 grid of the two pictures: 1 when the mean luma difference is above
// 0.12. A false positive only makes one frame ignore the history.
kernel void videoSceneChange(texture2d<float, access::write> result [[texture(0)]],
                             texture2d<float> currentLuma [[texture(1)]],
                             texture2d<float> previousLuma [[texture(2)]],
                             uint2 local [[thread_position_in_threadgroup]],
                             uint index [[thread_index_in_threadgroup]]) {
    threadgroup float differences[64];
    float2 uv = (float2(local) + 0.5) / 8.0;
    differences[index] = abs(currentLuma.sample(upscaleLinear, uv, level(0)).r - previousLuma.sample(upscaleLinear, uv, level(0)).r);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        float sum = 0.0;
        for (int i = 0; i < 64; i++) sum += differences[i];
        result.write(float4(sum / 64.0 > 0.12 ? 1.0 : 0.0, 0, 0, 1), uint2(0));
    }
}

static float2 flowUv(float2 uv, float2 inputSize, texture2d<float> flow) {
    return ((uv * inputSize - float2(0.5)) / 8.0) / float2(flow.get_width(), flow.get_height());
}

// MetalFX Temporal's per-pixel inputs at the stream's size. Motion (RG): the backward flow sampled at the pixel, which is
// where the pixel was in the previous picture minus where it is now, in pixels: MetalFX's convention with a motion vector
// scale of 1 (an object that moved 10 pixels right and down has (-10, -10)). Reactive mask (R): 1 tells MetalFX to ignore
// the history at the pixel; it is high where the flow is unsure (low confidence, backward and forward flow disagree, the
// luma does not match where the flow points, the previous position is outside the picture), and 1 everywhere on a cut.
kernel void videoMotion(texture2d<float, access::write> motionOutput [[texture(0)]],
                        texture2d<float, access::write> reactiveMask [[texture(1)]],
                        texture2d<float> currentLuma [[texture(2)]],
                        texture2d<float> previousLuma [[texture(3)]],
                        texture2d<float> backwardFlow [[texture(4)]],
                        texture2d<float> forwardFlow [[texture(5)]],
                        texture2d<float> sceneChange [[texture(6)]],
                        constant int2 &inputSize [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    if (any(p >= inputSize)) return;
    float2 size = float2(inputSize);
    float2 uv = (float2(p) + 0.5) / size;
    float4 backward = backwardFlow.sample(upscaleLinear, flowUv(uv, size, backwardFlow), level(0));
    motionOutput.write(float4(backward.xy, 0.0, 0.0), uint2(p));
    float2 previousUv = uv + backward.xy / size;
    float4 forward = forwardFlow.sample(upscaleLinear, flowUv(clamp(previousUv, float2(0.0), float2(1.0)), size, forwardFlow), level(0));
    float consistency = length(backward.xy + forward.xy);
    float current = currentLuma.read(uint2(p), 0).r;
    float previous = previousLuma.sample(upscaleLinear, clamp(previousUv, float2(0.0), float2(1.0)), level(0)).r;
    float residual = abs(current - previous);
    float invalid = 1.0 - min(backward.w, forward.w);
    float reactive = max(invalid, smoothstep(0.75, 2.5, consistency));
    reactive = max(reactive, smoothstep(0.025, 0.12, residual));
    if (any(previousUv < float2(0.0)) || any(previousUv > float2(1.0))) reactive = 1.0;
    reactive = max(reactive, sceneChange.read(uint2(0)).r);
    reactiveMask.write(float4(clamp(reactive, 0.0, 1.0)), uint2(p));
}
