/// The Metal Shading Language source of the benchmark, compiled at run time with `MTLDevice.makeLibrary(source:)`.
///
/// `idwtKernel` is a port of PyroWave's `idwt.comp` (Hans-Kristian Arntzen, MIT, pyrowave commit
/// `186f0393b77f7755953b5ecde994bb1cec2e4155`, the one DELOS for Android vendors): one 64-thread threadgroup turns a
/// 16 x 16 block of every one of the four bands (LL, HL, LH, HH) of a level into 32 x 32 output samples. It gathers the
/// bands with a mirrored-repeat sampler into threadgroup memory with a two-sample apron, runs the CDF 9/7 lifting
/// steps down the rows, transposes while storing, and runs them again for the other direction. The threadgroup
/// memory holds half2 (PyroWave's FP16 storage); the arithmetic is `float` (PyroWave's `PRECISION == 1`, the Android
/// default) or `half` (`PRECISION == 0`). The first dimension of a dispatch walks the rows of the band image, because
/// PyroWave transposes on load; `IDWTParams.resolution` is therefore (height, width).
///
/// The MIT notice of the code `idwtKernel` derives from:
///
///     Copyright (c) 2025 Hans-Kristian Arntzen
///
///     Permission is hereby granted, free of charge, to any person obtaining
///     a copy of this software and associated documentation files (the
///     "Software"), to deal in the Software without restriction, including
///     without limitation the rights to use, copy, modify, merge, publish,
///     distribute, sublicense, and/or sell copies of the Software, and to
///     permit persons to whom the Software is furnished to do so, subject to
///     the following conditions:
///
///     The above copyright notice and this permission notice shall be
///     included in all copies or substantial portions of the Software.
///
///     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
///     EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
///     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
///     IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
///     CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
///     TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
///     SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///
/// `fillBands` is not part of PyroWave. It writes pseudo-random coefficients into the band images; it is the data
/// source of the benchmark and, run every frame, a bandwidth stand-in for PyroWave's dequantisation pass (which also
/// writes every coded band once). It does not decode a bit stream.
public enum IDWTShaders {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant bool DCShift [[function_constant(0)]];

    struct IDWTParams {
        int2 resolution;       // transposed, as in PyroWave: x = band height, y = band width
        float2 invResolution;
    };

    struct FillParams {
        uint firstLayer;
        uint seed;
        float amplitude;
    };

    constant int kApronHalf = 2;
    constant int kRowStride = 41;  // (32 + 2 * 4) interleaved samples per row, plus one to spread the banks
    constexpr sampler mirrorSampler(coord::normalized, address::mirrored_repeat, filter::nearest);

    inline int2 unswizzle8x8(uint index) {
        uint y = extract_bits(index, 0, 1);
        uint x = extract_bits(index, 1, 2);
        y |= extract_bits(index, 3, 2) << 1;
        x |= extract_bits(index, 5, 1) << 2;
        return int2(int(x), int(y));
    }

    // The 2 x 2 texels of one band around an integer position, in the order PyroWave's `.wxzy` swizzle gives them.
    // The coordinate tweaks turn the sampler's mirrored repeat (edge texel repeated) into the whole-sample symmetric
    // extension of JPEG 2000 for the interleaved signal.
    template <typename T>
    inline vec<T, 4> gatherBand(texture2d_array<T, access::sample> tex, int2 coord, bool evenX, bool evenY,
                                int2 res, float2 inv, uint layer) {
        coord -= int2(evenX && coord.x < 0, evenY && coord.y < 0);
        coord += 1;
        coord += int2(!evenX && coord.x >= res.x, !evenY && coord.y >= res.y);
        float2 uv = float2(coord) * inv;
        return tex.gather(mirrorSampler, uv.yx, layer).wxzy;
    }

