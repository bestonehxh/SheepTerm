// SheepVTRender — the Metal source, as a Swift string literal.
//
// Compiled once per device with `MTLDevice.makeLibrary(source:options:)`. It is a
// literal on purpose: a `.metal` file has to be compiled into a `default.metallib`
// inside a resource bundle, and a resource bundle is one more thing that can go
// missing when the package is embedded in an app (SwiftTerm ships the same
// shaders as a resource and has the bug reports to show for it).
//
// Two pipelines, both instanced: `vertex_id / 6` is the instance, `vertex_id % 6`
// the corner of its quad, so there is no vertex buffer beyond the instance array.
// Positions are in **points, top-left origin** (the same space `RowBuilder`
// emits); `viewport` is the drawable size in those same units, and the vertex
// functions flip Y into Metal's y-up clip space.
//
// Blending: the background pipeline uses straight alpha (`sourceAlpha` /
// `oneMinusSourceAlpha`) so selection and search tints lay over the cell colour;
// the glyph pipelines are premultiplied (`one` / `oneMinusSourceAlpha`) because
// the fragment multiplies the colour by the atlas coverage. sRGB is handled by
// the layer's colorspace, never here.

nonisolated public enum Shaders {
    /// Vertex/fragment entry points, by name.
    public static let backgroundVertex = "sheep_bg_vertex"
    public static let backgroundFragment = "sheep_bg_fragment"
    public static let glyphVertex = "sheep_glyph_vertex"
    public static let glyphFragmentGray = "sheep_glyph_fragment_gray"
    public static let glyphFragmentBGRA = "sheep_glyph_fragment_bgra"

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Must match SheepVTRender.BackgroundInstance (32 bytes) byte for byte.
    struct BackgroundInstance {
        float2 position;
        float2 size;
        float4 color;
    };

    // Must match SheepVTRender.GlyphInstance (48 bytes) byte for byte.
    struct GlyphInstance {
        float2 position;
        float2 size;
        float2 uvOrigin;
        float2 uvSize;
        float4 color;
    };

    struct BackgroundOut {
        float4 position [[position]];
        float4 color;
    };

    struct GlyphOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    constant float2 kQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0),
    };

    // Points with a top-left origin -> clip space.
    static inline float4 sheep_ndc(float2 point, float2 viewport) {
        return float4((point.x / viewport.x) * 2.0 - 1.0,
                      1.0 - (point.y / viewport.y) * 2.0,
                      0.0,
                      1.0);
    }

    vertex BackgroundOut sheep_bg_vertex(uint vid [[vertex_id]],
                                         const device BackgroundInstance *instances [[buffer(0)]],
                                         constant float2 &viewport [[buffer(1)]]) {
        BackgroundInstance inst = instances[vid / 6];
        float2 corner = kQuadCorners[vid % 6];
        BackgroundOut out;
        out.position = sheep_ndc(inst.position + inst.size * corner, viewport);
        out.color = inst.color;
        return out;
    }

    fragment float4 sheep_bg_fragment(BackgroundOut in [[stage_in]]) {
        return in.color;
    }

    vertex GlyphOut sheep_glyph_vertex(uint vid [[vertex_id]],
                                       const device GlyphInstance *instances [[buffer(0)]],
                                       constant float2 &viewport [[buffer(1)]]) {
        GlyphInstance inst = instances[vid / 6];
        float2 corner = kQuadCorners[vid % 6];
        GlyphOut out;
        out.position = sheep_ndc(inst.position + inst.size * corner, viewport);
        out.uv = inst.uvOrigin + inst.uvSize * corner;
        out.color = inst.color;
        return out;
    }

    // Gray atlas: the texture holds coverage only, the colour comes from the
    // instance. Premultiplied out.
    fragment float4 sheep_glyph_fragment_gray(GlyphOut in [[stage_in]],
                                              texture2d<float> atlas [[texture(0)]],
                                              sampler samp [[sampler(0)]]) {
        float coverage = atlas.sample(samp, in.uv).r;
        return float4(in.color.rgb * coverage, in.color.a * coverage);
    }

    // BGRA atlas (colour emoji): the bitmap already carries its own colour,
    // premultiplied. The instance colour only modulates it.
    fragment float4 sheep_glyph_fragment_bgra(GlyphOut in [[stage_in]],
                                              texture2d<float> atlas [[texture(0)]],
                                              sampler samp [[sampler(0)]]) {
        float4 texel = atlas.sample(samp, in.uv);
        return float4(texel.rgb * in.color.rgb, texel.a * in.color.a);
    }
    """
}
