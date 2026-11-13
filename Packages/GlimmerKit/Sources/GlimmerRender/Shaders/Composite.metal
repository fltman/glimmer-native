#include <metal_stdlib>
using namespace metal;

// Compositing shaders. Everything works on premultiplied, linear, extended-sRGB
// RGBA16Float tiles. Solid tiles are bound as 1×1 textures, so every source is
// simply sampled.

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

constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

// ── Colour helpers ──────────────────────────────────────────────────────────

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

static float luma709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// ── Blend math (W3C Compositing and Blending Level 1) ──────────────────────

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
    cb = saturate(cb);
    cs = saturate(cs);
    switch (mode) {
        case 1: return cb * cs;
        case 2: return cb + cs - cb * cs;
        case 3: return float3(hardLight(cs.r, cb.r), hardLight(cs.g, cb.g), hardLight(cs.b, cb.b));
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

/// Composites premultiplied `src` (already scaled by opacity/masks) onto `dst`.
static float4 blendOver(float4 dst, float4 src, int mode, bool gamma) {
    float as = src.a;
    float ab = dst.a;
    if (as <= 0.0) return dst;

    float3 cs = src.rgb / max(src.a, 1e-8);
    float3 cb = ab > 0.0 ? dst.rgb / ab : float3(0.0);
    if (gamma) { cs = encodeSRGB(cs); cb = encodeSRGB(cb); }

    float3 mixed = (1.0 - ab) * cs + ab * blendColor(cb, cs, mode);
    float ao = as + ab * (1.0 - as);
    float3 straight = (as * mixed + (1.0 - as) * ab * cb) / max(ao, 1e-8);
    if (gamma) straight = decodeSRGB(straight);
    return float4(straight * ao, ao);
}

static float maskValue(float sampled, float density) {
    return 1.0 - density * (1.0 - saturate(sampled));
}

static float lutCoord(float t) { return (saturate(t) * 1023.0 + 0.5) / 1024.0; }

// ── Layer compositing ──────────────────────────────────────────────────────

// Must match `LayerUniforms` in TilePipelines.swift.
struct LayerUniforms {
    float4 overlay;        // colour overlay: linear straight rgb, a = opacity (0 = none)
    float4 patternForeground;
    float4 patternBackground;
    float2 gradientStart;  // document pixels
    float2 gradientEnd;
    float2 tileOrigin;     // document pixel of the output tile's top-left
    int mode;
    float opacity;
    int gammaSpace;
    int sourceKind;        // 0 texture, 1 linear gradient, 2 radial gradient, 3 pattern
    float maskDensity;
    float clipDensity;
    int overlayMode;
    int patternKind;
    float patternScale;
    int gradientReverse;
};

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float4 proceduralSource(float2 doc, constant LayerUniforms &u, texture2d<float> lut) {
    if (u.sourceKind == 1 || u.sourceKind == 2) {
        float2 d = u.gradientEnd - u.gradientStart;
        float t;
        if (u.sourceKind == 1) {
            t = dot(doc - u.gradientStart, d) / max(dot(d, d), 1e-6);
        } else {
            t = length(doc - u.gradientStart) / max(length(d), 1e-6);
        }
        if (u.gradientReverse != 0) t = 1.0 - t;
        float4 c = lut.sample(linearSampler, float2(lutCoord(t), 0.5));  // straight sRGB + opacity
        return float4(decodeSRGB(c.rgb) * c.a, c.a);
    }
    // Pattern
    float s = max(u.patternScale, 1.0);
    float2 cell = floor(doc / s);
    float2 f = fract(doc / s);
    float k = 0.0;
    switch (u.patternKind) {
        case 0: k = fmod(abs(cell.x + cell.y), 2.0); break;                   // checkerboard
        case 1: k = length(f - 0.5) < 0.3 ? 1.0 : 0.0; break;                 // dots
        case 2: k = fract((doc.x + doc.y) / s) < 0.5 ? 1.0 : 0.0; break;      // stripes
        case 3: { float w = max(1.0, s / 16.0) / s;                            // grid
                  k = (f.x < w || f.y < w) ? 1.0 : 0.0; break; }
        default: k = hash21(cell); break;                                       // noise
    }
    float3 c = mix(u.patternBackground.rgb, u.patternForeground.rgb, k);
    return float4(c, 1.0);
}

/// One layer (pixels, fill, group result or effect) onto the current tile, read
/// through programmable blending.
fragment float4 composite_layer_fragment(QuadOut in [[stage_in]],
                                         float4 dst [[color(0)]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> srcMask [[texture(1)]],
                                         texture2d<float> clip [[texture(2)]],
                                         texture2d<float> clipMask [[texture(3)]],
                                         texture2d<float> lut [[texture(4)]],
                                         constant LayerUniforms &u [[buffer(0)]]) {
    float2 outUV = in.position.xy / 256.0;
    float4 c = u.sourceKind == 0 ? src.sample(nearestSampler, in.uv)
                                 : proceduralSource(u.tileOrigin + in.position.xy, u, lut);

    // Colour overlay replaces the layer's colour, keeping its alpha.
    if (u.overlay.a > 0.0 && c.a > 0.0) {
        float3 straight = c.rgb / c.a;
        float3 over = blendColor(saturate(straight), u.overlay.rgb, u.overlayMode);
        c.rgb = mix(straight, over, u.overlay.a) * c.a;
    }

    float k = u.opacity * maskValue(srcMask.sample(nearestSampler, in.uv).a, u.maskDensity);
    k *= clip.sample(nearestSampler, outUV).a * maskValue(clipMask.sample(nearestSampler, outUV).a, u.clipDensity);
    return blendOver(dst, c * k, u.mode, u.gammaSpace != 0);
}

/// Pass-through group with opacity or mask: blend the children's result back
/// toward the backdrop saved before they were drawn.
fragment float4 passthrough_mix_fragment(QuadOut in [[stage_in]],
                                         float4 dst [[color(0)]],
                                         texture2d<float> backup [[texture(0)]],
                                         texture2d<float> mask [[texture(1)]],
                                         texture2d<float> clip [[texture(2)]],
                                         texture2d<float> clipMask [[texture(3)]],
                                         constant LayerUniforms &u [[buffer(0)]]) {
    float2 uv = in.position.xy / 256.0;
    float k = u.opacity * maskValue(mask.sample(nearestSampler, uv).a, u.maskDensity);
    k *= clip.sample(nearestSampler, uv).a * maskValue(clipMask.sample(nearestSampler, uv).a, u.clipDensity);
    return mix(backup.sample(nearestSampler, uv), dst, k);
}

// ── Adjustment layers (formulas match Glimmer for the web) ─────────────────

// Must match `AdjustUniforms` in TilePipelines.swift.
struct AdjustUniforms {
    float4 params[7];
    int kind;           // AdjustmentKind.shaderIndex
    int mode;
    float opacity;
    int gammaSpace;
    float maskDensity;
    float clipDensity;
    int pad0;
    int pad1;
};

static float P(constant AdjustUniforms &u, int i) { return u.params[i / 4][i % 4]; }

static float3 rgb2hsl(float3 c) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    float l = (mx + mn) * 0.5;
    float h = 0.0, s = 0.0;
    float d = mx - mn;
    if (d > 1e-5) {
        s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }
    return float3(h, s, l);
}

static float hue2rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

static float3 hsl2rgb(float3 hsl) {
    if (hsl.y <= 0.0) return float3(hsl.z);
    float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
    float p = 2.0 * hsl.z - q;
    return float3(hue2rgb(p, q, hsl.x + 1.0 / 3.0), hue2rgb(p, q, hsl.x), hue2rgb(p, q, hsl.x - 1.0 / 3.0));
}

/// Straight linear colour in, adjusted straight linear colour out.
static float3 adjustColor(float3 lin, constant AdjustUniforms &u, texture2d<float> lut) {
    if (u.kind == 3) {  // exposure works in linear light
        float3 c = lin * exp2(P(u, 0)) + P(u, 1);
        c = max(c, 0.0);
        return pow(c, float3(1.0 / max(P(u, 2), 0.01)));
    }
    float3 c = saturate(encodeSRGB(lin));
    switch (u.kind) {
        case 0: {  // brightness / contrast
            c += P(u, 0);
            float k = tan((clamp(P(u, 1), -0.999, 0.999) + 1.0) * 0.7853981634);
            c = (c - 0.5) * k + 0.5;
            break;
        }
        case 1:    // levels
        case 2:    // curves
            c = float3(lut.sample(linearSampler, float2(lutCoord(c.r), 0.5)).r,
                       lut.sample(linearSampler, float2(lutCoord(c.g), 0.5)).g,
                       lut.sample(linearSampler, float2(lutCoord(c.b), 0.5)).b);
            break;
        case 4: {  // hue / saturation
            float3 hsl = rgb2hsl(c);
            float l = P(u, 2);
            hsl.x = fract(hsl.x + P(u, 0) / 6.2831853);
            hsl.y = saturate(hsl.y * (1.0 + P(u, 1)));
            hsl.z = saturate(hsl.z + l * (l > 0.0 ? (1.0 - hsl.z) : hsl.z));
            c = hsl2rgb(hsl);
            break;
        }
        case 5: {  // vibrance
            float s = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
            float k = 1.0 + P(u, 0) * (1.0 - s) + P(u, 1);
            c = mix(float3(luma709(c)), c, k);
            break;
        }
        case 6: {  // colour balance
            float before = luma709(c);
            float3 shadowW = 1.0 - smoothstep(0.0, 0.5, c);
            float3 highW = smoothstep(0.5, 1.0, c);
            float3 midW = 1.0 - shadowW - highW;
            c += float3(P(u, 0), P(u, 1), P(u, 2)) * 0.5 * shadowW;
            c += float3(P(u, 3), P(u, 4), P(u, 5)) * 0.5 * midW;
            c += float3(P(u, 6), P(u, 7), P(u, 8)) * 0.5 * highW;
            c = saturate(c);
            if (P(u, 9) > 0.5) c = saturate(c + (before - luma709(c)));
            break;
        }
        case 7: {  // black & white
            float mn = min(min(c.r, c.g), c.b);
            float red = max(0.0, min(c.r - c.g, c.r - c.b));
            float green = max(0.0, min(c.g - c.r, c.g - c.b));
            float blue = max(0.0, min(c.b - c.r, c.b - c.g));
            float yellow = max(0.0, min(c.r, c.g) - c.b);
            float cyan = max(0.0, min(c.g, c.b) - c.r);
            float magenta = max(0.0, min(c.r, c.b) - c.g);
            float gray = mn + red * P(u, 0) + yellow * P(u, 1) + green * P(u, 2)
                       + cyan * P(u, 3) + blue * P(u, 4) + magenta * P(u, 5);
            c = float3(saturate(gray));
            break;
        }
        case 8: {  // photo filter
            float before = luma709(c);
            c = mix(c, c * float3(P(u, 0), P(u, 1), P(u, 2)), P(u, 3));
            if (P(u, 4) > 0.5) {
                float after = luma709(c);
                c = saturate(c * (after > 1e-4 ? before / after : 1.0));
            }
            break;
        }
        case 9: {  // channel mixer: rows r, g, b = (r, g, b, constant)
            float3 o = float3(dot(c, float3(P(u, 0), P(u, 1), P(u, 2))) + P(u, 3),
                              dot(c, float3(P(u, 4), P(u, 5), P(u, 6))) + P(u, 7),
                              dot(c, float3(P(u, 8), P(u, 9), P(u, 10))) + P(u, 11));
            if (P(u, 12) > 0.5) o = float3(o.r);
            c = saturate(o);
            break;
        }
        case 10: c = 1.0 - c; break;  // invert
        case 11: {  // posterize
            float n = max(2.0, P(u, 0));
            c = saturate(floor(c * n) / (n - 1.0));
            break;
        }
        case 12: {  // threshold
            float l = dot(c, float3(0.299, 0.587, 0.114));
            c = float3(l >= P(u, 0) ? 1.0 : 0.0);
            break;
        }
        case 13: {  // gradient map
            c = lut.sample(linearSampler, float2(lutCoord(luma709(c)), 0.5)).rgb;
            break;
        }
        default: break;
    }
    return decodeSRGB(saturate(c));
}

fragment float4 adjust_fragment(QuadOut in [[stage_in]],
                                float4 dst [[color(0)]],
                                texture2d<float> lut [[texture(0)]],
                                texture2d<float> mask [[texture(1)]],
                                texture2d<float> clip [[texture(2)]],
                                texture2d<float> clipMask [[texture(3)]],
                                constant AdjustUniforms &u [[buffer(0)]]) {
    float a = dst.a;
    if (a <= 0.0) return dst;
    float2 uv = in.position.xy / 256.0;
    float3 cb = dst.rgb / a;
    float3 adjusted = adjustColor(cb, u, lut);

    // The adjustment's blend mode combines the backdrop with its adjusted self.
    bool gamma = u.gammaSpace != 0;
    float3 b = gamma ? encodeSRGB(cb) : cb;
    float3 s = gamma ? encodeSRGB(adjusted) : adjusted;
    float3 blended = blendColor(b, s, u.mode);
    if (gamma) blended = decodeSRGB(blended);

    float k = u.opacity * maskValue(mask.sample(nearestSampler, uv).a, u.maskDensity);
    k *= clip.sample(nearestSampler, uv).a * maskValue(clipMask.sample(nearestSampler, uv).a, u.clipDensity);
    return float4(mix(cb, blended, k) * a, a);
}

// ── Utilities ──────────────────────────────────────────────────────────────

/// Straight copy (blending disabled) for re-tiling and region assembly.
fragment float4 tile_copy_fragment(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.sample(nearestSampler, in.uv);
}

/// 4×4 supersampled minification for thumbnails (premultiplied, blended "over").
fragment float4 thumbnail_fragment(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float4 sum = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float2 o = (float2(i, j) + 0.5) / 4.0 - 0.5;
            sum += src.sample(linearSampler, in.uv + o.x * dx + o.y * dy);
        }
    }
    return sum / 16.0;
}

