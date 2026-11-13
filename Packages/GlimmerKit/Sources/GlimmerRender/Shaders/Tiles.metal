#include <metal_stdlib>
using namespace metal;

// ── Shared quad ─────────────────────────────────────────────────────────────

// Must match `QuadUniforms` in TilePipelines.swift.
struct QuadUniforms {
    float4 rect;        // target pixels: x, y, width, height (y-down)
    float4 uvRect;      // u0, v0, u1, v1
    float2 targetSize;  // target pixels
};

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// Triangle strip: (0,0) (1,0) (0,1) (1,1)
vertex QuadOut tile_quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &q [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = q.rect.xy + corner * q.rect.zw;
    QuadOut out;
    out.position = float4(p.x / q.targetSize.x * 2.0 - 1.0, 1.0 - p.y / q.targetSize.y * 2.0, 0.0, 1.0);
    out.uv = mix(q.uvRect.xy, q.uvRect.zw, corner);
    return out;
}

// Must match `SourceUniforms` in TilePipelines.swift.
struct SourceUniforms {
    float4 solidColor;  // premultiplied linear
    int isSolid;
    int mode;           // BlendMode.shaderIndex
    float opacity;
    int gammaSpace;     // 1 = blend in sRGB-encoded space
};

static float4 sourceColor(QuadOut in, texture2d<float> src, constant SourceUniforms &u) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return u.isSolid != 0 ? u.solidColor : src.sample(s, in.uv);
}

// ── Blend math (W3C Compositing and Blending Level 1) ──────────────────────

static float3 encodeSRGB(float3 c) {
    float3 a = abs(c);
    float3 e = select(1.055 * pow(a, 1.0 / 2.4) - 0.055, a * 12.92, a <= 0.0031308);
    return sign(c) * e;
}

static float3 decodeSRGB(float3 c) {
    float3 a = abs(c);
    float3 d = select(pow((a + 0.055) / 1.055, 2.4), a / 12.92, a <= 0.04045);
    return sign(c) * d;
}

static float lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }

static float3 clipColor(float3 c) {
    float l = lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));
    if (n < 0.0) c = l + (c - l) * l / max(l - n, 1e-6);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / max(x - l, 1e-6);
    return c;
}

static float3 setLum(float3 c, float l) { return clipColor(c + (l - lum(c))); }

static float sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }

static float3 setSat(float3 c, float s) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float range = mx - mn;
    if (range <= 1e-6) return float3(0.0);
    return (c - mn) * s / range;
}

static float softLightD(float b) {
    return b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
}

static float colorDodge(float b, float s) {
    if (b <= 0.0) return 0.0;
    if (s >= 1.0) return 1.0;
    return min(1.0, b / (1.0 - s));
}

static float colorBurn(float b, float s) {
    if (b >= 1.0) return 1.0;
    if (s <= 0.0) return 0.0;
    return 1.0 - min(1.0, (1.0 - b) / s);
}

static float hardLight(float b, float s) {
    return s <= 0.5 ? b * 2.0 * s : b + (2.0 * s - 1.0) - b * (2.0 * s - 1.0);
}

static float softLight(float b, float s) {
    return s <= 0.5 ? b - (1.0 - 2.0 * s) * b * (1.0 - b)
                    : b + (2.0 * s - 1.0) * (softLightD(b) - b);
}

