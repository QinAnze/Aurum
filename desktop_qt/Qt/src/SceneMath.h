#pragma once
#include <QByteArray>
#include <QJsonArray>
#include <array>

namespace SceneMath {
struct Vector {
    double x = 0;
    double y = 0;
    double z = 0;
    Vector operator+(Vector other) const;
    Vector operator-(Vector other) const;
    Vector operator*(double scale) const;
    double dot(Vector other) const;
    Vector cross(Vector other) const;
    double length() const;
    Vector normalized() const;
    Vector lerp(Vector other, double amount) const;
    QJsonArray json() const;
};

// 按 OpenGL 列主序存储双精度矩阵，只在提交 GPU 时压为 Float32。
struct Matrix {
    std::array<double, 16> values{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    static Matrix compose(Vector position, Vector rotation, Vector scale = {1, 1, 1});
    static Matrix perspective(double fovDegrees, double aspect, double near, double far);
    static Matrix camera(Vector position, Vector target);
    Matrix operator*(const Matrix &other) const;
    Matrix inverse() const;
    Vector point(Vector point) const;
    Vector direction(Vector vector) const;
    QJsonArray json() const;
    QByteArray bytes() const;
};

class Frustum {
  public:
    explicit Frustum(const Matrix &projectionView);
    bool intersects(Vector minimum, Vector maximum) const;
    bool intersectsSphere(Vector center, double radius) const;

  private:
    std::array<std::array<double, 4>, 6> m_planes;
};
}
