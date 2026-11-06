#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Rings of light that ripple out from the centre, like the pulse of a tap. Each ring is born small,
// brightens, travels outward and fades; a slow wave along its edge keeps it reading as light rather
// than a drawn circle. `intensity` scales everything (idle glow ≈ 0.2, full burst ≈ 1.4).
[[ stitchable ]] half4 flickRings(float2 position, half4 color, float2 size, float time, float intensity) {
    float2 uv = (position * 2.0 - size) / min(size.x, size.y);
    float r = length(uv);
    float a = atan2(uv.y, uv.x);
    const int rings = 6;
    float glow = 0.0;
    for (int i = 0; i < rings; i++) {
        float phase = fract(time * 0.035 + float(i) / float(rings));
        float radius = 0.12 + phase * 1.15;
        float wave = 0.016 * sin(a * 7.0 + time * 0.25 + float(i) * 2.1)
                   + 0.009 * sin(a * 13.0 - time * 0.4 + float(i));
        float life = smoothstep(0.0, 0.15, phase) * (1.0 - phase);
        glow += life * 0.006 / (abs(r - radius - wave) + 0.003);
        glow += life * 0.0012 / (abs(r - radius * 0.94 - wave) + 0.006);   // faint echo just inside
    }
    float l = clamp(glow, 0.0, 4.0);
    float3 orange = float3(1.0, 0.42, 0.0);
    // Bright cores go warm white, the falloff stays orange.
    float3 tint = mix(orange * l, float3(1.0, 0.86, 0.7) * l, smoothstep(0.9, 2.6, l));
    // Fade the edges so it sits in its container without a hard border.
    float vignette = smoothstep(1.25, 0.25, r);
    return half4(half3(tint * intensity * vignette), 1.0);
}

// Soft film grain for flat black surfaces.
[[ stitchable ]] half4 flickGrain(float2 position, half4 color, float time, float amount) {
    float n = fract(sin(dot(position + time * 13.0, float2(12.9898, 78.233))) * 43758.5453);
    return half4(color.rgb + half3((n - 0.5) * amount), color.a);
}
