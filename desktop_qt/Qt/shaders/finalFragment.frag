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
layout(binding = 2) uniform sampler2D color;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
vec4 effect() {
    float theme = g.viewport.z;
    vec3 rgb = outputColor(aces(texture(color, rtUV(v_uv)).rgb, mix(1.05, .98, theme)));
    float shade = g.clip.z;
    if (g.viewport.w < 0.5 && g.clip.w < 0.5) {
        vec3 paper = mix(vec3(232, 229, 225) / 255, vec3(17, 24, 27) / 255, theme);
        float top = mix(.35 * (1 - saturate(v_uv.y / .38)), .82 * (1 - saturate(v_uv.y / .36)), theme);
        rgb = mix(rgb, mix(vec3(234, 231, 226) / 255, paper, theme), top * (1 - shade));
        float bottom = .84 * (1 - saturate((1 - v_uv.y) / .25)) * theme;
        rgb = mix(rgb, paper, bottom * (1 - shade));
        float radius = length((v_uv - vec2(.42, .47)) / vec2(.58, .53)) / sqrt(2.0);
        float darkRadius = length((v_uv - vec2(.48, .48)) / vec2(.58, .53)) / sqrt(2.0);
        float edge = mix(.19 * saturate((radius - .32) / (.85 - .32)),
                         .48 * saturate((darkRadius - .42) / (.90 - .42)), theme);
        rgb = mix(rgb, paper, edge * (1 - shade));
        float side = v_uv.x < .59   ? mix(0.0, .2, saturate((v_uv.x - .4) / .19))
                     : v_uv.x < .68 ? mix(.2, .92, (v_uv.x - .59) / .09)
                                    : mix(.92, 1.0, (v_uv.x - .68) / .32);
        rgb = mix(rgb, paper, side * shade);
    }
    return vec4(rgb, 1);
}
void main() {
    fragColor = effect();
}
