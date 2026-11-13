#include <metal_stdlib>
using namespace metal;

// Must match `CanvasUniforms` in CanvasRenderer.swift.
struct CanvasUniforms {
    float3x3 pixelToDocument;   // drawable pixel (y-down) -> document pixel
    float2 documentSize;
    float checkerSize;          // drawable pixels per checker square
    float documentPerPixel;     // document pixels per drawable pixel (for AA)
    float4 pasteboard;          // linear, premultiplied
    float4 checkerLight;
    float4 checkerDark;
};

struct CanvasVertexOut {
    float4 position [[position]];
};

// Full-screen triangle; no vertex buffer needed.
vertex CanvasVertexOut canvas_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    CanvasVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment float4 canvas_fragment(CanvasVertexOut in [[stage_in]],
                                constant CanvasUniforms &u [[buffer(0)]]) {
    float2 pixel = in.position.xy;  // pixel centre, origin top-left
    float2 doc = (u.pixelToDocument * float3(pixel, 1.0)).xy;

    // Distance outside the document rect, in drawable pixels (negative inside).
    float2 outside = max(-doc, doc - u.documentSize);
    float distancePx = max(outside.x, outside.y) / u.documentPerPixel;
    float coverage = clamp(0.5 - distancePx, 0.0, 1.0);

    // Checkerboard is fixed in screen space, like every pro editor.
    int2 cell = int2(floor(pixel / u.checkerSize));
    float4 checker = ((cell.x + cell.y) & 1) ? u.checkerDark : u.checkerLight;

    return mix(u.pasteboard, checker, coverage);
}
