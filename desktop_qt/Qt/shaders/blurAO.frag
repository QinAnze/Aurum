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
layout(binding = 2) uniform sampler2D ao;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;
vec4 effect() {
    vec2 px = 1.0 / vec2(textureSize(ao, 0).x, textureSize(ao, 0).y);
    float c = 0;
    for (int y = -2; y <= 1; y++) {
        for (int x = -2; x <= 1; x++) {
            c += texture(ao, rtUV(v_uv + vec2(x, -y) * px)).r;
        }
    }
    return vec4(vec3(c / 16), 1);
}
void main() {
    fragColor = effect();
}
