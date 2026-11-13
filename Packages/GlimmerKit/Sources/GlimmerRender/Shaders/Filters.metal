#include <metal_stdlib>
using namespace metal;

// Destructive pixel filters (Filter menu), ported from the web app's GLSL.
// Textures hold premultiplied linear extended-sRGB. Blurs work there (physically
// correct); the "look" filters convert to display sRGB straight alpha first,
// like Photoshop and the web app.

struct FilterUniforms {
    int kind;
    int pad0;
    float2 texOrigin;    // document position of texel (0, 0)
    float4 a;            // parameters 0-3
    float4 b;            // parameters 4-7
    float2 frameOrigin;  // document frame (vignette / chromatic aberration centre)
    float2 frameSize;
};

constexpr sampler fpx(filter::linear, address::clamp_to_edge, coord::pixel);

static float3 f_l2s(float3 c) {
    float3 a = abs(c);
    float3 e = select(1.055 * pow(a, 1.0 / 2.4) - 0.055, a * 12.92, a <= 0.0031308);
    return sign(c) * e;
}

static float3 f_s2l(float3 c) {
    float3 a = abs(c);
    float3 l = select(pow((a + 0.055) / 1.055, 2.4), a / 12.92, a <= 0.04045);
    return sign(c) * l;
}

static float4 toDisplay(float4 p) {
    float3 rgb = p.a > 1e-6 ? p.rgb / p.a : float3(0);
    return float4(f_l2s(rgb), p.a);
}

static float4 fromDisplay(float4 d) {
    return float4(f_s2l(d.rgb) * d.a, d.a);
}

