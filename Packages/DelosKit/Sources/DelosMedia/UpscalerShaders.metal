#include <metal_stdlib>
using namespace metal;

// The upscalers of DELOS for Android (app/src/main/assets/sgsr/*.frag, *.comp), ported line by line from GLSL ES 3.1.
// Every pass works in texel index space (row 0 of a texture is row 0 of its picture), as the GLSL does, so the
// textures' top-left origin here and the bottom-left origin there give the same pixels. GL samples the luma pyramid
// with a non-mipmapped LINEAR minification filter, which reads the base level whatever lod textureLod asks for; the ports
// sample level 0 where the GLSL passes a lod, and read the mip level where it uses texelFetch. MetalUpscaler (Swift) fills
// the uniforms; keep the two in step.

struct VideoVertex {
    float4 position [[position]];
    float2 coordinate;
};

// ViewportInfo[0] of the GLSL: 1 / sampled width, 1 / sampled height, stream width, stream height.
struct UpscaleUniforms {
    float4 viewportInfo;
    // sgsrStrength (the sharpness, 0-1)
    float strength;
    // sgsrEnabled: reconstruction on (the output is at least the source's size)
    int enabled;
};

constexpr sampler upscaleLinear(filter::linear, address::clamp_to_edge);

// MARK: SGSR 1, Standard (sgsr1.frag; Qualcomm snapdragon-gsr d926f074, BSD-3-Clause)

static float sgsrFastLanczos2(float x) {
    float wA = x - 4.0;
    float wB = x * wA - wA;
    wA *= wA;
    return wB * wA;
}

static float2 sgsrWeightY(float dx, float dy, float c, float3 data) {
    float std = data.x;
    float2 dir = data.yz;
    float edgeDis = ((dx * dir.y) + (dy * dir.x));
    float x = (((dx * dx) + (dy * dy)) + ((edgeDis * edgeDis) * ((clamp(((c * c) * std), 0.0, 1.0) * 0.7) + -1.0)));
    float w = sgsrFastLanczos2(x);
    return float2(w, w * c);
}

static float2 sgsrEdgeDirection(float4 left, float4 right) {
    float RxLz = (right.x + (-left.z));
    float RwLy = (right.w + (-left.y));
    float2 delta = float2(RxLz + RwLy, RxLz + (-RwLy));
    float lengthInv = rsqrt((delta.x * delta.x + 3.075740e-05) + (delta.y * delta.y));
    return delta * lengthInv;
}

