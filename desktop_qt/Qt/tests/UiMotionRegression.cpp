#include "UiMotion.h"
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <algorithm>
#include <cmath>

namespace {
/** 重放同一组界面动作，对照冻结采样中的原生曲线和字轮实现。 */
QJsonObject replay(const QJsonObject &input) {
    const auto kind = input["kind"].toString();
    const auto initial = input["initial"].toArray();
    UiMotion::ReelCurve reel(initial.at(0).toDouble(), initial.at(1).toDouble(), initial.at(2).toDouble(),
                             initial.at(3).toDouble(), initial.size() > 4 ? initial.at(4).toDouble() : 0.46);
    UiMotion::SurfaceMotion surface;
    UiMotion::RollingLabel label;
    QJsonArray results;
    for (const auto &value : input["calls"].toArray()) {
        const auto call = value.toObject();
        const auto method = call["method"].toString();
        const auto args = call["args"].toArray();
        if (kind == "reel" && method == "sample") {
            const auto sample = reel.sample(args.at(0).toDouble());
            results.append(QJsonArray{sample[0], sample[1]});
        } else if (kind == "surface") {
            if (method == "set") {
                surface.set(args.at(0).toBool(), args.at(1).toDouble(), args.at(2).toBool());
            } else if (method == "sample") {
                surface.sample(args.at(0).toDouble());
            } else if (method == "opacity") {
                surface.opacity = args.at(0).toDouble();
            } else if (method == "offset") {
                surface.offset = args.at(0).toDouble();
            }
            results.append(QJsonObject{{"opacity", surface.opacity},
                                       {"offset", surface.offset},
                                       {"duration", surface.duration},
                                       {"finished", surface.finished()}});
        } else if (kind == "rolling" && method == "active") {
            results.append(label.active(args.at(0).toDouble()));
        } else if (kind == "rolling" && method == "render") {
            const auto widths = call["widths"].toObject();
            results.append(label.render(args.at(0).toString(), args.at(1).toDouble(), args.at(2).toDouble(),
                                        args.at(3).toDouble(), args.at(4).toString(), args.at(5).toDouble(),
                                        args.at(6).toDouble(), args.at(7).toBool(), args.at(8).toBool(),
                                        args.at(9).toArray(),
                                        [widths](const QString &text, double, const QString &, double) {
                                            return widths[text].toDouble();
                                        }));
        } else {
            return {{"error", "Unknown motion regression operation"}};
        }
    }
    return {{"results", results}};
}

bool equal(const QJsonValue &actual, const QJsonValue &expected) {
    if (actual.type() != expected.type()) {
        return false;
    }
    if (actual.isDouble()) {
        const auto scale = std::max({1., std::abs(actual.toDouble()), std::abs(expected.toDouble())});
        return std::abs(actual.toDouble() - expected.toDouble()) <= scale * 1e-11;
    }
    if (actual.isArray()) {
        const auto values = actual.toArray();
        const auto reference = expected.toArray();
        if (values.size() != reference.size()) {
            return false;
        }
        for (qsizetype i = 0; i < values.size(); ++i) {
            if (!equal(values.at(i), reference.at(i))) {
                return false;
            }
        }
        return true;
    }
    if (actual.isObject()) {
        const auto values = actual.toObject();
        const auto reference = expected.toObject();
        if (values.keys() != reference.keys()) {
            return false;
        }
        for (auto it = values.begin(); it != values.end(); ++it) {
            if (!equal(it.value(), reference[it.key()])) {
                return false;
            }
        }
        return true;
    }
    return actual == expected;
}
}

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    const auto arguments = application.arguments();
    QFile fixture(arguments.value(1));
    if (!fixture.open(QIODevice::ReadOnly)) {
        qCritical("Missing UI motion reference fixture");
        return 1;
    }
    const auto cases = QJsonDocument::fromJson(qUncompress(fixture.readAll())).array();
    if (cases.isEmpty()) {
        qCritical("UI motion reference fixture has no scenarios");
        return 1;
    }
    int samples = 0;
    for (qsizetype i = 0; i < cases.size(); ++i) {
        const auto entry = cases.at(i).toObject();
        const auto actual = replay(entry["input"].toObject());
        if (!equal(actual, entry["expected"])) {
            qCritical() << "Native UI motion differs from retained reference sample" << i;
            return 1;
        }
        samples += actual["results"].toArray().size();
    }
    qInfo() << "Native UI curves, interrupted surfaces and rolling commands match" << samples
            << "reference samples across" << cases.size() << "scenarios";
    return 0;
}
