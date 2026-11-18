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

// The pyramid the flow reads, in one pass: the luma (Rec. 709 weights) of the stream's RGB picture at level 0, smoothed by a
// 3 × 3 binomial filter (detail near the pixel pitch otherwise aliases in the flow's gradients and samples and biases the
// subpixel motion), and its 2 × 2 box averages at levels 1-3, each 8 × 8 threadgroup reducing its block in threadgroup
// memory. A level's texel only averages pixels inside the picture (levels are rounded down), so the clamped reads past the
// edge are never written.
kernel void videoLumaPyramid(texture2d<float, access::write> luma [[texture(0)]],
                             texture2d<float> source [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]],
                             uint2 local [[thread_position_in_threadgroup]],
                             uint index [[thread_index_in_threadgroup]],
                             uint2 group [[threadgroup_position_in_grid]]) {
    // The block's luma with a one-pixel border, each source pixel read once
    threadgroup float tile[10][10];
    threadgroup float block[8][8];
    int2 size = int2(source.get_width(), source.get_height());
    for (uint i = index; i < 100; i += 64) {
        int2 q = clamp(int2(group * 8) + int2(i % 10, i / 10) - 1, int2(0), size - 1);
        tile[i / 10][i % 10] = dot(source.read(uint2(q)).rgb, float3(0.2126, 0.7152, 0.0722));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float value = 0.0;
    for (uint y = 0; y < 3; y++) for (uint x = 0; x < 3; x++) {
        value += tile[local.y + y][local.x + x] * float((2 - abs(int(x) - 1)) * (2 - abs(int(y) - 1)));
    }
    value /= 16.0;
    if (all(int2(gid) < size)) luma.write(float4(value), gid, 0);
    block[local.y][local.x] = value;
    for (uint lod = 1, span = 4; lod <= 3; lod++, span /= 2) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float average = 0.0;
        if (all(local < uint2(span))) {
            uint2 c = local * 2;
            average = 0.25 * (block[c.y][c.x] + block[c.y][c.x + 1] + block[c.y + 1][c.x] + block[c.y + 1][c.x + 1]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (all(local < uint2(span))) {
            block[local.y][local.x] = average;
            uint2 texel = group * span + local;
            if (all(texel < uint2(luma.get_width(lod), luma.get_height(lod)))) luma.write(float4(average), texel, lod);
        }
    }
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

// The summed absolute luma difference of the cell's 16 samples, `center` moved by `motion`
static float flowCost(texture2d<float> currentLuma, texture2d<float> previousLuma, int2 center, float2 motion, constant FlowUniforms &u) {
    float cost = 0.0;
    for (int y = -3; y <= 3; y += 2) for (int x = -3; x <= 3; x += 2) {
        int2 p = clamp(center + int2(x, y), int2(0), u.levelSize - 1);
        cost += abs(currentLuma.read(uint2(p), uint(u.level)).r - flowPrevious(previousLuma, float2(p) + motion, float2(u.levelSize), u.level));
    }
    return cost;
}

// Pyramidal Lucas-Kanade flow on an 8-pixel grid, from `currentLuma` to `previousLuma`, in the inverse compositional form
// (the current picture's gradients and their matrix once per cell, then only the previous picture per iteration): RG =
// where the cell's centre was in the previous picture, relative to now, in pixels of this level. The coarsest level starts
// from zero motion; every finer one from twice the coarser level's, or from zero motion where that matches the cell better
// (a coarse level that fine detail aliased in must not push the finer ones into a wrong match).
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
        if (flowCost(currentLuma, previousLuma, center, float2(0.0), u) < flowCost(currentLuma, previousLuma, center, motion, u)) {
            motion = float2(0.0);
        }
    }
    float2 levelSize = float2(u.levelSize);
    uint lod = uint(u.level);
    int2 last = u.levelSize - 1;
    float values[16];
    float2 gradients[16];
    float3 matrix = float3(0.0);
    for (int i = 0; i < 16; i++) {
        int2 p = clamp(center + int2((i & 3) * 2 - 3, (i >> 2) * 2 - 3), int2(0), last);
        values[i] = currentLuma.read(uint2(p), lod).r;
        float2 gradient = 0.5 * float2(currentLuma.read(uint2(clamp(p + int2(1, 0), int2(0), last)), lod).r -
                                           currentLuma.read(uint2(clamp(p - int2(1, 0), int2(0), last)), lod).r,
                                       currentLuma.read(uint2(clamp(p + int2(0, 1), int2(0), last)), lod).r -
                                           currentLuma.read(uint2(clamp(p - int2(0, 1), int2(0), last)), lod).r);
        gradients[i] = gradient;
        matrix += float3(gradient.x * gradient.x, gradient.x * gradient.y, gradient.y * gradient.y);
    }
    float determinant = matrix.x * matrix.z - matrix.y * matrix.y;
    if (determinant >= 1e-8) {
        for (int iteration = 0; iteration < 6; iteration++) {
            float2 rhs = float2(0.0);
            for (int i = 0; i < 16; i++) {
                int2 p = clamp(center + int2((i & 3) * 2 - 3, (i >> 2) * 2 - 3), int2(0), last);
                rhs += gradients[i] * (flowPrevious(previousLuma, float2(p) + motion, levelSize, u.level) - values[i]);
            }
            float2 delta = float2(matrix.z * rhs.x - matrix.y * rhs.y, matrix.x * rhs.y - matrix.y * rhs.x) / determinant;
            motion -= delta / max(1.0, length(delta) / 2.0);
            if (dot(delta, delta) < 0.0001) break;
        }
    }
    flowOutput.write(float4(motion, 0.0, 0.0), uint2(cell));
}


// A conservative whole-frame cut detector: the mean luma of 8 × 8 blocks of the two pictures (16 samples of the pyramid's
// coarsest level each, so motion within a block hardly changes it), 1 when the blocks' mean difference is above 0.08. A
// false positive only makes one frame ignore the history; a cut it misses is still caught per pixel by the reactive mask.
kernel void videoSceneChange(texture2d<float, access::write> result [[texture(0)]],
                             texture2d<float> currentLuma [[texture(1)]],
                             texture2d<float> previousLuma [[texture(2)]],
                             uint2 local [[thread_position_in_threadgroup]],
                             uint index [[thread_index_in_threadgroup]]) {
    threadgroup float differences[64];
    float coarsest = float(currentLuma.get_num_mip_levels() - 1);
    float current = 0.0, previous = 0.0;
    for (int i = 0; i < 16; i++) {
        float2 uv = (float2(local) + (float2(i & 3, i >> 2) + 0.5) / 4.0) / 8.0;
        current += currentLuma.sample(pyramidLinear, uv, level(coarsest)).r;
        previous += previousLuma.sample(pyramidLinear, uv, level(coarsest)).r;
    }
    differences[index] = abs(current - previous) / 16.0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        float sum = 0.0;
        for (int i = 0; i < 64; i++) sum += differences[i];
        result.write(float4(sum / 64.0 > 0.08 ? 1.0 : 0.0, 0, 0, 1), uint2(0));
    }
}