    template <typename T>
    inline void loadQuad(texture2d_array<T, access::sample> tex, threadgroup half2* sb, int2 base, int2 local,
                         int2 res, float2 inv) {
        int2 c = base + local;
        vec<T, 4> t0 = gatherBand(tex, c, true, true, res, inv, 0);
        vec<T, 4> t1 = gatherBand(tex, c, false, true, res, inv, 2);
        vec<T, 4> t2 = gatherBand(tex, c, true, false, res, inv, 1);
        vec<T, 4> t3 = gatherBand(tex, c, false, false, res, inv, 3);
        threadgroup half2* r0 = sb + (local.y + 0) * kRowStride + 2 * local.x;
        threadgroup half2* r1 = sb + (local.y + 1) * kRowStride + 2 * local.x;
        r0[0] = half2(half(t0.x), half(t2.x));
        r0[1] = half2(half(t1.x), half(t3.x));
        r0[2] = half2(half(t0.y), half(t2.y));
        r0[3] = half2(half(t1.y), half(t3.y));
        r1[0] = half2(half(t0.z), half(t2.z));
        r1[1] = half2(half(t1.z), half(t3.z));
        r1[2] = half2(half(t0.w), half(t2.w));
        r1[3] = half2(half(t1.w), half(t3.w));
    }

    // CDF 9/7 synthesis: the four lifting steps of ITU-T T.800 F.4.8.2 on a run of interleaved samples.
    template <typename M, int P>
    inline void lift(thread vec<M, 2> (&v)[P]) {
        const M alpha = M(-1.586134342059924f);
        const M beta = M(-0.052980118572961f);
        const M gamma = M(0.882911075530934f);
        const M delta = M(0.443506852043971f);
        #pragma unroll
        for (int i = 2; i < P - 1; i += 2) v[i] -= delta * (v[i - 1] + v[i + 1]);
        #pragma unroll
        for (int i = 3; i < P - 2; i += 2) v[i] -= gamma * (v[i - 1] + v[i + 1]);
        #pragma unroll
        for (int i = 4; i < P - 3; i += 2) v[i] -= beta * (v[i - 1] + v[i + 1]);
        #pragma unroll
        for (int i = 5; i < P - 4; i += 2) v[i] -= alpha * (v[i - 1] + v[i + 1]);
    }

    template <typename M, int P>
    inline void loadScaled(threadgroup half2* sb, int2 lc, thread vec<M, 2> (&v)[P]) {
        const M k = M(1.230174104914001f);
        const M invK = M(1.0f / 1.230174104914001f);
        #pragma unroll
        for (int i = 0; i < P; i += 2) {
            v[i + 0] = vec<M, 2>(sb[lc.y * kRowStride + lc.x + i + 0]) * k;
            v[i + 1] = vec<M, 2>(sb[lc.y * kRowStride + lc.x + i + 1]) * invK;
        }
    }

    // Stores the inner samples of `v` transposed: the pair axis and the run axis swap places.
    template <typename M, int P>
    inline void storeTransposed(threadgroup half2* sb, int2 lc, thread vec<M, 2> (&v)[P]) {
        #pragma unroll
        for (int i = kApronHalf; i < P / 2 - kApronHalf; i++) {
            vec<M, 2> a = v[2 * i + 0];
            vec<M, 2> b = v[2 * i + 1];
            int row = (lc.x >> 1) + (i - kApronHalf);
            sb[row * kRowStride + 2 * lc.y + 0] = half2(vec<M, 2>(a.x, b.x));
            sb[row * kRowStride + 2 * lc.y + 1] = half2(vec<M, 2>(a.y, b.y));
        }
    }

    template <typename M>
    inline void inverse8x2(threadgroup half2* sb, uint li) {
        vec<M, 2> v[16];
        int2 lc = int2(8 * int(li % 4), int(li / 4));
        loadScaled<M, 16>(sb, lc, v);
        lift<M, 16>(v);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        storeTransposed<M, 16>(sb, lc, v);
    }

