#include "SceneMath.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numbers>

namespace SceneMath {
Vector Vector::operator+(Vector other) const {
    return {x + other.x, y + other.y, z + other.z};
}
Vector Vector::operator-(Vector other) const {
    return {x - other.x, y - other.y, z - other.z};
}
Vector Vector::operator*(double scale) const {
    return {x * scale, y * scale, z * scale};
}
double Vector::dot(Vector other) const {
    return x * other.x + y * other.y + z * other.z;
}
Vector Vector::cross(Vector other) const {
    return {y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x};
}
double Vector::length() const {
    return std::sqrt(x * x + y * y + z * z);
}
Vector Vector::normalized() const {
    const auto size = length();
    return *this * (size == 0 ? 1 : 1 / size);
}
Vector Vector::lerp(Vector other, double amount) const {
    return {x + (other.x - x) * amount, y + (other.y - y) * amount, z + (other.z - z) * amount};
}
QJsonArray Vector::json() const {
    return {x, y, z};
}

Matrix Matrix::compose(Vector position, Vector rotation, Vector scale) {
    const auto c1 = std::cos(rotation.x / 2);
    const auto c2 = std::cos(rotation.y / 2);
    const auto c3 = std::cos(rotation.z / 2);
    const auto s1 = std::sin(rotation.x / 2);
    const auto s2 = std::sin(rotation.y / 2);
    const auto s3 = std::sin(rotation.z / 2);
    const auto x = s1 * c2 * c3 + c1 * s2 * s3;
    const auto y = c1 * s2 * c3 - s1 * c2 * s3;
    const auto z = c1 * c2 * s3 + s1 * s2 * c3;
    const auto w = c1 * c2 * c3 - s1 * s2 * s3;
    const auto x2 = x + x;
    const auto y2 = y + y;
    const auto z2 = z + z;
    const auto xx = x * x2;
    const auto xy = x * y2;
    const auto xz = x * z2;
    const auto yy = y * y2;
    const auto yz = y * z2;
    const auto zz = z * z2;
    const auto wx = w * x2;
    const auto wy = w * y2;
    const auto wz = w * z2;
    return {{(1 - (yy + zz)) * scale.x, (xy + wz) * scale.x, (xz - wy) * scale.x, 0, (xy - wz) * scale.y,
             (1 - (xx + zz)) * scale.y, (yz + wx) * scale.y, 0, (xz + wy) * scale.z, (yz - wx) * scale.z,
             (1 - (xx + yy)) * scale.z, 0, position.x, position.y, position.z, 1}};
}
Matrix Matrix::perspective(double fov, double aspect, double near, double far) {
    const auto top = near * std::tan(std::numbers::pi / 180 * 0.5 * fov);
    const auto height = 2 * top;
    const auto width = aspect * height;
    const auto left = -0.5 * width;
    const auto right = left + width;
    const auto bottom = top - height;
    const auto x = 2 * near / (right - left);
    const auto y = 2 * near / (top - bottom);
    const auto a = (right + left) / (right - left);
    const auto b = (top + bottom) / (top - bottom);
    const auto c = -(far + near) / (far - near);
    const auto d = -2 * far * near / (far - near);
    return {{x, 0, 0, 0, 0, y, 0, 0, a, b, c, -1, 0, 0, d, 0}};
}
Matrix Matrix::camera(Vector position, Vector target) {
    auto z = position - target;
    if (z.length() == 0) {
        z.z = 1;
    }
    z = z.normalized();
    const Vector up{0, 1, 0};
    auto x = up.cross(z);
    if (x.length() == 0) {
        z.z += 0.0001;
        z = z.normalized();
        x = up.cross(z);
    }
    x = x.normalized();
    const auto y = z.cross(x);
    return {{x.x, x.y, x.z, 0, y.x, y.y, y.z, 0, z.x, z.y, z.z, 0, position.x, position.y, position.z, 1}};
}
Matrix Matrix::operator*(const Matrix &other) const {
    Matrix result;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            double value = 0;
            for (int k = 0; k < 4; ++k) {
                value += values[k * 4 + row] * other.values[column * 4 + k];
            }
            result.values[column * 4 + row] = value;
        }
    }
    return result;
}

