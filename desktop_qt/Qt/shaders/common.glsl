// 保留原渲染器的 Three.js r183 公式；MIT 归属见 NOTICE。
const float PI = 3.141592653589793;
struct Globals {
    mat4 view;
    mat4 projection;
    mat4 shadow;
    mat4 inverseProjection;
    mat4 aoProjection;
    mat4 aoInverseProjection;
    vec4 eye;
    vec4 fogColor;
    vec4 fog;
    vec4 viewport;
    vec4 clip;
};
struct Surface {
    vec4 color;
    vec4 physical;
    vec4 optics;
    vec4 attenuation;
    vec4 extra;
    vec4 flags;
    vec4 darkColor;
};
struct Out {
    vec4 position;
    vec3 world;
    vec3 normal;
    vec2 uv;
    float height;
    float viewZ;
    float quality;
    float clarity;
    float theme;
    vec4 shadow;
};
layout(std140, binding = 0) uniform GlobalBlock {
    Globals g;
    mat4 correction;
    vec4 backend;
};
vec2 rtUV(vec2 uv) {
    return backend.x > 0.5 ? vec2(uv.x, 1 - uv.y) : uv;
}
#define saturate(x) clamp(x, 0.0, 1.0)
float srgb(float v) {
    return v <= .04045 ? v / 12.92 : pow((v + .055) / 1.055, 2.4);
}
vec3 linearColor(vec3 v) {
    return vec3(srgb(v.x), srgb(v.y), srgb(v.z));
}
vec3 outputColor(vec3 x) {
    return mix(1.055 * pow(max(x, 0.0), vec3(1.0 / 2.4)) - .055, 12.92 * x, lessThanEqual(x, vec3(.0031308)));
}
vec3 aces(vec3 c, float exposure) {
    c *= exposure / .6;
    mat3 acesInput =
        mat3(vec3(.59719, .076, .02840), vec3(.35458, .90834, .13383), vec3(.04823, .01566, .83777));
    mat3 acesOutput = mat3(vec3(1.60475, -.10208, -.00327), vec3(-.53108, 1.10813, -.07276),
                           vec3(-.07367, -.00605, 1.07602));
    c = acesInput * c;
    vec3 a = c * (c + .0245786) - .000090537;
    vec3 b = c * (.983729 * c + .4329510) + .238081;
    return saturate(acesOutput * (a / b));
}
float getFace(vec3 d) {
    vec3 a = abs(d);
    if (a.x > a.z) {
        return a.x > a.y ? (d.x > 0 ? 0 : 3) : (d.y > 0 ? 1 : 4);
    }
    return a.z > a.y ? (d.z > 0 ? 2 : 5) : (d.y > 0 ? 1 : 4);
}
vec2 cubeUV(vec3 d, float f) {
    vec2 uv;
    if (f == 0) {
        uv = vec2(d.z, d.y) / abs(d.x);
    } else if (f == 1) {
        uv = vec2(-d.x, -d.z) / abs(d.y);
    } else if (f == 2) {
        uv = vec2(-d.x, d.y) / abs(d.z);
    } else if (f == 3) {
        uv = vec2(-d.z, d.y) / abs(d.x);
    } else if (f == 4) {
        uv = vec2(-d.x, d.z) / abs(d.y);
    } else {
        uv = vec2(d.x, d.y) / abs(d.z);
    }
    return .5 * (uv + 1);
}
vec3 envMip(sampler2D env, vec3 d, float mip) {
    float face = getFace(d), filterOffset = max(4 - mip, 0.0);
    mip = max(mip, 4.0);
    float size = exp2(mip);
    vec2 uv = cubeUV(d, face) * (size - 2) + 1;
    if (face > 2) {
        uv.y += size;
        face -= 3;
    }
    uv.x += face * size + filterOffset * 48;
    uv.y += 4 * (256 - size);
    uv /= vec2(768, 1024);
    return texture(env, uv).rgb;
}
float roughMip(float r) {
    if (r >= .8) {
        return (1 - r) * 5 - 2;
    }
    if (r >= .4) {
        return (.8 - r) * 7.5 - 1;
    }
    if (r >= .305) {
        return (.4 - r) / .095 + 2;
    }
    if (r >= .21) {
        return (.305 - r) / .095 + 3;
    }
    return -2 * log2(1.16 * max(r, .001));
}
vec3 envSample(sampler2D env, vec3 d, float r) {
    float mip = clamp(roughMip(r), -2.0, 8.0), m = floor(mip);
    return mix(envMip(env, d, m), envMip(env, d, m + 1), fract(mip));
}
vec2 DFG(float nv, float r, sampler2D lut) {
    return texture(lut, vec2(r, nv)).rg;
}
vec3 envBRDF(vec3 f0, float nv, float r, sampler2D lut) {
    vec2 fab = DFG(nv, r, lut);
    return f0 * fab.x + fab.y;
}
vec3 ggx(vec3 N, vec3 V, vec3 L, vec3 f0, float r) {
    vec3 H = normalize(V + L);
    float nv = saturate(dot(N, V));
    float nl = saturate(dot(N, L));
    float nh = saturate(dot(N, H));
    float vh = saturate(dot(V, H));
    float a = r * r;
    float a2 = a * a;
    float gv = nl * sqrt(a2 + (1 - a2) * nv * nv);
    float gl = nv * sqrt(a2 + (1 - a2) * nl * nl);
    float vis = .5 / max(gv + gl, 1e-6);
    float d = a2 / (PI * pow(nh * nh * (a2 - 1) + 1, 2));
    float f = exp2((-5.55473 * vh - 6.98316) * vh);
    return (f0 * (1 - f) + f) * vis * d;
}
vec3 ggxMulti(vec3 N, vec3 V, vec3 L, vec3 f0, float r, sampler2D lut) {
    vec2 v = DFG(saturate(dot(N, V)), r, lut), l = DFG(saturate(dot(N, L)), r, lut);
    vec3 fv = f0 * v.x + v.y;
    vec3 fl = f0 * l.x + l.y;
    vec3 avg = f0 + (1 - f0) * .047619;
    float ev = 1 - v.x - v.y;
    float el = 1 - l.x - l.y;
    return ggx(N, V, L, f0, r) + fv * fl * avg / (1 - ev * el * avg + 1e-6) * ev * el;
}
vec3 multiScatter(vec3 f0, vec2 fab) {
    vec3 ss = f0 * fab.x + fab.y, avg = f0 + (1 - f0) * .047619;
    float ems = 1 - fab.x - fab.y;
    return ss * avg / (1 - ems * avg) * ems;
}
/**
 * 按原五点采样计算阴影覆盖；屏幕坐标按后端方向转换。
 */
