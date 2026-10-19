#version 440
#extension GL_GOOGLE_include_directive : enable
#include "common.glsl"
layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in float v_height;
layout(location = 4) in float v_viewZ;
layout(location = 5) in float v_quality;
layout(location = 6) in float v_clarity;
layout(location = 7) in float v_theme;
layout(location = 8) in vec4 v_shadow;
Out interpolated() {
    return Out(gl_FragCoord, v_world, v_normal, v_uv, v_height, v_viewZ, v_quality, v_clarity, v_theme,
               v_shadow);
}
layout(location = 0) out vec4 normalColor;
void main() {
    vec3 normal = normalize((g.view * vec4(v_normal, 0)).xyz);
    normalColor = vec4(normal * .5 + .5, 1);
}