fragment float4 sgsr1Fragment(VideoVertex in [[stage_in]],
                              texture2d<float> ps0 [[texture(0)]],
                              constant UpscaleUniforms &u [[buffer(0)]]) {
    // OperationMode 1 (RGBA): the green channel stands for the luma
    float2 uv = in.coordinate;
    float4 color = float4(ps0.sample(upscaleLinear, uv, level(0)).xyz, 0.0);
    if (u.enabled != 0) {
        float2 imgCoord = ((uv * u.viewportInfo.zw) + float2(-0.5, 0.5));
        float2 imgCoordPixel = floor(imgCoord);
        float2 coord = (imgCoordPixel * u.viewportInfo.xy);
        float2 pl = (imgCoord + (-imgCoordPixel));
        float4 left = ps0.gather(upscaleLinear, coord, int2(0), component::y);
        float edgeVote = abs(left.z - left.y) + abs(color.y - left.y) + abs(color.y - left.z);
        if (edgeVote > 8.0 / 255.0) {
            coord.x += u.viewportInfo.x;
            float4 right = ps0.gather(upscaleLinear, coord + float2(u.viewportInfo.x, 0.0), int2(0), component::y);
            float4 upDown;
            upDown.xy = ps0.gather(upscaleLinear, coord + float2(0.0, -u.viewportInfo.y), int2(0), component::y).wz;
            upDown.zw = ps0.gather(upscaleLinear, coord + float2(0.0, u.viewportInfo.y), int2(0), component::y).yx;
            float mean = (left.y + left.z + right.x + right.w) * 0.25;
            left = left - float4(mean);
            right = right - float4(mean);
            upDown = upDown - float4(mean);
            color.w = color.y - mean;
            float sum = (((((abs(left.x) + abs(left.y)) + abs(left.z)) + abs(left.w)) + (((abs(right.x) + abs(right.y)) + abs(right.z)) + abs(right.w))) + (((abs(upDown.x) + abs(upDown.y)) + abs(upDown.z)) + abs(upDown.w)));
            float sumMean = 1.014185e+01 / sum;
            float std = (sumMean * sumMean);
            float3 data = float3(std, sgsrEdgeDirection(left, right));
            float2 aWY = sgsrWeightY(pl.x, pl.y + 1.0, upDown.x, data);
            aWY += sgsrWeightY(pl.x - 1.0, pl.y + 1.0, upDown.y, data);
            aWY += sgsrWeightY(pl.x - 1.0, pl.y - 2.0, upDown.z, data);
            aWY += sgsrWeightY(pl.x, pl.y - 2.0, upDown.w, data);
            aWY += sgsrWeightY(pl.x + 1.0, pl.y - 1.0, left.x, data);
            aWY += sgsrWeightY(pl.x, pl.y - 1.0, left.y, data);
            aWY += sgsrWeightY(pl.x, pl.y, left.z, data);
            aWY += sgsrWeightY(pl.x + 1.0, pl.y, left.w, data);
            aWY += sgsrWeightY(pl.x - 1.0, pl.y - 1.0, right.x, data);
            aWY += sgsrWeightY(pl.x - 2.0, pl.y - 1.0, right.y, data);
            aWY += sgsrWeightY(pl.x - 2.0, pl.y, right.z, data);
            aWY += sgsrWeightY(pl.x - 1.0, pl.y, right.w, data);
            float finalY = aWY.y / aWY.x;
            float maxY = max(max(left.y, left.z), max(right.x, right.w));
            float minY = min(min(left.y, left.z), min(right.x, right.w));
            float deltaY = clamp(2.0 * finalY, minY, maxY) - color.w;
            // Smooth high contrast input
            deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);
            color.xyz = clamp(color.xyz + deltaY, 0.0, 1.0);
        }
    }
    return float4(color.xyz, 1.0);
}

// MARK: SGSR 1, High (sgsr1_high.frag; Qualcomm Unity SGSR 1 ab685c99, SGSR_TARGET_HIGH_QUALITY, BSD-3-Clause)

static float4 sgsrHighWeightY(float dx, float dy, float c, float2 dir, float std) {
    float dxy2 = (dx * dx) + (dy * dy);
    float c2std = c * c * std;
    float dc = exp(c2std);
    float ds = sqrt(dxy2);
    float edgeDis = ((dx * dir.y) + (dy * dir.x));
    edgeDis *= edgeDis;
    float x1 = dxy2 + (edgeDis * (saturate(c2std * -2.8) * 0.7 + -1.0));
    float w1 = sgsrFastLanczos2(x1);
    float x2 = (ds * 0.54 + 0.36) - dc * 0.36;
    float w2 = sgsrFastLanczos2(x2);
    return float4(w1 * c, w1, w2 * c, w2);
}

