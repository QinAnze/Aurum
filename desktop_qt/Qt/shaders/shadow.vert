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
void main() {
    mat4 model = mat4(model0, model1, model2, model3);
    vec4 p = g.shadow * model * position;
    gl_Position = correction * vec4(p.x * 2 - p.w, p.w - p.y * 2, p.z * 2 - p.w, p.w);
}