// ── Smart objects ──────────────────────────────────────────────────────────

// Must match `SmartUniforms` in SmartObjectRenderer.swift.
struct SmartUniforms {
    float3x3 sourceToClip;
    float2 sourceSize;
};

vertex QuadOut smart_vertex(uint vid [[vertex_id]], constant SmartUniforms &u [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float3 clip = u.sourceToClip * float3(corner * u.sourceSize, 1.0);
    QuadOut out;
    out.position = float4(clip.xy, 0.0, 1.0);
    out.uv = corner;
    return out;
}

fragment float4 smart_fragment(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler trilinear(filter::linear, mip_filter::linear, address::clamp_to_zero);
    return src.sample(trilinear, in.uv);
}

// ── Layer style kernels ────────────────────────────────────────────────────

/// Effective alpha (layer alpha × mask), shifted and spread, into R.
kernel void effect_alpha(texture2d<float, access::read> pixels [[texture(0)]],
                         texture2d<float, access::read> mask [[texture(1)]],
                         texture2d<float, access::write> out [[texture(2)]],
                         constant float4 &params [[buffer(0)]],  // offset.xy, spread, invert
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    int2 p = int2(gid) - int2(round(params.xy));
    float a = 0.0;
    if (p.x >= 0 && p.y >= 0 && p.x < int(pixels.get_width()) && p.y < int(pixels.get_height())) {
        a = pixels.read(uint2(p)).a * saturate(mask.read(uint2(p)).a);
    }
    if (params.w > 0.5) a = 1.0 - a;
    float spread = clamp(params.z, 0.0, 0.99);
    a = saturate(a / (1.0 - spread));
    out.write(float4(a), gid);
}

/// Binary shape (alpha ≥ 0.5) or its complement, for the distance transform.
kernel void effect_binary(texture2d<float, access::read> pixels [[texture(0)]],
                          texture2d<float, access::read> mask [[texture(1)]],
                          texture2d<float, access::write> out [[texture(2)]],
                          constant float &invert [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float a = pixels.read(gid).a * saturate(mask.read(gid).a);
    bool on = a >= 0.5;
    if (invert > 0.5) on = !on;
    out.write(float4(on ? 1.0 : 0.0), gid);
}

// Must match `EffectColorUniforms` in LayerStyleRenderer.swift.
struct EffectColorUniforms {
    float4 color;    // linear straight rgb, a = opacity
    float4 stroke;   // width, position (0 outside, 1 inside, 2 center), mode (0 coverage, 1 stroke, 2 inner)
};

/// Turns a coverage (or distance) field into a premultiplied colour layer.
kernel void effect_colorize(texture2d<float, access::read> field [[texture(0)]],
                            texture2d<float, access::read> field2 [[texture(1)]],
                            texture2d<float, access::read> pixels [[texture(2)]],
                            texture2d<float, access::read> mask [[texture(3)]],
                            texture2d<float, access::write> out [[texture(4)]],
                            constant EffectColorUniforms &u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float cov;
    int mode = int(u.stroke.z);
    if (mode == 1) {
        // field = distance outside the shape, field2 = distance inside.
        float w = u.stroke.x;
        float dOut = field.read(gid).r, dIn = field2.read(gid).r;
        int pos = int(u.stroke.y);
        float outside = dOut > 0.0 ? saturate((pos == 2 ? w * 0.5 : w) - dOut + 0.5) : 0.0;
        float inside = dIn > 0.0 ? saturate((pos == 2 ? w * 0.5 : w) - dIn + 0.5) : 0.0;
        cov = pos == 0 ? outside : (pos == 1 ? inside : max(outside, inside));
    } else if (mode == 2) {
        // Inner shadow: blurred inverse shape, kept inside the layer.
        float a = pixels.read(gid).a * saturate(mask.read(gid).a);
        cov = field.read(gid).r * a;
    } else {
        cov = field.read(gid).r;
    }
    float k = saturate(cov) * u.color.a;
    out.write(float4(u.color.rgb * k, k), gid);
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

/// Marching ants along the 0.5 contour of a selection tile.
///
/// Edges are found by sampling the neighbouring screen pixels (uv derivatives are
/// linear, so they're valid everywhere). Derivatives of the sampled value itself
/// are not: they're computed per 2×2 quad and miss edges that fall between quads.
fragment float4 ants_fragment(QuadOut in [[stage_in]],
                              texture2d<float> selection [[texture(0)]],
                              constant float &time [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    bool inside = selection.sample(s, in.uv).a >= 0.5;
    bool edge = (selection.sample(s, in.uv - dx).a >= 0.5) != inside
             || (selection.sample(s, in.uv + dx).a >= 0.5) != inside
             || (selection.sample(s, in.uv - dy).a >= 0.5) != inside
             || (selection.sample(s, in.uv + dy).a >= 0.5) != inside;
    if (!inside || !edge) discard_fragment();
    float2 p = in.position.xy;
    float dash = fmod(floor((p.x + p.y) / 5.0 + time * 6.0), 2.0);
    return dash > 0.5 ? float4(1.0) : float4(0.0, 0.0, 0.0, 1.0);
}