static float2 sgsrHighPass(float4 left, float4 right, float4 upDown, float2 pl) {
    float sum2 = left.x * left.x + left.y * left.y + left.z * left.z + left.w * left.w +
        right.x * right.x + right.y * right.y + right.z * right.z + right.w * right.w +
        upDown.x * upDown.x + upDown.y * upDown.y + upDown.z * upDown.z + upDown.w * upDown.w;
    float std2 = -6.0 / max(sum2, 1e-8);
    float2 dir = sgsrEdgeDirection(left, right);
    float4 aYW = sgsrHighWeightY(pl.x, pl.y + 1.0, upDown.x, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 1.0, pl.y + 1.0, upDown.y, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 1.0, pl.y - 2.0, upDown.z, dir, std2);
    aYW += sgsrHighWeightY(pl.x, pl.y - 2.0, upDown.w, dir, std2);
    aYW += sgsrHighWeightY(pl.x + 1.0, pl.y - 1.0, left.x, dir, std2);
    aYW += sgsrHighWeightY(pl.x + 1.0, pl.y, left.w, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 2.0, pl.y - 1.0, right.y, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 2.0, pl.y, right.z, dir, std2);
    aYW += sgsrHighWeightY(pl.x, pl.y - 1.0, left.y, dir, std2);
    aYW += sgsrHighWeightY(pl.x, pl.y, left.z, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 1.0, pl.y - 1.0, right.x, dir, std2);
    aYW += sgsrHighWeightY(pl.x - 1.0, pl.y, right.w, dir, std2);
    return float2(aYW.x / aYW.y, aYW.z / aYW.w);
}

static float4 sgsrGatherLuma(texture2d<float> ps0, float2 coord) {
    return ps0.gather(upscaleLinear, coord, int2(0), component::x) * 0.299
        + ps0.gather(upscaleLinear, coord, int2(0), component::y) * 0.587
        + ps0.gather(upscaleLinear, coord, int2(0), component::z) * 0.114;
}

fragment float4 sgsr1HighFragment(VideoVertex in [[stage_in]],
                                  texture2d<float> ps0 [[texture(0)]],
                                  constant UpscaleUniforms &u [[buffer(0)]]) {
    float2 uv = in.coordinate;
    float4 pix = ps0.sample(upscaleLinear, uv, level(0));
    if (u.enabled != 0) {
        float4 con1 = u.viewportInfo;
        float2 imgCoord = ((uv * con1.zw) + float2(-0.5, 0.5));
        float2 imgCoordPixel = floor(imgCoord);
        float2 coord = (imgCoordPixel * con1.xy);
        float2 pl = (imgCoord + (-imgCoordPixel));
        float4 left = sgsrGatherLuma(ps0, coord);
        pix.w = pix.x * 0.299 + pix.y * 0.587 + pix.z * 0.114;
        float edgeVote = abs(left.z - left.y) + abs(pix.w - left.y) + abs(pix.w - left.z);
        if (edgeVote > 4.0 / 255.0) {
            coord.x += con1.x;
            float4 right = sgsrGatherLuma(ps0, coord + float2(con1.x, 0.0));
            float4 upDown;
            upDown.xy = sgsrGatherLuma(ps0, coord + float2(0.0, -con1.y)).wz;
            upDown.zw = sgsrGatherLuma(ps0, coord + float2(0.0, con1.y)).yx;
            float mean = ((((left.y + left.z) + right.x) + right.w) * 0.25);
            left = left - float4(mean);
            right = right - float4(mean);
            upDown = upDown - float4(mean);
            pix.w = pix.w - mean;
            float2 y2 = sgsrHighPass(left, right, upDown, pl);
            float maxY = max(max(left.y, left.z), max(right.x, right.w));
            float minY = min(min(left.y, left.z), min(right.x, right.w));
            float edgeY = clamp(2.0 * y2.x, minY, maxY);
            float smoothY = clamp(2.0 * y2.y, minY, maxY);
            float deltaY = (smoothY * 0.4 - pix.w) + (edgeY * 0.6);
            pix.xyz = saturate(pix.xyz + deltaY);
        }
    }
    return float4(pix.xyz, 1.0);
}

// MARK: Presentation passes (Delos, GPL-3.0-or-later)