/// B(Cb, Cs) for straight colours. `mode` matches BlendMode.shaderIndex.
static float3 blendColor(float3 cb, float3 cs, int mode) {
    if (mode == 0) return cs;
    // The formulas below are defined on [0, 1].
    cb = saturate(cb);
    cs = saturate(cs);
    switch (mode) {
        case 1: return cb * cs;
        case 2: return cb + cs - cb * cs;
        case 3: return float3(hardLight(cs.r, cb.r), hardLight(cs.g, cb.g), hardLight(cs.b, cb.b)); // overlay
        case 4: return min(cb, cs);
        case 5: return max(cb, cs);
        case 6: return float3(colorDodge(cb.r, cs.r), colorDodge(cb.g, cs.g), colorDodge(cb.b, cs.b));
        case 7: return float3(colorBurn(cb.r, cs.r), colorBurn(cb.g, cs.g), colorBurn(cb.b, cs.b));
        case 8: return float3(hardLight(cb.r, cs.r), hardLight(cb.g, cs.g), hardLight(cb.b, cs.b));
        case 9: return float3(softLight(cb.r, cs.r), softLight(cb.g, cs.g), softLight(cb.b, cs.b));
        case 10: return abs(cb - cs);
        case 11: return cb + cs - 2.0 * cb * cs;
        case 12: return min(float3(1.0), cb + cs);
        case 13: return max(float3(0.0), cb + cs - 1.0);
        case 14: return setLum(setSat(cs, sat(cb)), lum(cb));
        case 15: return setLum(setSat(cb, sat(cs)), lum(cb));
        case 16: return setLum(cs, lum(cb));
        case 17: return setLum(cb, lum(cs));
        default: return cs;
    }
}

/// Composites premultiplied `src` onto premultiplied `dst`.
static float4 blendOver(float4 dst, float4 src, constant SourceUniforms &u) {
    float as = src.a * u.opacity;
    float ab = dst.a;
    if (as <= 0.0) return dst;

    float3 cs = src.rgb / max(src.a, 1e-8);
    float3 cb = ab > 0.0 ? dst.rgb / ab : float3(0.0);
    bool gamma = u.gammaSpace != 0;
    if (gamma) { cs = encodeSRGB(cs); cb = encodeSRGB(cb); }

    float3 mixed = (1.0 - ab) * cs + ab * blendColor(cb, cs, u.mode);
    float ao = as + ab * (1.0 - as);
    float3 straight = (as * mixed + (1.0 - as) * ab * cb) / max(ao, 1e-8);
    if (gamma) straight = decodeSRGB(straight);
    return float4(straight * ao, ao);
}

// Reads the render target through programmable blending (tile memory on Apple GPUs).
fragment float4 composite_blend_fragment(QuadOut in [[stage_in]],
                                         float4 dst [[color(0)]],
                                         texture2d<float> src [[texture(0)]],
                                         constant SourceUniforms &u [[buffer(0)]]) {
    return blendOver(dst, sourceColor(in, src, u), u);
}

/// Straight copy (blending disabled) for re-tiling.
fragment float4 tile_copy_fragment(QuadOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant SourceUniforms &u [[buffer(0)]]) {
    return sourceColor(in, src, u);
}

/// 4×4 supersampled minification for thumbnails (premultiplied, blended "over").
fragment float4 thumbnail_fragment(QuadOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant SourceUniforms &u [[buffer(0)]]) {
    if (u.isSolid != 0) return u.solidColor;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float4 sum = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float2 o = (float2(i, j) + 0.5) / 4.0 - 0.5;
            sum += src.sample(s, in.uv + o.x * dx + o.y * dy);
        }
    }
    return sum / 16.0;
}

// ── Presentation ────────────────────────────────────────────────────────────

// Must match `PresentUniforms` in CanvasRenderer.swift.
struct PresentUniforms {
    float3x3 documentToClip;
    float4 documentRect;  // x, y, width, height in document pixels
    float4 uvRect;
};

vertex QuadOut present_vertex(uint vid [[vertex_id]], constant PresentUniforms &u [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float2 doc = u.documentRect.xy + corner * u.documentRect.zw;
    float3 clip = u.documentToClip * float3(doc, 1.0);
    QuadOut out;
    out.position = float4(clip.xy, 0.0, 1.0);
    out.uv = mix(u.uvRect.xy, u.uvRect.zw, corner);
    return out;
}

/// Trilinear sampling of composited tiles; pixel-exact (nearest) when magnified.
fragment float4 present_fragment(QuadOut in [[stage_in]], texture2d<float> tile [[texture(0)]]) {
    constexpr sampler minifying(mag_filter::nearest, min_filter::linear, mip_filter::linear,
                                address::clamp_to_edge);
    return tile.sample(minifying, in.uv);
}