static float2 flowUv(float2 uv, float2 inputSize, texture2d<float> flow) {
    return ((uv * inputSize - float2(0.5)) / 8.0) / float2(flow.get_width(), flow.get_height());
}

// The current picture's smoothed luma at a pixel and its four neighbours
struct MotionPatch {
    float values[5];
};

static int2 motionOffset(int i) {
    return int2(int(i == 1) - int(i == 2), int(i == 3) - int(i == 4));
}

// How badly the previous picture, read `motion` away, matches the patch around `p`
static float motionCost(texture2d<float> previousLuma, MotionPatch current, int2 p, float2 motion, int2 inputSize) {
    float cost = 0.0;
    for (int i = 0; i < 5; i++) {
        float2 position = float2(clamp(p + motionOffset(i), int2(0), inputSize - 1)) + motion + 0.5;
        cost += abs(current.values[i] - previousLuma.sample(pyramidLinear, position / float2(inputSize), level(0)).r);
    }
    return cost / 5.0;
}

// Preserve the interpolated flow unless a nearby cell actually matches this pixel's patch better. At a HUD boundary
// interpolation mixes two motions into a third, invalid motion. Zero is a candidate, not the default: it must explain
// high-contrast detail demonstrably better, so flat/noisy video and moving glyphs can still accumulate their history.
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
    float2 grid = flowUv(uv, size, backwardFlow);
    float2 flow = backwardFlow.sample(upscaleLinear, grid, level(0)).xy;
    int2 gridSize = int2(backwardFlow.get_width(), backwardFlow.get_height());
    int2 firstCell = int2(floor(grid * float2(gridSize) - 0.5));
    float2 candidates[4];
    float2 low = flow, high = flow;
    for (int i = 0; i < 4; i++) {
        int2 cell = clamp(firstCell + int2(i & 1, i >> 1), int2(0), gridSize - 1);
        candidates[i] = backwardFlow.read(uint2(cell)).xy;
        low = min(low, candidates[i]);
        high = max(high, candidates[i]);
    }
    if (all(low == float2(0.0)) && all(high == float2(0.0))) {
        // No competing motion: avoid two identical patch comparisons on a still picture.
        float difference = abs(currentLuma.read(uint2(p), 0).r - previousLuma.read(uint2(p), 0).r);
        motionOutput.write(float4(0.0), uint2(p));
        reactiveMask.write(float4(max(smoothstep(0.025, 0.12, difference), sceneChange.read(uint2(0)).r)), uint2(p));
        return;
    }
    MotionPatch current;
    for (int i = 0; i < 5; i++) current.values[i] = currentLuma.read(uint2(clamp(p + motionOffset(i), int2(0), inputSize - 1)), 0).r;
    float2 motion = flow;
    float cost = motionCost(previousLuma, current, p, motion, inputSize);
    float selectedCenter = abs(current.values[0] - previousLuma.sample(pyramidLinear, uv + motion / size, level(0)).r);
    if (length(high - low) > 0.5) {
        for (int i = 0; i < 4; i++) {
            float candidateCost = motionCost(previousLuma, current, p, candidates[i], inputSize);
            float candidateCenter = abs(current.values[0] -
                previousLuma.sample(pyramidLinear, uv + candidates[i] / size, level(0)).r);
            if (candidateCost + 0.003 < cost * 0.8 && candidateCenter <= selectedCenter + 0.003) {
                cost = candidateCost;
                motion = candidates[i];
                selectedCenter = candidateCenter;
            }
        }
    }
    float still = motionCost(previousLuma, current, p, float2(0.0), inputSize);
    float stillCenter = abs(current.values[0] - previousLuma.read(uint2(p), 0).r);
    // A patch crossing an edge must not drag the correctly moving background into its stationary foreground.
    bool stationary = still + 0.003 < cost * 0.8 && stillCenter <= selectedCenter + 0.003;
    if (stationary) motion = float2(0.0);
    motionOutput.write(float4(motion, 0.0, 0.0), uint2(p));
    float reactive;
    if (stationary || all(motion == float2(0.0))) {
        reactive = smoothstep(0.025, 0.12, abs(current.values[0] - previousLuma.read(uint2(p), 0).r));
    } else {
        float2 previousUv = uv + motion / size;
        float2 clamped = clamp(previousUv, float2(0.0), float2(1.0));
        float2 back = flowUv(clamped, size, forwardFlow);
        float2 forward = forwardFlow.sample(upscaleLinear, back, level(0)).xy;
        float disagreement = length(motion + forward);
        // The inverse flow is mixed at the same boundary. Accept an actual neighbouring inverse vector, not an
        // unrelated motion from a wide median; the boundary pass below rejects history where the selected layers meet.
        int2 forwardSize = int2(forwardFlow.get_width(), forwardFlow.get_height());
        int2 forwardCell = int2(floor(back * float2(forwardSize) - 0.5));
        if (disagreement > 0.1) {
            for (int i = 0; i < 4; i++) {
                int2 q = clamp(forwardCell + int2(i & 1, i >> 1), int2(0), forwardSize - 1);
                disagreement = min(disagreement, length(motion + forwardFlow.read(uint2(q)).xy));
            }
        }
        float4 around = previousLuma.gather(upscaleLinear, clamped);
        float outside = max(max(min(min(around.x, around.y), min(around.z, around.w)) - current.values[0],
                                current.values[0] - max(max(around.x, around.y), max(around.z, around.w))), 0.0);
        reactive = max(smoothstep(0.1, 0.5, disagreement), smoothstep(0.025, 0.12, outside));
        if (any(previousUv < float2(0.0)) || any(previousUv > float2(1.0))) reactive = 1.0;
    }
    reactive = max(reactive, sceneChange.read(uint2(0)).r);
    reactiveMask.write(float4(clamp(reactive, 0.0, 1.0)), uint2(p));
}