// The four neighbours of `uv`, `step` apart, and the bounded sharpen of supersample_present.frag / temporal_present.frag.
static float3 boundedSharpen(texture2d<float> ps0, float2 uv, float2 step, float gain) {
    float3 center = ps0.sample(upscaleLinear, uv, level(0)).rgb;
    float3 left = ps0.sample(upscaleLinear, uv - float2(step.x, 0), level(0)).rgb;
    float3 right = ps0.sample(upscaleLinear, uv + float2(step.x, 0), level(0)).rgb;
    float3 down = ps0.sample(upscaleLinear, uv - float2(0, step.y), level(0)).rgb;
    float3 up = ps0.sample(upscaleLinear, uv + float2(0, step.y), level(0)).rgb;
    float3 low = min(center, min(min(left, right), min(down, up)));
    float3 high = max(center, max(max(left, right), max(down, up)));
    float3 limit = min(float3(0.06), (high - low) * 0.25);
    float3 detail = center - (left + right + down + up) * 0.25;
    return clamp(center + clamp(detail * gain, -limit, limit), 0.0, 1.0);
}

// SGSR 1's final resolve with its independent bounded sharpening (supersample_present.frag)
fragment float4 supersamplePresentFragment(VideoVertex in [[stage_in]],
                                           texture2d<float> ps0 [[texture(0)]],
                                           constant UpscaleUniforms &u [[buffer(0)]]) {
    float2 uv = in.coordinate;
    if (u.strength > 0.0) return float4(boundedSharpen(ps0, uv, u.viewportInfo.xy, u.strength * 0.375), 1.0);
    return float4(ps0.sample(upscaleLinear, uv, level(0)).rgb, 1.0);
}

// SGSR 2's presentation-only sharpening: never accumulated into history (temporal_present.frag)
fragment float4 temporalPresentFragment(VideoVertex in [[stage_in]],
                                        texture2d<float> ps0 [[texture(0)]],
                                        constant UpscaleUniforms &u [[buffer(0)]]) {
    return float4(boundedSharpen(ps0, in.coordinate, u.viewportInfo.xy, u.strength * 0.75), 1.0);
}

