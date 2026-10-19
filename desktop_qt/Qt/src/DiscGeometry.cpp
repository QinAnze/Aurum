#include "DiscGeometry.h"
#include <QVector3D>
#include <cmath>
#include <numbers>

QByteArray DiscGeometry::Mesh::bytes() const {
    return QByteArray(reinterpret_cast<const char *>(vertices.data()),
                      qsizetype(vertices.size() * sizeof(float)));
}

DiscGeometry::Mesh DiscGeometry::annulus(float inner, float outer, float front, float back, bool solid) {
    Mesh mesh;
    auto point = [](float radius, float angle, float z) {
        return QVector3D(CenterX + radius * std::cos(angle), CenterY + radius * std::sin(angle), z);
    };
    auto vertex = [&](QVector3D p, QVector3D normal) {
        // 盘面封面使用正方形中心裁切 UV；孔由真实几何留空，不使用透明贴图伪装。
        float values[] = {p.x(),
                          p.y(),
                          p.z(),
                          1,
                          normal.x(),
                          normal.y(),
                          normal.z(),
                          0,
                          .5f + (p.x() - CenterX) / (2 * PrintRadius),
                          .5f + (p.y() - CenterY) / (2 * PrintRadius),
                          0,
                          0};
        mesh.vertices.insert(mesh.vertices.end(), std::begin(values), std::end(values));
    };
    auto triangle = [&](QVector3D a, QVector3D b, QVector3D c, QVector3D normal) {
        vertex(a, normal);
        vertex(b, normal);
        vertex(c, normal);
    };
    for (int i = 0; i < Segments; ++i) {
        const float a = 2 * std::numbers::pi_v<float> * i / Segments;
        const float b = 2 * std::numbers::pi_v<float> * (i + 1) / Segments;
        auto p = point(inner, a, front);
        auto q = point(outer, a, front);
        auto r = point(outer, b, front);
        auto s = point(inner, b, front);
        triangle(p, q, r, {0, 0, 1});
        triangle(p, r, s, {0, 0, 1});
        if (!solid) {
            continue;
        }
        auto pb = point(inner, a, back);
        auto qb = point(outer, a, back);
        auto rb = point(outer, b, back);
        auto sb = point(inner, b, back);
        triangle(pb, rb, qb, {0, 0, -1});
        triangle(pb, sb, rb, {0, 0, -1});
        const QVector3D radial(std::cos((a + b) / 2), std::sin((a + b) / 2), 0);
        triangle(q, qb, rb, radial);
        triangle(q, rb, r, radial);
        triangle(p, sb, pb, -radial);
        triangle(p, s, sb, -radial);
    }
    return mesh;
}

bool DiscGeometry::validate() {
    auto mesh = annulus(HoleRadius, Radius, .10f, .055f);
    if (mesh.count() != Segments * 24 || Radius >= CenterY || Radius >= 3.7f - CenterY) {
        return false;
    }
    double x = 0;
    double y = 0;
    for (size_t i = 0; i < mesh.vertices.size(); i += 12) {
        auto px = mesh.vertices[i];
        auto py = mesh.vertices[i + 1];
        const auto radius = std::hypot(px - CenterX, py - CenterY);
        if (px < -2.5 || px > 2.5 || py < 0 || py > 3.7 || radius < HoleRadius - .00001 ||
            radius > Radius + .00001) {
            return false;
        }
        x += px;
        y += py;
    }
    return std::abs(x / mesh.count() - CenterX) < .00001 && std::abs(y / mesh.count() - CenterY) < .00001;
}