// Reject a one-pixel footprint at conflicting per-pixel motion layers, where antialiasing mixes foreground and
// background. Do not average/erode the rejection mask: that would reopen rejected history as isolated stippled pixels.
// Contrast gates only this extra boundary rejection; flat/noisy areas retain the original mask and temporal benefit.
kernel void videoReactiveMask(texture2d<float, access::write> reactiveMask [[texture(0)]],
                              texture2d<float> raw [[texture(1)]],
                              texture2d<float> motion [[texture(2)]],
                              texture2d<float> luma [[texture(3)]],
                              uint2 gid [[thread_position_in_grid]],
                              uint2 local [[thread_position_in_threadgroup]],
                              uint index [[thread_index_in_threadgroup]],
                              uint2 group [[threadgroup_position_in_grid]]) {
    threadgroup float2 vectors[10][10];
    threadgroup float values[10][10];
    int2 size = int2(raw.get_width(), raw.get_height());
    for (uint i = index; i < 100; i += 64) {
        int2 q = clamp(int2(group * 8) + int2(i % 10, i / 10) - 1, int2(0), size - 1);
        vectors[i / 10][i % 10] = motion.read(uint2(q)).xy;
        values[i / 10][i % 10] = luma.read(uint2(q), 0).r;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (any(int2(gid) >= size)) return;
    float2 center = vectors[local.y + 1][local.x + 1];
    float low = values[local.y + 1][local.x + 1], high = low, difference = 0.0;
    for (uint y = 0; y < 3; y++) for (uint x = 0; x < 3; x++) {
        float value = values[local.y + y][local.x + x];
        low = min(low, value);
        high = max(high, value);
        difference = max(difference, length(center - vectors[local.y + y][local.x + x]));
    }
    float boundary = smoothstep(0.25, 0.75, difference) * smoothstep(0.04, 0.12, high - low);
    reactiveMask.write(float4(max(raw.read(gid).r, boundary)), gid);
}
