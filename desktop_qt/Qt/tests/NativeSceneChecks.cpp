#include "NativeScene.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QThread>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
bool equal(const QJsonValue &left, const QJsonValue &right, double tolerance = 1e-7) {
    if (left.type() != right.type()) {
        return false;
    }
    if (left.isDouble()) {
        return std::abs(left.toDouble() - right.toDouble()) <= tolerance;
    }
    if (left.isArray()) {
        const auto a = left.toArray();
        const auto b = right.toArray();
        if (a.size() != b.size()) {
            return false;
        }
        for (int index = 0; index < a.size(); ++index) {
            if (!equal(a.at(index), b.at(index), tolerance)) {
                return false;
            }
        }
        return true;
    }
    if (left.isObject()) {
        const auto a = left.toObject();
        const auto b = right.toObject();
        if (a.keys() != b.keys()) {
            return false;
        }
        for (auto entry = a.begin(); entry != a.end(); ++entry) {
            if (!equal(entry.value(), b[entry.key()], tolerance)) {
                return false;
            }
        }
        return true;
    }
    return left == right;
}
QJsonArray numbers(const QByteArray &bytes) {
    QJsonArray values;
    for (int index = 0; index + 4 <= bytes.size(); index += 4) {
        float value;
        std::memcpy(&value, bytes.constData() + index, sizeof(value));
        values.append(value);
    }
    return values;
}
QJsonObject normalize(const QJsonObject &frame, const SceneDrawBuffers &buffers) {
    QJsonObject result;
    for (const auto &key : {"view", "projection", "aoProjection", "eye", "background", "fogColor", "fogNear",
                            "fogFar", "detail", "focus", "aperture", "selected", "mode"}) {
        result[key] = frame[key];
    }
    QJsonArray draws;
    for (const auto &value : frame["draws"].toArray()) {
        auto draw = value.toObject();
        const auto bytes = buffers.value(draw["id"].toInt());
        draw["matrices"] = numbers(bytes.matrices);
        draw["themes"] = numbers(bytes.themes);
        for (const auto &key : {"id", "matrixBuffer", "themeBuffer"}) {
            draw.remove(key);
        }
        draws.append(draw);
    }
    result["draws"] = draws;
    return result;
}
void write(QString path, QJsonObject value) {
    QFile file(path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(value).toJson());
    }
}
}

/** 对照同一选择时间序列的相机、材质和原生矩阵；不把离线数据对照当作硬件帧率。 */
bool runNativeSceneChecks(const QString &root, const QString &fixturePath) {
    QFile fixture(fixturePath);
    if (!fixture.open(QIODevice::ReadOnly)) {
        return false;
    }
    QHash<QString, QJsonObject> references;
    for (const auto &value : QJsonDocument::fromJson(qUncompress(fixture.readAll())).array()) {
        const auto entry = value.toObject();
        references.insert(entry["name"].toString(), entry);
    }
    NativeScene native(root);
    if (!native.ready()) {
        qCritical() << "Native scene initialization failed" << native.failure;
        return false;
    }
    native.review("archive");
    bool ok = true;
    const auto compare = [&](double time, const QString &name) {
        const auto actual = normalize(native.sample(time), native.drawBuffers);
        const auto expected = references.value(name)["frame"].toObject();
        bool same = true;
        for (auto entry = actual.begin(); entry != actual.end(); ++entry) {
            if (!equal(entry.value(), expected[entry.key()], entry.key() == "draws" ? 0.00001 : 0.00000001)) {
                qCritical().noquote() << "Native scene parity:" << name << time << entry.key();
                same = false;
            }
        }
        if (!same) {
            const auto folder = qEnvironmentVariable("RHINE_NATIVE_SCENE_DIFF");
            if (!folder.isEmpty()) {
                QDir().mkpath(folder);
                write(folder + "/" + name + "-actual.json", actual);
                write(folder + "/" + name + "-expected.json", expected);
            }
        }
        ok &= same;
        return same;
    };
    compare(2.101, "archive");
    native.setMode("detail");
    for (int index = 1; index <= 180; ++index) {
        const auto time = 2.101 + index / 60.0;
        native.sample(time);
    }
    compare(5.102, "detail");
    if (ok) {
        native.setMode("archive");
        for (int index = 1; index <= 240; ++index) {
            const auto time = 5.102 + index / 60.0;
            if (index == 24 || index == 26 || index == 28) {
                native.navigate("row", 1);
            }
            if (index == 80) {
                native.navigate("lane", 1);
            }
            if (index == 100) {
                native.navigate("row", -8);
            }
            if (index == 120 || index == 144) {
                native.theme(index == 120);
            }
            native.sample(time);
            if (index % 12 == 0 && !compare(time + 0.0001, "rapid-" + QString::number(index))) {
                break;
            }
        }
    }
    if (ok) {
        native.review("boot");
        native.setMode("boot");
        for (const double shot :
             {0.0, 4.2, 9.0, 14.8, 18.0, 21.9, 22.1, 23.0, 24.6, 25.5, 26.7, 28.0, 29.6, 32.2, 34.0}) {
            native.freeze(shot);
            if (!compare(10 + shot, "boot-" + QString::number(shot))) {
                break;
            }
        }
        native.freeze(std::nullopt);
    }
    if (ok) {
        native.review("detail");
        native.sample(50);
        native.openViewer();
        for (int index = 1; index <= 40; ++index) {
            QCoreApplication::processEvents();
            native.sample(50 + index / 60.0);
        }
        compare(51, "viewer");
        native.viewerAction("explode");
        for (int index = 1; index <= 100; ++index) {
            native.sample(51 + index / 60.0);
        }
        compare(53, "viewer-exploded");
        native.pointer("pointerdown", 500, 400);
        native.pointer("pointermove", 550, 420);
        native.pointer("pointerup", 550, 420);
        for (int index = 1; index <= 60; ++index) {
            native.sample(53 + index / 60.0);
        }
        compare(54.001, "viewer-orbit");
        native.viewerKey("ArrowLeft");
        native.viewerKey("+");
        for (int index = 1; index <= 60; ++index) {
            native.sample(54.001 + index / 60.0);
        }
        compare(55.002, "viewer-pan-zoom");
        native.viewerAction("frosted");
        native.viewerAction("reset");
        for (int index = 1; index <= 60; ++index) {
            native.sample(55.002 + index / 60.0);
        }
        compare(56.003, "viewer-reset");
    }
    qInfo() << "Native scene camera, materials and frame buffers:" << (ok ? "passed" : "FAILED");
    return ok;
}

#ifdef RHINE_SCENE_REGRESSION_TEST_MAIN
int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    return runNativeSceneChecks(application.arguments().value(1), application.arguments().value(2)) ? 0 : 1;
}
#endif