// Sharpen only (sharpen_only.frag): FidelityFX CAS (MIT, AMD) on the five-sample cross at a scale factor of 1, per
// channel, in the encoded domain. sgsrStrength 0 returns the pixel unchanged.
fragment float4 sharpenOnlyFragment(VideoVertex in [[stage_in]],
                                    texture2d<float> ps0 [[texture(0)]],
                                    constant UpscaleUniforms &u [[buffer(0)]]) {
    float2 uv = in.coordinate, stepSize = u.viewportInfo.xy;
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

// MARK: SGSR 2 adapted to video (SgsrTemporal.java and its passes)

// The LUMA pass of SgsrTemporal.java
fragment float4 sgsrLumaFragment(VideoVertex in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    float3 c = source.sample(upscaleLinear, in.coordinate, level(0)).rgb;
    return float4(dot(c, float3(0.2126, 0.7152, 0.0722)), 0, 0, 1);
}

struct FlowUniforms {
    int level;
    int coarsest;
    int2 levelSize;
};

static float flowPrevious(texture2d<float> previousLuma, float2 position, float2 levelSize) {
    return previousLuma.sample(upscaleLinear, (position + 0.5) / levelSize, level(0)).r;
}

// video_flow.comp: pyramidal Lucas-Kanade backward flow on an 8-pixel grid, current -> previous
kernel void sgsrFlow(texture2d<float, access::write> flowOutput [[texture(0)]],
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
            float value = flowPrevious(previousLuma, q, levelSize);
            float2 gradient = 0.5 * float2(flowPrevious(previousLuma, q + float2(1, 0), levelSize) - flowPrevious(previousLuma, q - float2(1, 0), levelSize),
                                           flowPrevious(previousLuma, q + float2(0, 1), levelSize) - flowPrevious(previousLuma, q - float2(0, 1), levelSize));
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

// scene_change.comp: conservative whole-frame cut detection; a false positive only resets the history
kernel void sgsrSceneChange(texture2d<float, access::write> result [[texture(0)]],
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

static float2 sgsrFlowUv(float2 uv, float2 inputSize, texture2d<float> flow) {
    return ((uv * inputSize - float2(0.5)) / 8.0) / float2(flow.get_width(), flow.get_height());
}

// video_activate.comp: flow confidence, forward/backward consistency and the luma residual mark disocclusions
kernel void sgsrActivate(texture2d<float, access::write> reactiveMask [[texture(0)]],
                         texture2d<float> currentLuma [[texture(1)]],
                         texture2d<float> previousLuma [[texture(2)]],
                         texture2d<float> backwardFlow [[texture(3)]],
                         texture2d<float> forwardFlow [[texture(4)]],
                         constant int2 &inputSize [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    if (any(p >= inputSize)) return;
    float2 size = float2(inputSize);
    float2 uv = (float2(p) + 0.5) / size;
    float4 backward = backwardFlow.sample(upscaleLinear, sgsrFlowUv(uv, size, backwardFlow), level(0));
    float2 previousUv = uv + backward.xy / size;
    float4 forward = forwardFlow.sample(upscaleLinear, sgsrFlowUv(clamp(previousUv, float2(0.0), float2(1.0)), size, backwardFlow), level(0));
    float consistency = length(backward.xy + forward.xy);
    float current = currentLuma.read(uint2(p), 0).r;
    float previous = previousLuma.sample(upscaleLinear, clamp(previousUv, float2(0.0), float2(1.0)), level(0)).r;
    float residual = abs(current - previous);
    float invalid = 1.0 - min(backward.w, forward.w);
    float reactive = max(invalid, smoothstep(0.75, 2.5, consistency));
    reactive = max(reactive, smoothstep(0.025, 0.12, residual));
    if (any(previousUv < float2(0.0)) || any(previousUv > float2(1.0))) reactive = 1.0;
    reactiveMask.write(float4(clamp(reactive, 0.0, 1.0)), uint2(p));
}

struct TemporalUniforms {
    float2 renderSize;
    float2 outputSize;
    float2 renderSizeRcp;
    float2 scaleRatio;
    float reset;
    int qualityMode;
};

static float sgsrFastLanczos(float base) {
    float y = base - 1.0;
    float y2 = y * y;
    float y_temp = 0.75 * y + y2;
    return y_temp * y2;
}

static float3 rgbToYCoCg(float3 c) { return float3(c.r * 0.25 + c.g * 0.5 + c.b * 0.25, c.r * 0.5 - c.b * 0.5, -c.r * 0.25 + c.g * 0.5 - c.b * 0.25); }
static float3 yCoCgToRgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }

// One tap of the 3 × 3 neighbourhood: the Lanczos upsample and the colour box (sgsr2_video.frag's repeated blocks)
static void sgsrTap(float3 samplecolor, float2 baseoffset, float kernelbias2, float curvebias, thread float4 &upsampled,
                    thread float3 &boxcenter, thread float3 &boxvar, thread float &boxweight, thread float3 &boxmin,
                    thread float3 &boxmax, bool first) {
    float baseoffset_dot = dot(baseoffset, baseoffset);
    float base = clamp(baseoffset_dot * kernelbias2, 0.0, 1.0);
    float weight = sgsrFastLanczos(base);
    upsampled += float4(samplecolor * weight, weight);
    float bw = exp(baseoffset_dot * curvebias);
    if (first) {
        boxmin = samplecolor;
        boxmax = samplecolor;
    } else {
        boxmin = min(boxmin, samplecolor);
        boxmax = max(boxmax, samplecolor);
    }
    float3 wsample = samplecolor * bw;
    boxcenter += wsample;
    boxvar += (samplecolor * wsample);
    boxweight += bw;
}

static float4 sgsrFetch(texture2d<float> input, int2 p, int2 last) {
    return input.read(uint2(clamp(p, int2(0), last)), 0);
}

// sgsr2_video.frag (Qualcomm SGSR 2, BSD-3-Clause, with Delos's video adaptation: total optical flow, confidence
// rejection, zero engine jitter)
fragment float4 sgsr2VideoFragment(VideoVertex in [[stage_in]],
                                   texture2d<float> InputColor [[texture(0)]],
                                   texture2d<float> PrevOutput [[texture(1)]],
                                   texture2d<float> MotionDepthClipAlphaBuffer [[texture(2)]],
                                   texture2d<float> ForwardFlow [[texture(3)]],
                                   texture2d<float> SceneChange [[texture(4)]],
                                   texture2d<float> ReactiveMask [[texture(5)]],
                                   constant TemporalUniforms &u [[buffer(0)]]) {
    float scalefactor = u.scaleRatio.y;
    float2 Hruv = in.coordinate;
    float2 Jitteruv = clamp(Hruv, 0.0, 1.0);
    int2 InputPos = int2(Jitteruv * u.renderSize);
    int2 last = int2(u.renderSize) - 1;

    // RG = current-to-previous source-pixel flow; B = residual; A = confidence.
    float4 backward = MotionDepthClipAlphaBuffer.sample(upscaleLinear, sgsrFlowUv(Jitteruv, u.renderSize, MotionDepthClipAlphaBuffer), level(0));
    float2 rawPrevious = Jitteruv + backward.xy * u.renderSizeRcp;
    float4 forward = ForwardFlow.sample(upscaleLinear, sgsrFlowUv(rawPrevious, u.renderSize, MotionDepthClipAlphaBuffer), level(0));
    float consistency = length(backward.xy + forward.xy);
    float confidence = min(backward.w, forward.w) * exp(-consistency * 1.5);
    if (any(rawPrevious < float2(0.0)) || any(rawPrevious > float2(1.0))) confidence = 0.0;
    float frameReset = max(u.reset, SceneChange.sample(upscaleLinear, float2(0.5), level(0)).r);
    float3 mda = float3(-2.0 * backward.xy * u.renderSizeRcp, 1.0 - confidence);
    float2 Motion = mda.xy;

    float2 PrevUV = clamp(-0.5 * Motion + Hruv, 0.0, 1.0);
    float depthfactor = mda.z;
    float3 HistoryColor = PrevOutput.sample(upscaleLinear, PrevUV, level(0)).xyz;

    float4 Upsampledcw = float4(0.0);
    // Decoded video has zero engine jitter: a fixed source-pixel Lanczos footprint
    float kernelbias = 1.0;
    float motion_viewport_len = length(Motion * u.outputSize);
    float curvebias = mix(-2.0, -3.0, clamp(motion_viewport_len * 0.02, 0.0, 1.0));

    float3 rectboxcenter = float3(0.0);
    float3 rectboxvar = float3(0.0);
    float rectboxweight = 0.0;
    float2 srcpos = float2(InputPos) + float2(0.5);
    kernelbias *= 0.5;
    float kernelbias2 = kernelbias * kernelbias;
    float2 srcpos_srcOutputPos = srcpos - Hruv * u.renderSize;
    float3 rectboxmin = float3(0.0), rectboxmax = float3(0.0);
    // The taps in the shader's order: top, right, left, centre, bottom, then the four corners
    const int2 taps[9] = {int2(0, 1), int2(1, 0), int2(-1, 0), int2(0, 0), int2(0, -1), int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1)};
    for (int i = 0; i < 9; i++) {
        sgsrTap(sgsrFetch(InputColor, InputPos + taps[i], last).xyz, srcpos_srcOutputPos + float2(taps[i]), kernelbias2, curvebias, Upsampledcw,
                rectboxcenter, rectboxvar, rectboxweight, rectboxmin, rectboxmax, i == 0);
    }

    rectboxweight = 1.0 / rectboxweight;
    rectboxcenter *= rectboxweight;
    rectboxvar *= rectboxweight;
    rectboxvar = sqrt(abs(rectboxvar - rectboxcenter * rectboxcenter));

    // Clamp the signed-Lanczos result to the actual 3x3 source neighbourhood to suppress ringing
    Upsampledcw.xyz = abs(Upsampledcw.w) > 1e-6 ?
        clamp(Upsampledcw.xyz / Upsampledcw.w, rectboxmin, rectboxmax) :
        InputColor.sample(upscaleLinear, Hruv, level(0)).rgb;
    Upsampledcw.w = abs(Upsampledcw.w) * (1.0 / 3.0);

    float baseupdate = 1.0 - depthfactor;
    baseupdate = min(baseupdate, mix(baseupdate, Upsampledcw.w * 10.0, clamp(10.0 * motion_viewport_len, 0.0, 1.0)));
    baseupdate = min(baseupdate, mix(baseupdate, Upsampledcw.w, clamp(motion_viewport_len * 0.05, 0.0, 1.0)));
    float basealpha = baseupdate;

    const float EPSILON = 1.192e-07;
    float boxscale = max(depthfactor, clamp(motion_viewport_len * 0.05, 0.0, 1.0));
    float boxsize = mix(scalefactor, 1.0, boxscale);
    float3 sboxvar = rectboxvar * boxsize;
    float3 boxmin = rectboxcenter - sboxvar;
    float3 boxmax = rectboxcenter + sboxvar;
    rectboxmax = min(rectboxmax, boxmax);
    rectboxmin = max(rectboxmin, boxmin);

    bool historyOutsideBox = any(rectboxmin > HistoryColor) || any(HistoryColor > rectboxmax);
    float3 clampedcolor;
    if (u.qualityMode != 0) {
        float3 ycHistory = rgbToYCoCg(HistoryColor);
        float3 ycCenter = rgbToYCoCg(rectboxcenter);
        float3 ycMin = float3(1e10), ycMax = float3(-1e10);
        for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
            float3 yc = rgbToYCoCg(sgsrFetch(InputColor, InputPos + int2(x, y), last).rgb);
            ycMin = min(ycMin, yc);
            ycMax = max(ycMax, yc);
        }
        float3 ycExtent = (ycMax - ycMin) * 0.5;
        float3 ycLower = max(ycMin, ycCenter - ycExtent);
        float3 ycUpper = min(ycMax, ycCenter + ycExtent);
        float3 ycClamped = clamp(ycHistory, ycLower, ycUpper);
        // A history colour may fit the RGB box but not the tighter chroma-aware box
        historyOutsideBox = historyOutsideBox || any(ycHistory < ycLower) || any(ycHistory > ycUpper);
        clampedcolor = yCoCgToRgb(ycClamped);
    } else {
        clampedcolor = clamp(HistoryColor, rectboxmin, rectboxmax);
    }
    float startLerpValue = 0.0;
    float lerpcontribution = historyOutsideBox ? startLerpValue : 1.0;

    HistoryColor = mix(clampedcolor, HistoryColor, clamp(lerpcontribution, 0.0, 1.0));
    float basemin = min(basealpha, 0.1);
    basealpha = mix(basemin, basealpha, clamp(lerpcontribution, 0.0, 1.0));

    float alphasum = max(EPSILON, basealpha + Upsampledcw.w);
    float alpha = clamp(Upsampledcw.w / alphasum + frameReset, 0.0, 1.0);
    // Flow confidence replaces engine depth rejection. Never blend untrusted history.
    float reactive = u.qualityMode != 0 ? ReactiveMask.sample(upscaleLinear, Jitteruv, level(0)).r : 0.0;
    alpha = max(alpha, 1.0 - confidence * 0.75);
    alpha = max(alpha, reactive);

    Upsampledcw.xyz = mix(HistoryColor, Upsampledcw.xyz, alpha);
    return float4(Upsampledcw.xyz, 0.0);
}
