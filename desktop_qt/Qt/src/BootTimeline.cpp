#include "SceneMotion.h"
#include <QJsonArray>
#include <algorithm>
#include <cmath>
#include <numbers>

namespace SceneMotion {
namespace {
QString typed(const QString &text, int frame, int start, int end) {
    if (frame < start) {
        return {};
    }
    return text.left(std::min(
        int(text.size()), 1 + int(std::floor(double(frame - start) * (text.size() - 1) / (end - start)))));
}
double progress(double time, double start, double end) {
    return std::clamp((time - start) / (end - start), 0.0, 1.0);
}
bool at(int frame, std::initializer_list<int> values) {
    return std::find(values.begin(), values.end(), frame) != values.end();
}
constexpr double radians = std::numbers::pi / 180;
}

/** 把原测量关键帧一次装入连续原生曲线；运行时不载入或执行动画脚本。 */
BootTimeline::BootTimeline(const QJsonObject &tracks) {
    for (auto entry = tracks.begin(); entry != tracks.end(); ++entry) {
        if (entry.key() == "orbit.sides" || entry.key() == "logo.draw" || entry.key() == "orbit.orbit" ||
            entry.key() == "brandX") {
            continue;
        }
        Curve curve;
        for (const auto &value : entry.value().toArray()) {
            const auto pair = value.toArray();
            curve.append({pair.at(0).toDouble(), pair.at(1).toDouble()});
        }
        m_tracks.insert(entry.key(), curve);
    }
    const auto brand = tracks["brandX"].toArray();
    for (int index = 0; index < brand.size(); ++index) {
        m_tracks["brandX"].append({double(index), brand.at(index).toDouble()});
    }
    for (const auto &value : tracks["logo.draw"].toArray()) {
        const auto row = value.toArray();
        m_tracks["logo.drawStart"].append({row.at(0).toDouble(), row.at(1).toDouble()});
        m_tracks["logo.drawEnd"].append({row.at(0).toDouble(), row.at(2).toDouble()});
    }
    for (const auto &value : tracks["orbit.sides"].toArray()) {
        const auto row = value.toArray();
        for (int column = 0; column < 9; ++column) {
            m_tracks["orbit.column" + QString::number(column)].append(
                {row.at(0).toDouble(), row.at(column + 1).toDouble()});
        }
    }
    for (const auto &value : tracks["orbit.orbit"].toArray()) {
        const auto row = value.toArray();
        const auto x = row.at(1).toDouble() - 959.5;
        const auto y = row.at(2).toDouble() - 539.5;
        m_tracks["orbit.angle"].append({row.at(0).toDouble(), std::atan2(y, x)});
        m_tracks["orbit.radius"].append({row.at(0).toDouble(), std::hypot(x, y)});
    }
}

double BootTimeline::value(const QString &key, double frame) const {
    const auto found = m_tracks.constFind(key);
    return found == m_tracks.cend() ? 0 : track(*found, frame);
}
QJsonObject BootTimeline::logo(double frame) const {
    const auto cut = value("logo.movingCut", frame);
    const auto start = frame < 420 ? value("logo.drawStart", frame) : cut + 0.0275;
    const auto end = frame < 420 ? value("logo.drawEnd", frame) : cut + 1;
    QJsonObject result{{"offsetX", value("logo.leftEdge", frame) - 520},
                       {"start", start},
                       {"length", std::clamp(end - start, 0.0, 1.0)}};
    for (const auto &key : {"strokeWidth", "symbolScale", "plusX", "minusX", "minusWidth", "plusAngle"}) {
        result[key] = value("logo." + QString::fromUtf8(key), frame);
    }
    return result;
}
QJsonObject BootTimeline::scan(double frame) const {
    QJsonObject result;
    for (const auto &key :
         {"radius", "whiteRadius", "outerStart", "outerSweep", "whiteStart", "whiteSweep", "innerRadius",
          "innerStart", "innerSweep", "orbit", "orbitRadius", "dotRadius", "blackCap", "whiteCap"}) {
        double scale = 1;
        if (QStringList{"outerStart", "outerSweep", "whiteStart", "whiteSweep", "innerStart", "innerSweep",
                        "orbit"}
                .contains(key)) {
            scale = radians;
        }
        result[key] = value("scan." + QString::fromUtf8(key), frame) * scale;
    }
    return result;
}
QJsonObject BootTimeline::orbit(double frame) const {
    double columns[9];
    for (int index = 0; index < 9; ++index) {
        columns[index] = value("orbit.column" + QString::number(index), frame);
    }
    const auto angle = value("orbit.angle", frame);
    const auto radius = value("orbit.radius", frame);
    const auto sourceFrame = int(std::floor(frame + 0.00001));
    const bool flash = at(sourceFrame, {546, 547, 549, 550});
    const auto core = value(flash ? "orbit.coreFlash" : "orbit.core", frame);
    QJsonArray sides{QJsonObject{{"x", columns[0]},
                                 {"y", columns[1]},
                                 {"radius", columns[4]},
                                 {"start", columns[5] * radians},
                                 {"sweep", columns[7] * radians}},
                     QJsonObject{{"x", columns[2]},
                                 {"y", columns[3]},
                                 {"radius", columns[4]},
                                 {"start", columns[6] * radians},
                                 {"sweep", columns[8] * radians}}};
    QJsonArray satellites;
    for (int index = 0; index < 6; ++index) {
        const auto phase = angle + index * std::numbers::pi / 3;
        satellites.append(QJsonObject{{"x", 959.5 + std::cos(phase) * radius},
                                      {"y", 539.5 + std::sin(phase) * radius},
                                      {"radius", value("orbit.dotGrowth", frame - 548 - index * 3)}});
    }
    return {
        {"sides", sides}, {"sideVisible", frame >= 544}, {"coreRadius", core}, {"satellites", satellites}};
}

QJsonObject BootTimeline::sample(double appTime) const {
    const auto time = appTime + 5;
    const auto frame = int(std::floor(time * 25 + 0.00001));
    QString step = "welcome";
    if (time < 9.12) {
        step = "access";
    } else if (time < 11.12) {
        step = "logo";
    } else if (time < 19.48) {
        step = "auth";
    } else if (time < 22.76) {
        step = "scan";
    }
    QString auth;
    if (frame < 363) {
        auth = typed("ID CONFIRMED", frame, 282, 295);
        if (frame >= 320) {
            auth += " : ";
        }
    } else if (frame < 421) {
        auth = typed("REQUEST RECEIVED", frame, 367, 389);
    } else {
        auth = typed("START PROCESSING", frame, 423, 440);
        if (frame >= 449) {
            auth += QString(std::min(3, 1 + (frame - 449) / 4), '.');
        }
        if (at(frame, {479, 485, 486})) {
            auth = "              SING...";
        }
    }
    const auto measuredFrame = time * 25;
    const auto scanState = scan(measuredFrame);
    const auto orbitState = orbit(measuredFrame);
    const bool glitch = at(frame, {525, 526, 528, 529});
    const auto flashIndex = frame - 569;
    const auto exit = ease(progress(time, 26.56, 26.92));
    const int accessCounts[]{1, 1, 3, 4, 5, 6, 9, 11, 12, 14, 17, 18, 19, 20, 22, 23, 25, 26};
    const double welcomeIntro[]{1, 0, 0.28, 0, 1, 0, 0};
    const double welcomeInk[]{0, 0, 0.2, 1, 0, 0, 0.25};
    double accessOpacity = 0;
    if (frame >= 170 && frame < 227) {
        accessOpacity = frame == 226 ? 0.25 : 1;
    }
    QJsonArray brand;
    for (int line = 0; line < 3; ++line) {
        const auto local = measuredFrame - 278 - line * 2;
        brand.append(QJsonObject{{"x", value("brandX", local)}, {"opacity", value("brandOpacity", local)}});
    }
    const QString access = "ACCESS PERMISSION REQUIRED";
    return {{"t", time},
            {"f", frame},
            {"step", step},
            {"auth", auth},
            {"access", access.left(frame < 170 ? 0 : accessCounts[std::min(17, frame - 170)])},
            {"accessOpacity", accessOpacity},
            {"logoOpacity", time >= 9.16 && time < 19.48 ? 1 : 0},
            {"logo", logo(measuredFrame)},
            {"logoLetters", typed("RHINE·LAB", frame, 232, 255)},
            {"authOpacity", frame >= 281 && frame < 487 ? 1 : 0},
            {"brand", brand},
            {"poweredLetters", typed("POWERED BY RHINE LAB", frame, 279, 295).size()},
            {"scanVisible", time >= 19.48 && time < 22.76},
            {"scan", scanState},
            {"scanOrbit", orbitState},
            {"scanRadius", scanState["radius"]},
            {"ringScale", glitch ? 1.94 : 1},
            {"ringOpacity", glitch ? 0.32 : value("ringOpacity", measuredFrame)},
            {"ringBlur", glitch ? 2.2 : 0},
            {"scanTracking", value("scanTracking", measuredFrame)},
            {"scanFont", 26.5},
            {"permissionOpacity",
             time < 21.8 ? progress(time, 19.48, 19.88) : value("permissionOpacity", measuredFrame)},
            {"ornament", time >= 21.84},
            {"coreRadius", orbitState["coreRadius"]},
            {"welcomeVisible", time >= 22.76 && time < 26.92},
            {"welcomePanel", flashIndex >= 0 && flashIndex < 7 ? welcomeIntro[flashIndex] : 0},
            {"welcomeInk", flashIndex >= 0 && flashIndex < 7 ? welcomeInk[flashIndex] : 1},
            {"companyVisible", frame >= 588 && !at(frame, {590, 591})},
            {"companyMask", at(frame, {594, 595})},
            {"highlight", value("highlightKeys", measuredFrame) / 410},
            {"databaseOpacity", frame < 626 || at(frame, {628, 629, 631, 634}) ? 0 : 1},
            {"welcomeLogo", frame >= 588},
            {"welcomeScale", 1 - 0.46 * exit},
            {"welcomeOpacity", 1 - std::pow(exit, 3)},
            {"exitBlur", 8 * exit},
            {"exit", exit},
            {"backgroundOpacity", time < 26.92 ? 1 : 0},
            {"white", ease(progress(time, 26.16, 26.88))}};
}
}
