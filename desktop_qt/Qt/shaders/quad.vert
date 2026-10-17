#version 440
#extension GL_GOOGLE_include_directive : enable
#include "common.glsl"
layout(location = 0) out vec2 v_uv;
void main() {
    int id = gl_VertexIndex;
    vec2 p = vec2(id == 2 ? 3 : -1, id == 1 ? 3 : -1);
    gl_Position = correction * vec4(p, 0, 1);
    v_uv = vec2((p.x + 1) * .5, 1 - (p.y + 1) * .5);
}
