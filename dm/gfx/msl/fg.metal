// Frame generation (nvn_mtl.m, Frame generation): a picture halfway between the game's last two frames, shown on the refresh between them. Games hand the present no motion
// vectors or depth (MetalFX's frame interpolator needs both), so the motion is estimated from the two pictures: block matching on their luma, coarse to fine, then each pixel
// is taken from both frames half a motion step apart and blended where they agree. Everything is a full-screen triangle (fg_vs) into a texture of the pass's size.
#include <metal_stdlib>
using namespace metal;

struct V { float4 p [[position]]; float2 uv; };
vertex V fg_vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }

// The game's picture copied texel for texel (the present shows this copy on the second refresh; the game may draw into its own texture again by then)
fragment float4 fg_copy(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(in.p.xy)); }

// Luma averaged over the 4x4 source texels under each output texel: four bilinear taps, each the mean of a 2x2 quad. o: one source texel in uv
struct LumaP { float2 o; float2 pad; };
fragment float fg_luma(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant LumaP &p [[buffer(0)]]) {
    float3 c = t.sample(s, in.uv + float2(-p.o.x, -p.o.y)).rgb + t.sample(s, in.uv + float2(p.o.x, -p.o.y)).rgb
             + t.sample(s, in.uv + float2(-p.o.x, p.o.y)).rgb + t.sample(s, in.uv + float2(p.o.x, p.o.y)).rgb;
    return dot(c * 0.25, float3(0.299, 0.587, 0.114));
}

// Sum of absolute luma differences of the 3x3 blocks at c in cur and c + d in prev (texel coordinates, clamped to the picture)
static float sad3(texture2d<float> cur, texture2d<float> prev, int2 c, int2 d, int2 hi) {
    float s = 0;
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
        int2 a = clamp(c + int2(i, j), int2(0), hi), b = clamp(c + d + int2(i, j), int2(0), hi);
        s += abs(cur.read(uint2(a)).r - prev.read(uint2(b)).r);
    }
    return s;
}

// The motion of each texel of the coarsest luma (1/16 of the picture): the offset into the previous frame, within r texels, whose block matches best. A small cost per texel of
// offset keeps flat areas and the HUD still. Output in texels of this level
struct FlowP { int r; float bias; int2 pad; };
fragment float2 fg_flow_coarse(V in [[stage_in]], texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]], constant FlowP &p [[buffer(0)]]) {
    int2 c = int2(in.p.xy), hi = int2(cur.get_width(), cur.get_height()) - 1;
    float best = sad3(cur, prev, c, int2(0), hi); int2 bd = int2(0);
    for (int dy = -p.r; dy <= p.r; dy++) for (int dx = -p.r; dx <= p.r; dx++) {
        int2 d = int2(dx, dy);
        float s = sad3(cur, prev, c, d, hi) + p.bias * length(float2(d));
        if (s < best) { best = s; bd = d; }
    }
    return float2(bd);
}

// The motion refined on the finer luma (1/4 of the picture, 4 texels per coarse texel): the coarse motion of this texel and of its four neighbours, each searched r texels
// around, and no motion. Output in texels of this level
fragment float2 fg_flow_fine(V in [[stage_in]], texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]], texture2d<float> coarse [[texture(2)]],
                             constant FlowP &p [[buffer(0)]]) {
    int2 c = int2(in.p.xy), hi = int2(cur.get_width(), cur.get_height()) - 1, chi = int2(coarse.get_width(), coarse.get_height()) - 1;
    int2 cc = clamp(c / 4, int2(0), chi);
    int2 seeds[5] = { cc, cc + int2(1, 0), cc - int2(1, 0), cc + int2(0, 1), cc - int2(0, 1) };
    float best = sad3(cur, prev, c, int2(0), hi); int2 bd = int2(0);
    for (int k = 0; k < 5; k++) {
        int2 s0 = int2(round(coarse.read(uint2(clamp(seeds[k], int2(0), chi))).rg * 4));
        if (k && all(s0 == int2(round(coarse.read(uint2(cc)).rg * 4)))) continue;
        for (int dy = -p.r; dy <= p.r; dy++) for (int dx = -p.r; dx <= p.r; dx++) {
            int2 d = s0 + int2(dx, dy);
            float s = sad3(cur, prev, c, d, hi) + p.bias * length(float2(d));
            if (s < best) { best = s; bd = d; }
        }
    }
    return float2(bd);
}

// The picture halfway: where cur(x) came from prev(x + d), the middle frame shows it at x + d/2, so pixel q takes cur(q - d/2) and prev(q + d/2), with d the motion around q.
// Where the two disagree (something uncovered or covered, or the motion is wrong) the current frame's sample wins, which keeps edges sharp rather than doubled.
// scale: flow texels to source texels; inv: one source texel in uv
struct SynthP { float2 inv; float scale; float pad; };
fragment float4 fg_synth(V in [[stage_in]], texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]], texture2d<float> flow [[texture(2)]],
                         sampler s [[sampler(0)]], constant SynthP &p [[buffer(0)]]) {
    float2 d = flow.sample(s, in.uv).rg * p.scale * p.inv;
    float4 a = prev.sample(s, in.uv + 0.5 * d), b = cur.sample(s, in.uv - 0.5 * d);
    float w = saturate(1.0 - 3.0 * length(a.rgb - b.rgb));
    return mix(b, 0.5 * (a + b), w);
}