float shadowFactor(Out o, sampler2DShadow map, Globals g) {

    vec3 p = o.shadow.xyz / o.shadow.w;
    if (any(lessThan(p.xy, vec2(0))) || any(greaterThan(p.xy, vec2(1))) || p.z > 1) {
        return 1;
    }
    float phi =
        fract(52.9829189 *
              fract(dot(vec2(o.position.x, backend.x > .5 ? o.position.y : g.viewport.y - o.position.y),
                        vec2(.06711056, .00583715)))) *
        2 * PI;
    float total = 0;
    for (int i = 0; i < 5; i++) {
        float theta = float(i) * 2.399963229728653 + phi;
        vec2 offset =
            vec2(cos(theta), -sin(theta)) * sqrt((float(i) + .5) / 5.0) * 4.0 / float(textureSize(map, 0).x);
        total += texture(map, vec3(rtUV(p.xy + offset), p.z - .0003));
    }
    return total * .2;
}
float w0(float a) {
    return (a * (a * (-a + 3) - 3) + 1) / 6;
}
float w1(float a) {
    return (a * a * (3 * a - 6) + 4) / 6;
}
float w2(float a) {
    return (a * (a * (-3 * a + 3) + 3) + 1) / 6;
}
float w3(float a) {
    return a * a * a / 6;
}
vec4 bicubic(sampler2D tex, vec2 uv, float lod) {
    vec2 size = vec2(textureSize(tex, int(lod)).x, textureSize(tex, int(lod)).y);
    vec2 p = uv * size + .5;
    vec2 i = floor(p);
    vec2 a = fract(p);
    vec2 g0 = vec2(w0(a.x) + w1(a.x), w0(a.y) + w1(a.y));
    vec2 g1 = vec2(w2(a.x) + w3(a.x), w2(a.y) + w3(a.y));
    vec2 h0 = -1 + vec2(w1(a.x), w1(a.y)) / g0;
    vec2 h1 = 1 + vec2(w3(a.x), w3(a.y)) / g1;
    vec4 c = g0.y * (g0.x * textureLod(tex, rtUV((i + vec2(h0.x, h0.y) - .5) / size), (lod)) +
                     g1.x * textureLod(tex, rtUV((i + vec2(h1.x, h0.y) - .5) / size), (lod)));
    return c + g1.y * (g0.x * textureLod(tex, rtUV((i + vec2(h0.x, h1.y) - .5) / size), (lod)) +
                       g1.x * textureLod(tex, rtUV((i + vec2(h1.x, h1.y) - .5) / size), (lod)));
}
vec4 transmissionSample(sampler2D tex, vec2 uv, float lod) {
    lod = clamp(lod, 0.0, float(int(floor(log2(float(textureSize(tex, 0).x)))) - 1));
    return mix(bicubic(tex, uv, floor(lod)), bicubic(tex, uv, ceil(lod)), fract(lod));
}