/** 带主元选择的双精度逆矩阵；奇异输入返回零矩阵，调用者不使用失效的投影。 */
Matrix Matrix::inverse() const {
    double rows[4][8]{};
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            rows[row][column] = values[column * 4 + row];
        }
        rows[row][row + 4] = 1;
    }
    for (int column = 0; column < 4; ++column) {
        int pivot = column;
        for (int row = column + 1; row < 4; ++row) {
            if (std::abs(rows[row][column]) > std::abs(rows[pivot][column])) {
                pivot = row;
            }
        }
        if (rows[pivot][column] == 0) {
            Matrix result;
            result.values.fill(0);
            return result;
        }
        if (pivot != column) {
            for (int index = 0; index < 8; ++index) {
                std::swap(rows[pivot][index], rows[column][index]);
            }
        }
        const auto divisor = rows[column][column];
        for (auto &value : rows[column]) {
            value /= divisor;
        }
        for (int row = 0; row < 4; ++row) {
            if (row == column) {
                continue;
            }
            const auto factor = rows[row][column];
            for (int index = 0; index < 8; ++index) {
                rows[row][index] -= factor * rows[column][index];
            }
        }
    }
    Matrix result;
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            result.values[column * 4 + row] = rows[row][column + 4];
        }
    }
    return result;
}
Vector Matrix::point(Vector point) const {
    const auto &m = values;
    const auto w = 1 / (m[3] * point.x + m[7] * point.y + m[11] * point.z + m[15]);
    return {(m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12]) * w,
            (m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13]) * w,
            (m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]) * w};
}
Vector Matrix::direction(Vector vector) const {
    const auto &m = values;
    return Vector{m[0] * vector.x + m[4] * vector.y + m[8] * vector.z,
                  m[1] * vector.x + m[5] * vector.y + m[9] * vector.z,
                  m[2] * vector.x + m[6] * vector.y + m[10] * vector.z}
        .normalized();
}
QJsonArray Matrix::json() const {
    QJsonArray result;
    for (const auto value : values) {
        result.append(value);
    }
    return result;
}
QByteArray Matrix::bytes() const {
    std::array<float, 16> result;
    std::transform(values.begin(), values.end(), result.begin(), [](double value) { return float(value); });
    return QByteArray(reinterpret_cast<const char *>(result.data()), sizeof(result));
}
Frustum::Frustum(const Matrix &matrix) {
    const auto &m = matrix.values;
    for (int index = 0; index < 6; ++index) {
        const auto component = index / 2;
        const auto sign = index % 2 == 0 ? -1 : 1;
        auto &plane = m_planes[index];
        for (int column = 0; column < 4; ++column) {
            plane[column] = m[column * 4 + 3] + sign * m[column * 4 + component];
        }
        const auto length = std::sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        for (auto &value : plane) {
            value /= length;
        }
    }
}
bool Frustum::intersects(Vector minimum, Vector maximum) const {
    for (const auto &plane : m_planes) {
        const auto x = plane[0] > 0 ? maximum.x : minimum.x;
        const auto y = plane[1] > 0 ? maximum.y : minimum.y;
        const auto z = plane[2] > 0 ? maximum.z : minimum.z;
        if (plane[0] * x + plane[1] * y + plane[2] * z + plane[3] < 0) {
            return false;
        }
    }
    return true;
}
bool Frustum::intersectsSphere(Vector center, double radius) const {
    for (const auto &plane : m_planes) {
        if (plane[0] * center.x + plane[1] * center.y + plane[2] * center.z + plane[3] < -radius) {
            return false;
        }
    }
    return true;
}

}
