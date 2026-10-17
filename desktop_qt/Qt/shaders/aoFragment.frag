#version 440
#extension GL_GOOGLE_include_directive : enable
#include "common.glsl"
float viewZ(float depth, Globals g) {
    return g.clip.x * g.clip.y / ((g.clip.y - g.clip.x) * depth - g.clip.y);
}
vec4 packDepth(float v) {
    if (v <= 0) {
        return vec4(0);
    }
    if (v >= 1) {
        return vec4(1);
    }
    float integer;
    float a = modf(v * 16777216.0, integer);
    float b = modf(integer / 256.0, integer);
    float green = modf(integer / 256.0, integer);
    return vec4(integer / 255.0, green * 256.0 / 255.0, b * 256.0 / 255.0, a);
}
float unpackDepth(vec4 v) {
    return dot(v, vec4(255.0 / 256, 255.0 / 65536, 255.0 / 16777216, 1.0 / 16777216));
}
layout(std140, binding = 1) uniform KernelBlock {
    vec4 aoSamples[32];
};
layout(binding = 2) uniform sampler2D normal;
layout(binding = 3) uniform sampler2D depth;
layout(binding = 4) uniform sampler2D noise;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
vec4 effect() {
    float d = texture(depth, rtUV(v_uv)).r;
    if (d >= 1) {
        return vec4(1);
    }
    float z = viewZ(d, g);
    vec4 p = vec4(v_uv.x * 2 - 1, 1 - v_uv.y * 2, d * 2 - 1, 1) * (-z);
    vec3 pos = (g.aoInverseProjection * p).xyz;
    vec3 N = normalize(texture(normal, rtUV(v_uv)).rgb * 2 - 1);
    float rnd = texture(noise, vec2(v_uv.x, 1 - v_uv.y) * g.viewport.xy / 4).r;
    vec3 tangent = normalize(vec3(rnd) - N * dot(vec3(rnd), N));
    mat3 basis = mat3(tangent, cross(N, tangent), N);
    float occlusion = 0;
    for (int i = 0; i < 32; i++) {
        vec3 point = pos + basis * aoSamples[i].xyz * .38;
        vec4 clip = g.aoProjection * vec4(point, 1);
        vec2 uv = clip.xy / clip.w * .5 + .5;
        uv.y = 1 - uv.y;
        float real = (-viewZ(texture(depth, rtUV(uv)).r, g) - g.clip.x) / (g.clip.y - g.clip.x);
        float proposed = (-point.z - g.clip.x) / (g.clip.y - g.clip.x);
        float delta = proposed - real;
        if (delta > .001 && delta < .09) {
            occlusion += 1;
        }
    }
    return vec4(vec3(1 - occlusion / 32), 1);
}
void main() {
    fragColor = effect();
}
