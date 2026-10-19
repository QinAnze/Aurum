#version 440
#extension GL_GOOGLE_include_directive : enable
#include "common.glsl"
layout(location = 0) in vec4 position;
layout(location = 1) in vec4 normal;
layout(location = 2) in vec4 uv;
layout(location = 3) in vec4 model0;
layout(location = 4) in vec4 model1;
layout(location = 5) in vec4 model2;
layout(location = 6) in vec4 model3;
layout(location = 7) in vec4 state;
layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out float v_height;
layout(location = 4) out float v_viewZ;
layout(location = 5) out float v_quality;
layout(location = 6) out float v_clarity;
layout(location = 7) out float v_theme;
layout(location = 8) out vec4 v_shadow;
void main() {
    mat4 model = mat4(model0, model1, model2, model3);
    vec4 w = model * position;
    v_world = w.xyz;
    v_normal = normalize((model * vec4(normal.xyz, 0)).xyz);
    vec4 eye = g.view * w;
    gl_Position = correction * g.projection * eye;
    v_shadow = g.shadow * vec4(w.xyz + v_normal * .035, 1);
    v_uv = uv.xy;
    v_height = position.y / 3.7;
    v_viewZ = -eye.z;
    v_quality = state.x;
    v_clarity = state.y;
    v_theme = state.z;
}