static float lum(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static float hash2(float2 p, float seed) {
    return fract(sin(dot(p, float2(127.1, 311.7)) + seed) * 43758.5453123);
}

static float halftoneScreen(float2 px, float v, float ang, float cell) {
    float s = sin(ang), co = cos(ang);
    float2 rp = float2(co * px.x + s * px.y, -s * px.x + co * px.y);
    float2 c = fmod(fmod(rp, cell) + cell, cell) - cell * 0.5;
    float radius = (1.0 - saturate(v)) * cell * 0.5 * 1.42;
    return 1.0 - smoothstep(radius - 1.0, radius + 1.0, length(c));
}

// kind: 1 motion, 2 lens, 3 sharpen, 4 unsharp, 5 clarity, 6 noise, 7 pixelate,
// 8 find edges, 9 emboss, 10 oil paint, 11 halftone, 12 vignette, 13 chromatic aberration.
kernel void filter_apply(texture2d<float, access::sample> src [[texture(0)]],
                         texture2d<float, access::sample> aux [[texture(1)]],
                         texture2d<float, access::write> out [[texture(2)]],
                         constant FilterUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 p = float2(gid) + 0.5;
    float2 doc = p + u.texOrigin;
    float4 c = src.sample(fpx, p);
    float4 result = c;

    switch (u.kind) {
    case 1: {  // Motion blur (linear)
        float dist = max(u.a.y, 0.0);
        float ang = u.a.x * M_PI_F / 180.0;
        int n = clamp(int(round(dist)), 1, 255);
        float2 step = float2(cos(ang), sin(ang)) * dist / max(1.0, float(n - 1));
        float mid = float(n - 1) * 0.5;
        float4 sum = 0;
        for (int i = 0; i < n; i++) sum += src.sample(fpx, p + step * (float(i) - mid));
        result = sum / float(n);
        break;
    }
    case 2: {  // Lens blur: golden-angle disc, highlights weighted (linear)
        float radius = u.a.x;
        if (radius < 0.5) break;
        int n = clamp(int(round(radius * radius * 0.9)) + 12, 8, 256);
        float4 sum = 0;
        float wsum = 0;
        for (int i = 0; i < n; i++) {
            float t = (float(i) + 0.5) / float(n);
            float ang = float(i) * 2.39996323;
            float4 s = src.sample(fpx, p + float2(cos(ang), sin(ang)) * sqrt(t) * radius);
            float l = s.a > 1e-6 ? min(dot(s.rgb / s.a, float3(0.2126, 0.7152, 0.0722)), 4.0) : 0.0;
            float w = 1.0 + u.a.y * pow(l, 3.0) * 3.0;
            sum += s * w;
            wsum += w;
        }
        result = sum / wsum;
        break;
    }
    case 3: {  // Sharpen: 4-neighbour Laplacian (display)
        float4 d = toDisplay(c);
        float3 n = toDisplay(src.sample(fpx, p + float2(0, -1))).rgb + toDisplay(src.sample(fpx, p + float2(0, 1))).rgb
                 + toDisplay(src.sample(fpx, p + float2(1, 0))).rgb + toDisplay(src.sample(fpx, p + float2(-1, 0))).rgb;
        d.rgb = saturate(d.rgb + (d.rgb * 4.0 - n) * u.a.x);
        result = fromDisplay(d);
        break;
    }
    case 4: {  // Unsharp mask: aux = Gaussian blur (display difference, threshold)
        float4 d = toDisplay(c);
        float3 diff = d.rgb - toDisplay(aux.sample(fpx, p)).rgb;
        float mag = max(max(abs(diff.r), abs(diff.g)), abs(diff.b));
        if (mag >= u.a.z) d.rgb = saturate(d.rgb + diff * u.a.x);
        result = fromDisplay(d);
        break;
    }
    case 5: {  // Clarity: midtone-weighted large-radius high pass (aux = base blur)
        float4 d = toDisplay(c);
        float3 high = d.rgb - toDisplay(aux.sample(fpx, p)).rgb;
        float l = lum(d.rgb);
        float midtone = 1.0 - pow(saturate(abs(l - 0.5) * 2.0), 2.0);
        d.rgb = saturate(d.rgb + high * u.a.x * 1.5 * midtone);
        result = fromDisplay(d);
        break;
    }
    case 6: {  // Add noise, seeded by document position (stable across tiles and previews)
        float4 d = toDisplay(c);
        float2 q = floor(doc);
        float3 noise = u.a.y > 0.5 ? float3(hash2(q, 137.137) - 0.5)
                                   : float3(hash2(q, 137.137), hash2(q + 17.0, 137.137), hash2(q + 43.0, 137.137)) - 0.5;
        d.rgb = saturate(d.rgb + noise * u.a.x);
        result = fromDisplay(d);
        break;
    }
    case 7: {  // Pixelate: cells aligned to the document origin, cell average via 4×4 samples
        float cell = max(u.a.x, 1.0);
        float2 cellOrigin = floor(doc / cell) * cell;
        float4 sum = 0;
        for (int j = 0; j < 4; j++)
            for (int i = 0; i < 4; i++)
                sum += src.sample(fpx, cellOrigin + (float2(i, j) + 0.5) * cell / 4.0 - u.texOrigin);
        result = sum / 16.0;
        break;
    }
    case 8: {  // Find edges: inverted Sobel magnitude (display)
        float tl = lum(toDisplay(src.sample(fpx, p + float2(-1, -1))).rgb);
        float tm = lum(toDisplay(src.sample(fpx, p + float2(0, -1))).rgb);
        float tr = lum(toDisplay(src.sample(fpx, p + float2(1, -1))).rgb);
        float ml = lum(toDisplay(src.sample(fpx, p + float2(-1, 0))).rgb);
        float mr = lum(toDisplay(src.sample(fpx, p + float2(1, 0))).rgb);
        float bl = lum(toDisplay(src.sample(fpx, p + float2(-1, 1))).rgb);
        float bm = lum(toDisplay(src.sample(fpx, p + float2(0, 1))).rgb);
        float br = lum(toDisplay(src.sample(fpx, p + float2(1, 1))).rgb);
        float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
        float gy = -tl - 2.0 * tm - tr + bl + 2.0 * bm + br;
        result = fromDisplay(float4(float3(1.0 - saturate(length(float2(gx, gy)))), c.a));
        break;
    }
    case 9: {  // Emboss (display)
        float ang = u.a.x * M_PI_F / 180.0;
        float2 dir = float2(cos(ang), sin(ang));
        float e = 0.5 + (lum(toDisplay(src.sample(fpx, p + dir)).rgb) - lum(toDisplay(src.sample(fpx, p - dir)).rgb)) * u.a.y;
        result = fromDisplay(float4(float3(saturate(e)), c.a));
        break;
    }
    case 10: {  // Oil paint: Kuwahara, lowest-variance quadrant mean (display)
        int rad = clamp(int(round(u.a.x)), 1, 10);
        float3 best = 0;
        float bestVar = 1e9;
        for (int q = 0; q < 4; q++) {
            float2 sgn = float2((q & 1) ? 1.0 : -1.0, (q >= 2) ? 1.0 : -1.0);
            float3 sumC = 0;
            float sumL = 0, sumL2 = 0, cnt = 0;
            for (int dy = 0; dy <= rad; dy++)
                for (int dx = 0; dx <= rad; dx++) {
                    float3 s = toDisplay(src.sample(fpx, p + float2(dx, dy) * sgn)).rgb;
                    float l = lum(s);
                    sumC += s; sumL += l; sumL2 += l * l; cnt += 1;
                }
            float m = sumL / cnt;
            float v = sumL2 / cnt - m * m;
            if (v < bestVar) { bestVar = v; best = sumC / cnt; }
        }
        float4 d = toDisplay(c);
        d.rgb = mix(d.rgb, best, saturate(u.a.y));
        result = fromDisplay(d);
        break;
    }
    case 11: {  // Halftone (display), screen anchored to the document
        float4 d = toDisplay(c);
        float cell = max(u.a.x, 2.0);
        float ang = u.a.y * M_PI_F / 180.0;
        if (u.a.z > 0.5) {
            d.rgb = float3(1.0 - halftoneScreen(doc, lum(d.rgb), ang, cell));
        } else {
            float cy = halftoneScreen(doc, d.r, ang + 0.2618, cell);
            float mg = halftoneScreen(doc, d.g, ang + 1.309, cell);
            float yl = halftoneScreen(doc, d.b, ang, cell);
            d.rgb = 1.0 - float3(cy, mg, yl);
        }
        result = fromDisplay(d);
        break;
    }
    case 12: {  // Vignette over the document frame (display)
        float4 d = toDisplay(c);
        float2 v = ((doc - u.frameOrigin) / u.frameSize - 0.5) * 2.0;
        v.x *= mix(u.frameSize.x / u.frameSize.y, 1.0, u.a.z);
        float k = smoothstep(u.a.y, u.a.y + max(u.a.w, 0.01), length(v));
        d.rgb = saturate(d.rgb * (1.0 - k * u.a.x));
        result = fromDisplay(d);
        break;
    }
    case 13: {  // Chromatic aberration: R out, B in, radially from the frame centre
        float2 dir = (doc - u.frameOrigin) / u.frameSize - 0.5;
        float r = length(dir) / 0.7071;
        float falloff = u.a.y > 0.5 ? r * r : r;
        float2 off = normalize(dir + 1e-6) * u.a.x * falloff;
        float4 d = toDisplay(c);
        d.r = toDisplay(src.sample(fpx, p + off)).r;
        d.b = toDisplay(src.sample(fpx, p - off)).b;
        result = fromDisplay(d);
        break;
    }
    default: break;
    }
    out.write(result, gid);
}

struct FilterMixUniforms {
    int2 targetOrigin;    // changed area, in output texels
    int2 targetSize;
    int2 filteredOffset;  // output texel → filtered texel offset
    int hasSelection;
    int pad;
};

/// Writes the original, or the filtered pixel blended by the selection inside the target area.
kernel void filter_mix(texture2d<float, access::read> original [[texture(0)]],
                       texture2d<float, access::read> filtered [[texture(1)]],
                       texture2d<float, access::read> selection [[texture(2)]],
                       texture2d<float, access::write> out [[texture(3)]],
                       constant FilterMixUniforms &u [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float4 o = original.read(gid);
    int2 g = int2(gid);
    if (any(g < u.targetOrigin) || any(g >= u.targetOrigin + u.targetSize)) { out.write(o, gid); return; }
    float4 f = filtered.read(uint2(g + u.filteredOffset));
    float s = u.hasSelection ? saturate(selection.read(gid).a) : 1.0;
    out.write(mix(o, f, s), gid);
}

/// Healing: the cloned texture with the destination's low frequencies:
/// out = clone + blur(destination) − blur(clone).
kernel void heal_combine(texture2d<float, access::read> clone [[texture(0)]],
                         texture2d<float, access::read> destBlur [[texture(1)]],
                         texture2d<float, access::read> cloneBlur [[texture(2)]],
                         texture2d<float, access::write> out [[texture(3)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float4 c = clone.read(gid);
    float4 r = c + destBlur.read(gid) - cloneBlur.read(gid);
    r.a = saturate(r.a);
    r.rgb = max(r.rgb, 0.0);
    out.write(r, gid);
}

struct SmudgeDab {
    float2 centre;   // in working-texture texels
    float2 delta;    // movement since the previous dab
    float radius;
    float hardness;
    float strength;
    float pad;
};

/// Smudge: pulls colour along the stroke direction inside one dab.
kernel void smudge_dab(texture2d<float, access::sample> before [[texture(0)]],
                       texture2d<float, access::write> working [[texture(1)]],
                       texture2d<float, access::sample> selection [[texture(2)]],
                       constant SmudgeDab &d [[buffer(0)]],
                       constant int2 &origin [[buffer(1)]],   // dispatch origin in working texels
                       constant int &hasSelection [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 g = int2(gid) + origin;
    if (g.x < 0 || g.y < 0 || g.x >= int(working.get_width()) || g.y >= int(working.get_height())) return;
    float2 p = float2(g) + 0.5;
    float dist = length(p - d.centre) / max(d.radius, 0.5);
    if (dist >= 1.0) return;
    float edge = mix(0.0, 0.98, saturate(d.hardness));
    float k = 1.0 - smoothstep(edge, 1.0, dist);
    if (hasSelection) k *= saturate(selection.sample(fpx, p).a);
    k *= d.strength;
    float4 here = before.sample(fpx, p);
    float4 dragged = before.sample(fpx, p - d.delta);
    working.write(mix(here, dragged, k), uint2(g));
}

// MARK: Liquify

struct LiquifyBrush {
    float2 centre;      // document px
    float2 delta;       // forward warp movement, document px
    float2 fieldOrigin; // document position of field texel (0, 0)
    float fieldScale;   // document px per field texel
    float radius;       // document px
    float strength;     // 0...1
    int mode;           // 0 forward, 1 restore, 2 pucker, 3 bloat, 4 twirl clockwise, 5 twirl counter-clockwise
    int2 boxOrigin;     // dispatch origin in field texels
};

// The field stores, per output pixel, where to read the source from (relative
// offset in document px): output(p) = source(p + D(p)). A brush moving content
// by o(p) composes as D'(p) = D(p − o) − o, so strokes chain without the
// drift you get from simply adding offsets.
kernel void liquify_brush(texture2d<float, access::sample> field [[texture(0)]],
                          texture2d<float, access::write> next [[texture(1)]],
                          constant LiquifyBrush &b [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 g = int2(gid) + b.boxOrigin;
    if (g.x < 0 || g.y < 0 || g.x >= int(next.get_width()) || g.y >= int(next.get_height())) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 t = float2(g) + 0.5;
    float2 p = b.fieldOrigin + t * b.fieldScale;
    float2 v = p - b.centre;
    float d = length(v) / max(b.radius, 1.0);
    float2 current = field.sample(s, t).xy;
    if (d >= 1.0) { next.write(float4(current, 0, 0), uint2(g)); return; }
    float w = (1.0 - d * d);
    w = w * w * b.strength;
    float2 o = 0;
    switch (b.mode) {
    case 0: o = b.delta * w; break;
    case 1: next.write(float4(current * (1.0 - w * 0.5), 0, 0), uint2(g)); return;
    case 2: o = -v * w * 0.08; break;
    case 3: o = v * w * 0.08; break;
    case 4: case 5: {
        float a = (b.mode == 4 ? 1.0 : -1.0) * w * 0.12;
        float2 r = float2(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y);
        o = r - v;
        break;
    }
    default: break;
    }
    float2 back = field.sample(s, t - o / b.fieldScale).xy;
    next.write(float4(back - o, 0, 0), uint2(g));
}

/// out(p) = source(p + D(p)); `texOrigin` maps output texels to document px.
kernel void liquify_render(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::sample> field [[texture(1)]],
                           texture2d<float, access::write> out [[texture(2)]],
                           constant float4 &geometry [[buffer(0)]],   // source origin (doc), field origin (doc)
                           constant float &fieldScale [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_zero, coord::pixel);
    constexpr sampler fs(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 doc = geometry.xy + float2(gid) + 0.5;
    float2 d = field.sample(fs, (doc - geometry.zw) / fieldScale).xy;
    out.write(source.sample(s, doc + d - geometry.xy), gid);
}
