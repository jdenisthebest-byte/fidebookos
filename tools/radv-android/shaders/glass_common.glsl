#ifndef FIDEBOOK_GLASS_COMMON_GLSL
#define FIDEBOOK_GLASS_COMMON_GLSL

// Shared with the driver's C push constants: exactly 32 bytes, including reserved.
// Explicit offsets and build_shaders.sh SPIR-V reflection prevent ABI drift.
layout(push_constant, std430) uniform PC {
    layout(offset = 0) ivec2 dims;
    layout(offset = 8) int ov_count;
    layout(offset = 12) int level;
    layout(offset = 16) int bg_valid;
    layout(offset = 20) int bg_swizzle;
    layout(offset = 24) int blur_px;
    layout(offset = 28) int reserved;
} pc;

bool is_taskbar_carrier(vec4 v) {
    if (v.a < 0.94) return false;
    // FideBookGlassLauncherOverlay taskbar_background, in RGBA or BGRA order.
    vec3 dark_rgba  = vec3(17.0 / 255.0, 25.0 / 255.0, 39.0 / 255.0);
    vec3 dark_bgra  = vec3(39.0 / 255.0, 25.0 / 255.0, 17.0 / 255.0);
    vec3 light_rgba = vec3(235.0 / 255.0, 243.0 / 255.0, 1.0);
    vec3 light_bgra = vec3(1.0, 243.0 / 255.0, 235.0 / 255.0);
    vec3 d0 = abs(v.rgb - dark_rgba);
    vec3 d1 = abs(v.rgb - dark_bgra);
    vec3 l0 = abs(v.rgb - light_rgba);
    vec3 l1 = abs(v.rgb - light_bgra);
    float err = min(min(max(d0.r, max(d0.g, d0.b)), max(d1.r, max(d1.g, d1.b))),
                    min(max(l0.r, max(l0.g, l0.b)), max(l1.r, max(l1.g, l1.b))));
    return err <= 0.036;
}

#endif
