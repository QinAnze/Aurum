#version 440
#extension GL_GOOGLE_include_directive : enable
#include "common.glsl"
float viewZ(float depth, Globals g) {
    return g.clip.x * g.clip.y / ((g.clip.y - g.clip.x) * depth - g.clip.y);
}
layout(binding = 2) uniform sampler2D color;
layout(binding = 3) uniform sampler2D depth;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
vec4 effect() {
    // 直接读取原生深度附件，避免额外的 RGBA 打包深度图及半精度量化误差。
    float z = viewZ(texture(depth, rtUV(v_uv)).r, g), b = clamp((g.fog.z + z) * g.fog.w, -.011, .011);
    vec2 aspect = vec2(1, g.viewport.x / g.viewport.y);
    vec3 c = texture(color, rtUV(v_uv)).rgb;
    const vec2 offsets[40] = vec2[40](
        vec2(0.0, -0.4), vec2(0.15, -0.37), vec2(0.29, -0.29), vec2(-0.37, -0.15), vec2(0.4, -0.0),
        vec2(0.37, 0.15), vec2(0.29, 0.29), vec2(-0.15, 0.37), vec2(0.0, 0.4), vec2(-0.15, -0.37),
        vec2(-0.29, -0.29), vec2(0.37, -0.15), vec2(-0.4, -0.0), vec2(-0.37, 0.15), vec2(-0.29, 0.29),
        vec2(0.15, 0.37), vec2(0.135, -0.333), vec2(-0.333, -0.135), vec2(0.333, 0.135), vec2(-0.135, 0.333),
        vec2(-0.135, -0.333), vec2(0.333, -0.135), vec2(-0.333, 0.135), vec2(0.135, 0.333),
        vec2(0.20299999999999999, -0.20299999999999999), vec2(0.27999999999999997, -0.0),
        vec2(0.20299999999999999, 0.20299999999999999), vec2(0.0, 0.27999999999999997),
        vec2(-0.20299999999999999, -0.20299999999999999), vec2(-0.27999999999999997, -0.0),
        vec2(-0.20299999999999999, 0.20299999999999999), vec2(0.0, -0.27999999999999997),
        vec2(0.11599999999999999, -0.11599999999999999), vec2(0.16000000000000003, -0.0),
        vec2(0.11599999999999999, 0.11599999999999999), vec2(0.0, 0.16000000000000003),
        vec2(-0.11599999999999999, -0.11599999999999999), vec2(-0.16000000000000003, -0.0),
        vec2(-0.11599999999999999, 0.11599999999999999), vec2(0.0, -0.16000000000000003));
    for (int i = 0; i < 40; i++) {
        c += texture(color, rtUV(v_uv + offsets[i] * aspect * b)).rgb;
    }
    return vec4(c / 41, 1);
}
void main() {
    fragColor = effect();
}
