#include "SceneMotion.h"
#include "SceneMath.h"
#include "SceneDrag.h"
#include <QDebug>
#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <cmath>

namespace {
bool equal(const QJsonValue &actual, const QJsonValue &expected) {
    if (actual.type() != expected.type()) {
        return false;
    }
    if (actual.isDouble()) {
        return std::abs(actual.toDouble() - expected.toDouble()) <=
               1e-10 * std::max(1.0, std::abs(expected.toDouble()));
    }
    if (actual.isArray()) {
        const auto left = actual.toArray();
        const auto right = expected.toArray();
        if (left.size() != right.size()) {
            return false;
        }
        for (int index = 0; index < left.size(); ++index) {
            if (!equal(left.at(index), right.at(index))) {
                return false;
            }
        }
        return true;
    }
    if (actual.isObject()) {
        const auto left = actual.toObject();
        const auto right = expected.toObject();
        if (left.keys() != right.keys()) {
            return false;
        }
        for (auto entry = left.begin(); entry != left.end(); ++entry) {
            if (!equal(entry.value(), right[entry.key()])) {
                return false;
            }
        }
        return true;
    }
    return actual == expected;
}
}

/** 原测量帧和中间采样验证曲线，连续状态序列覆盖打断、重入及减少动态效果。 */
bool runSceneMotionChecks(const QString &fixture) {
    QFile source(fixture);
    QFile tracks(":/animation/boot-tracks.json");
    if (!source.open(QIODevice::ReadOnly) || !tracks.open(QIODevice::ReadOnly)) {
        qCritical() << "Missing native scene motion fixture" << fixture;
        return false;
    }
    const auto document = QJsonDocument::fromJson(qUncompress(source.readAll())).object();
    SceneMotion::BootTimeline boot(QJsonDocument::fromJson(tracks.readAll()).object());
    bool ok = true;
    const auto check = [&ok](bool value, const char *name, double time) {
        if (!value) {
            qCritical() << "Native scene motion:" << name << time;
        }
        ok &= value;
    };
    for (const auto &entry : document["boot"].toArray()) {
        const auto sample = entry.toObject();
        check(equal(boot.sample(sample["time"].toDouble()), sample["value"]), "boot",
              sample["time"].toDouble());
    }
    SceneMotion::Decryption decryption;
    int index = 0;
    for (const auto &entry : document["decryption"].toArray()) {
        const auto sample = entry.toObject();
        const auto method = sample["method"].toString();
        const auto args = sample["args"].toArray();
        if (method == "enter") {
            decryption.enter(!args.isEmpty() && args.at(0).toBool());
        } else if (method == "leave") {
            decryption.leave();
        } else if (method == "select") {
            decryption.select(args.at(0).toDouble());
        } else if (method == "update") {
            const auto reference =
                args.size() > 3 ? std::optional<double>(args.at(3).toDouble()) : std::nullopt;
            decryption.update(args.at(0).toDouble(), args.at(1).toBool(), args.at(2).toBool(), reference);
        }
        check(equal(decryption.clarity, sample["clarity"]) && equal(decryption.frame, sample["frame"]),
              "decryption", index++);
    }
    for (const auto &entry : document["field"].toArray()) {
        const auto sample = entry.toObject();
        const auto value = SceneMotion::cinematicField(sample["row"].toDouble(), sample["lane"].toDouble(),
                                                       sample["time"].toDouble());
        check(equal(value, sample["value"]), "field", sample["time"].toDouble());
    }
    SceneMotion::Spring spring{2.8, -4.2};
    for (const auto &entry : document["spring"].toArray()) {
        const auto sample = entry.toObject();
        spring.damp(sample["target"].toDouble(), sample["rate"].toDouble(), sample["seconds"].toDouble());
        check(equal(spring.value, sample["value"]) && equal(spring.velocity, sample["velocity"]), "spring",
              0);
    }
    SceneMotion::ThemeWave theme;
    for (const auto &entry : document["theme"].toArray()) {
        const auto sample = entry.toObject();
        const auto time = sample["time"].toDouble();
        if (sample["method"] == "set") {
            const auto origin = sample["origin"].toObject();
            theme.set(sample["dark"].toBool(), time, {origin["lane"].toInt(), origin["row"].toInt()});
            continue;
        }
        theme.beginFrame();
        check(equal(theme.background(time), sample["background"]), "theme background", time);
        for (const auto &entry : sample["cells"].toArray()) {
            const auto cell = entry.toObject();
            check(equal(theme.sample({cell["lane"].toInt(), cell["row"].toInt()}, time), cell["value"]),
                  "theme cell", time);
        }
    }
    const auto vector = [](QJsonValue value) {
        const auto array = value.toArray();
        return SceneMath::Vector{array.at(0).toDouble(), array.at(1).toDouble(), array.at(2).toDouble()};
    };
    for (const auto &entry : document["math"].toArray()) {
        const auto sample = entry.toObject();
        const auto matrix = SceneMath::Matrix::compose(vector(sample["position"]), vector(sample["rotation"]),
                                                       vector(sample["scale"]));
        check(equal(matrix.json(), sample["matrix"]), "matrix", 0);
        check(equal(matrix.inverse().json(), sample["inverse"]), "matrix inverse", 0);
        check(equal(SceneMath::Matrix::perspective(sample["fov"].toDouble(), 16.0 / 9, 5, 300).json(),
                    sample["projection"]),
              "projection", 0);
        check(equal(SceneMath::Matrix::camera(vector(sample["cameraPosition"]), vector(sample["target"]))
                        .inverse()
                        .json(),
                    sample["view"]),
              "view", 0);
    }
    SceneMotion::ArchiveDrag drag;
    const auto position = [](SceneMotion::DragPosition value) {
        return QJsonObject{{"lane", value.lane}, {"row", value.row}};
    };
    for (const auto &entry : document["drag"].toArray()) {
        const auto sample = entry.toObject();
        const auto time = sample["time"].toDouble();
        if (sample["method"] == "start") {
            const auto projection = sample["projection"].toObject();
            const auto lane = projection["lane"].toObject();
            const auto row = projection["row"].toObject();
            drag.start(
                sample["x"].toDouble(), sample["y"].toDouble(),
                {{lane["x"].toDouble(), lane["y"].toDouble()}, {row["x"].toDouble(), row["y"].toDouble()}},
                time);
        } else {
            drag.move(sample["x"].toDouble(), sample["y"].toDouble(), time);
            check(drag.active == sample["active"].toBool() && drag.moved == sample["moved"].toBool() &&
                      equal(position(drag.value), sample["value"]) &&
                      equal(position(drag.releaseVelocity(time, false)), sample["velocity"]),
                  "drag", time);
        }
    }
    SceneMotion::ArchivePlaneMomentum momentum({-2.5, 12.7}, {7, -2});
    for (const auto &entry : document["momentum"].toArray()) {
        const auto sample = entry.toObject();
        momentum.step(1.0 / 60);
        QString phase = "snapping";
        if (momentum.phase() == SceneMotion::ArchiveMomentum::Phase::Coasting) {
            phase = "coasting";
        } else if (momentum.phase() == SceneMotion::ArchiveMomentum::Phase::Idle) {
            phase = "idle";
        }
        check(equal(position(momentum.value()), sample["value"]) &&
                  equal(position(momentum.velocity()), sample["velocity"]) &&
                  phase == sample["phase"].toString(),
              "momentum", 0);
    }
    qInfo() << "Native boot, decryption, field, spring, theme, matrices, drag and momentum:"
            << (ok ? "passed" : "FAILED");
    return ok;
}

#ifdef RHINE_SCENE_MOTION_TEST_MAIN
int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    return runSceneMotionChecks(application.arguments().value(1)) ? 0 : 1;
}
#endif