    template <typename M>
    inline void inverse4x2(threadgroup half2* sb, uint li, bool active, int yOffset) {
        vec<M, 2> v[12];
        int2 lc = int2(4 * int(li % 8), int(li / 8) + yOffset);
        if (active) {
            loadScaled<M, 12>(sb, lc, v);
            lift<M, 12>(v);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (active) {
            storeTransposed<M, 12>(sb, lc, v);
        }
    }

    template <typename TIn, typename TOut, typename M>
    kernel void idwtKernel(texture2d_array<TIn, access::sample> tex [[texture(0)]],
                           texture2d<TOut, access::write> out [[texture(1)]],
                           constant IDWTParams& p [[buffer(0)]],
                           uint3 wg [[threadgroup_position_in_grid]],
                           uint li [[thread_index_in_threadgroup]]) {
        threadgroup half2 sb[20 * kRowStride];

        int2 base = int2(wg.xy) * 16 - kApronHalf;
        loadQuad(tex, sb, base, 2 * unswizzle8x8(li), p.resolution, p.invResolution);
        int2 horiz = int2(16 + 2 * int(li % 2), 2 * int(li / 2));
        if (horiz.y < 16 + 2 * kApronHalf) {
            loadQuad(tex, sb, base, horiz, p.resolution, p.invResolution);
        }
        int2 vert = horiz.yx;
        if (vert.x < 16) {
            loadQuad(tex, sb, base, vert, p.resolution, p.invResolution);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        inverse8x2<M>(sb, li);
        inverse4x2<M>(sb, li, li < 32, 16);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        inverse8x2<M>(sb, li);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        int2 lc = unswizzle8x8(li);
        int2 origin = 32 * int2(int(wg.y), int(wg.x));
        for (int y = lc.y; y < 16; y += 8) {
            for (int x = lc.x; x < 32; x += 8) {
                vec<M, 2> v = vec<M, 2>(sb[y * kRowStride + x]);
                if (DCShift) {
                    v += M(0.5f);
                }
                out.write(vec<TOut, 4>(TOut(v.x)), uint2(origin + int2(2 * y + 0, x)));
                out.write(vec<TOut, 4>(TOut(v.y)), uint2(origin + int2(2 * y + 1, x)));
            }
        }
    }

    // host_name: idwt_<input>_<output>_<math>, h = half, f = float.
    template [[host_name("idwt_h_h_h")]] kernel void idwtKernel<half, half, half>(
        texture2d_array<half, access::sample>, texture2d<half, access::write>, constant IDWTParams&, uint3, uint);
    template [[host_name("idwt_h_h_f")]] kernel void idwtKernel<half, half, float>(
        texture2d_array<half, access::sample>, texture2d<half, access::write>, constant IDWTParams&, uint3, uint);
    template [[host_name("idwt_f_f_f")]] kernel void idwtKernel<float, float, float>(
        texture2d_array<float, access::sample>, texture2d<float, access::write>, constant IDWTParams&, uint3, uint);
    template [[host_name("idwt_f_h_f")]] kernel void idwtKernel<float, half, float>(
        texture2d_array<float, access::sample>, texture2d<half, access::write>, constant IDWTParams&, uint3, uint);

    inline uint hash3(uint x, uint y, uint z, uint seed) {
        uint h = x * 0x9E3779B1u ^ y * 0x85EBCA77u ^ z * 0xC2B2AE3Du ^ seed * 0x27D4EB2Fu;
        h ^= h >> 15;
        h *= 0x2C1B3C6Du;
        h ^= h >> 12;
        h *= 0x297A2D39u;
        h ^= h >> 15;
        return h;
    }

    template <typename T>
    kernel void fillBands(texture2d_array<T, access::write> tex [[texture(0)]],
                          constant FillParams& p [[buffer(0)]],
                          uint3 gid [[thread_position_in_grid]]) {
        if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) {
            return;
        }
        uint layer = gid.z + p.firstLayer;
        float v = (float(hash3(gid.x, gid.y, layer, p.seed) & 0xFFFFu) / 32768.0f - 1.0f) * p.amplitude;
        tex.write(vec<T, 4>(T(v)), uint2(gid.xy), layer);
    }

    template [[host_name("fill_h")]] kernel void fillBands<half>(
        texture2d_array<half, access::write>, constant FillParams&, uint3);
    template [[host_name("fill_f")]] kernel void fillBands<float>(
        texture2d_array<float, access::write>, constant FillParams&, uint3);
    """#
}
