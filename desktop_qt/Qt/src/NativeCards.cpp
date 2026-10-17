#include "NativeCards.h"
#include <QMatrix4x4>
#include <algorithm>
#include <cstring>

namespace {
double interpolate(double low, double high, double amount) {
    return (1 - amount) * low + amount * high;
}

QJsonArray interpolateColor(const QJsonArray &low, const QJsonArray &high, double amount) {
    QJsonArray result;
    for (int i = 0; i < 3; ++i) {
        const auto start = low[i].toDouble();
        result.append(start + (high[i].toDouble() - start) * amount);
    }
    return result;
}

QMatrix4x4 localMatrix(const QJsonArray &values) {
    QMatrix4x4 result;
    for (int i = 0; i < 16; ++i) {
        result(i % 4, i / 4) = float(values[i].toDouble());
    }
    return result;
}
}

/**
 * 共享卡片模板与紧凑根状态
 * 每张卡片只传一份根矩阵；局部偏移仅对标签等非单位部件计算。
 */
QString NativeCards::expand(QJsonObject &frame, const QByteArray &bytes, SceneDrawBuffers &buffers) {
    if (frame.contains("actorTemplate")) {
        parts = frame["actorTemplate"].toArray();
    }
    const auto cards = frame["actors"].toArray();
    constexpr qsizetype stride = 20;
    if (parts.isEmpty() || bytes.size() != cards.size() * stride * qsizetype(sizeof(double))) {
        return QStringLiteral("Invalid native card packet");
    }
    auto draws = frame["draws"].toArray();
    for (qsizetype index = 0; index < cards.size(); ++index) {
        double state[stride];
        memcpy(state, bytes.constData() + index * stride * sizeof(double), sizeof(state));
        const auto card = cards[index].toObject();
        const auto quality = state[16];
        const auto clarity = std::clamp(state[17], 0., 1.);
        const auto theme = state[18];
        const auto subdued = std::clamp(state[19], 0., 1.);
        float matrixValues[16];
        for (int i = 0; i < 16; ++i) {
            matrixValues[i] = float(state[i]);
        }
        const QByteArray rootBytes(reinterpret_cast<const char *>(matrixValues), sizeof(matrixValues));
        for (const auto &entry : parts) {
            const auto part = entry.toObject();
            const bool shadowOnly = card["shadowOnly"].toBool();
            if (shadowOnly && !part["castShadow"].toBool()) {
                continue;
            }
            auto draw = part["base"].toObject();
            const auto high = part["high"].toObject();
            const auto low = part["low"].toObject();
            if (!high.isEmpty() && !low.isEmpty()) {
                draw["color"] = interpolateColor(low["color"].toArray(), high["color"].toArray(), quality);
                draw["attenuation"] =
                    interpolateColor(low["attenuation"].toArray(), high["attenuation"].toArray(), quality);
                draw["attenuationDistance"] =
                    part["interpolateAttenuation"].toBool()
                        ? interpolate(low["attenuationDistance"].toDouble(),
                                      high["attenuationDistance"].toDouble(), quality)
                        : high["attenuationDistance"].toDouble();
                for (const auto &key : {"roughness", "metalness", "transmission", "thickness", "clearcoat",
                                        "clearcoatRoughness"}) {
                    draw[key] = interpolate(low[key].toDouble(), high[key].toDouble(), quality);
                }
                if (high["transmission"].toDouble() > 0) {
                    draw["transmission"] = std::max(0.000001, draw["transmission"].toDouble());
                }
            } else if (high.isEmpty()) {
                draw["opacity"] = quality;
            }
            if (part["name"] == "Frosted_Polymer") {
                for (const auto &key : {"thickness", "transmission", "attenuationDistance"}) {
                    const auto baseline =
                        interpolate(low.isEmpty() ? high[key].toDouble() : low[key].toDouble(),
                                    high[key].toDouble(), quality);
                    double target = 8;
                    if (std::strcmp(key, "thickness") == 0) {
                        target = .018;
                    } else if (std::strcmp(key, "transmission") == 0) {
                        target = .985;
                    }
                    draw[key] = interpolate(baseline, target, clarity);
                }
            }
            const auto id = -(card["id"].toInt() * 256 + part["partIndex"].toInt() + 1);
            draw["id"] = id;
            for (const auto &key : {"mesh", "asset", "label", "name", "transparent", "depthWrite", "order",
                                    "side", "castShadow"}) {
                draw[key] = part[key];
            }
            draw["musicKey"] = card["musicKey"];
            draw["musicSelected"] = card["selected"];
            draw["shadowOnly"] = shadowOnly;
            draw["instanced"] = false;
            draw["floor"] = false;
            draw["count"] = 1;
            if (high.isEmpty()) {
                draw["quality"] = part["hasMap"].toBool() ? 1 : 0;
            } else {
                draw["quality"] = quality;
            }
            draw["clarity"] = high.isEmpty() ? 0 : clarity;
            draw["theme"] = theme;
            draw["subdued"] = high.isEmpty() ? frame["globalSubdued"] : QJsonValue(subdued);
            draw["matrices"] = QJsonArray();
            draw["themes"] = QJsonArray();
            draw["matrixBuffer"] = -1;
            draw["themeBuffer"] = -1;
            auto local = localMatrix(part["localMatrix"].toArray());
            QByteArray matrixBytes = rootBytes;
            if (!local.isIdentity()) {
                // 使用双精度执行原脚本的矩阵乘法，再压成 GPU Float32，保持同帧数值一致。
                const auto values = part["localMatrix"].toArray();
                for (int column = 0; column < 4; ++column) {
                    for (int row = 0; row < 4; ++row) {
                        double value = 0;
                        for (int k = 0; k < 4; ++k) {
                            value += state[k * 4 + row] * values[column * 4 + k].toDouble();
                        }
                        matrixValues[column * 4 + row] = float(value);
                    }
                }
                matrixBytes = QByteArray(reinterpret_cast<const char *>(matrixValues), sizeof(matrixValues));
            }
            buffers.insert(id, {matrixBytes, {}});
            draws.append(draw);
        }
    }
    frame["draws"] = draws;
    frame.remove("actorTemplate");
    frame.remove("actors");
    return {};
}
