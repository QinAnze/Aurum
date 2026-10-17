#include "NativeHud.h"
#include <QRegularExpression>
#include <algorithm>
#include <cmath>
#include <numbers>

namespace {
const QString contour =
    "M295 73C295 41 273 15 240 15C221 15 207 23 192 38C186 43 181 47 176 52C127 96 103 128 70 128C38 128 15 "
    "101 15 70C15 39 37 15 70 15C103 15 127 48 156 75C182 99 208 128 240 128C273 128 295 105 295 73Z";

// 保持逐曲线 512 次采样，避免绘图库长度近似改变描边时序。
double contourLength() {
    QVector<double> values;
    auto matches = QRegularExpression("[-+]?[0-9]*\\.?[0-9]+").globalMatch(contour);
    while (matches.hasNext()) {
        values.append(matches.next().captured().toDouble());
    }
    QPointF point(values.at(0), values.at(1));
    const auto first = point;
    double length = 0;
    for (int index = 2; index < values.size(); index += 6) {
        const auto start = point;
        const QPointF a(values.at(index), values.at(index + 1));
        const QPointF b(values.at(index + 2), values.at(index + 3));
        const QPointF end(values.at(index + 4), values.at(index + 5));
        for (int sample = 1; sample <= 512; ++sample) {
            const auto time = sample / 512.0;
            const auto inverse = 1 - time;
            const auto next = start * (inverse * inverse * inverse) + a * (3 * inverse * inverse * time) +
                              b * (3 * inverse * time * time) + end * (time * time * time);
            length += std::hypot(next.x() - point.x(), next.y() - point.y());
            point = next;
        }
    }
    return length + std::hypot(point.x() - first.x(), point.y() - first.y());
}
const double contourSize = contourLength();
}

void NativeHud::logo(double x, double y, double width) {
    save();
    translate(x, y);
    scale(width / 310, width / 310);
    op({"path",
        "M156 75C127 48 103 15 70 15C37 15 15 39 15 70C15 101 38 128 70 128C103 128 127 96 176 52M155 75C182 "
        "99 208 128 240 128C273 128 295 105 295 73C295 41 273 15 240 15C221 15 207 23 192 38",
        26, ink(), QJsonArray{}, 0});
    op({"path", "M44 70H94M69 45V95M219 70H263", 15, ink(), QJsonArray{}, 0});
    restore();
}

void NativeHud::boot(double width) {
    const auto boot = frame["boot"].toObject();
    if (boot.isEmpty()) {
        return;
    }
    const auto number = [&boot](const char *name) { return boot[name].toDouble(); };
    const auto offset = (width - 1920) / 2;
    save();
    translate(offset, 0);
    if (number("backgroundOpacity") > 0) {
        save();
        alpha(number("backgroundOpacity"));
        op({"gradient"});
        restore();
        fill(-offset, 0, width, 1080, {1, 1, 1, number("white")});
    }
    if (number("accessOpacity") > 0) {
        save();
        alpha(number("accessOpacity"));
        art("access", 800, 532, 18, boot["access"].toString().size());
        restore();
    }
    const auto logo = boot["logo"].toObject();
    if (number("logoOpacity") > 0 && !logo.isEmpty()) {
        save();
        alpha(number("logoOpacity"));
        translate(518 + logo["offsetX"].toDouble(), 463);
        scale(296.0 / 310, 296.0 / 310);
        const auto fraction = std::clamp(logo["length"].toDouble(), 0.000001, 1.0);
        op({"path", contour, logo["strokeWidth"], ink(),
            QJsonArray{fraction * contourSize, (1 - fraction) * contourSize},
            -logo["start"].toDouble() * contourSize});
        const auto symbolScale = logo["symbolScale"].toDouble();
        if (symbolScale > 0) {
            save();
            translate(logo["plusX"].toDouble(), 70);
            op({"rotate", logo["plusAngle"].toDouble() * std::numbers::pi / 180});
            scale(symbolScale, symbolScale);
            translate(-69, -70);
            op({"path", "M44 70H94M69 45V95", 15, ink(), QJsonArray{}, 0});
            restore();
            save();
            translate(logo["minusX"].toDouble(), 70);
            scale(symbolScale, symbolScale);
            const auto half = logo["minusWidth"].toDouble() / 2;
            op({"path", "M" + QString::number(-half, 'g', 16) + " 0H" + QString::number(half, 'g', 16), 15,
                ink(), QJsonArray{}, 0});
            restore();
        }
        text(boot["logoLetters"].toString(), 20, 174 - 16 * 1.044, 16, "bold", 22);
        restore();
    }
    if (number("authOpacity") > 0) {
        save();
        alpha(number("authOpacity"));
        text("▪", 907, 528, 14);
        const auto auth = boot["auth"].toString();
        QString key = "processing";
        if (auth.startsWith("ID")) {
            key = "identity";
        } else if (auth.startsWith("REQUEST")) {
            key = "request";
        } else if (auth.startsWith(' ')) {
            key = "processingGlitch";
        }
        constexpr double size = 21.35;
        constexpr double tracking = -0.00909 * size;
        const QString prefix = "ID CONFIRMED : ";
        const auto count = key == "identity" ? std::min(auth.size(), prefix.size()) : auth.size();
        art(key, 931, 527, size, count, tracking);
        if (key == "identity" && auth.size() >= prefix.size()) {
            const auto nickname = m_music->identityName();
            const auto characters = nickname.toUcs4();
            const auto length = characters.isEmpty() ? 5 : characters.size();
            const auto frame = number("f");
            const auto visible =
                frame < 321 ? 0
                            : std::min(int(length), 1 + int(std::floor((frame - 321) * (length - 1) / 18)));
            const auto x = 931 + m_glyphs->artWidth("identity", size, tracking, prefix.size()) + tracking;
            if (!nickname.isEmpty()) {
                const auto bounds = m_glyphs->bounds(nickname, size, "regular");
                const auto scale = std::min(
                    {1.0, 650 / m_glyphs->width(nickname, size), size * 0.7 / bounds["height"].toDouble()});
                const auto y =
                    527 + size * 0.45 - (bounds["y"].toDouble() + bounds["height"].toDouble() / 2) * scale;
                text(QString::fromUcs4(reinterpret_cast<const char32_t *>(characters.constData()), visible),
                     x, y, size * scale);
            } else {
                for (int index = 0; index < visible; ++index) {
                    fill(x + index * 18, 530, 14, 14);
                }
            }
        }
        restore();
    }
    if (boot["scanVisible"].toBool()) {
        scan(boot);
    }
    if (boot["welcomeVisible"].toBool()) {
        save();
        alpha(number("welcomeOpacity"));
        translate(960, 552.6);
        scale(number("welcomeScale"), number("welcomeScale"));
        translate(-960, -552.6);
        auto panel = ink();
        panel[3] = number("welcomePanel");
        fill(725, 344, 470, 392, panel);
        const auto white = 1 - number("welcomeInk");
        art("welcome", 960 - m_glyphs->artWidth("welcome", 55) / 2, 403, 55, -1, 0,
            {white, white, white, 1, "calibratedWhite"});
        if (boot["companyVisible"].toBool()) {
            const bool mask = boot["companyMask"].toBool();
            save();
            alpha(mask ? 0.65 : 1);
            const auto companyWidth = m_glyphs->artWidth("company", 48, -0.5);
            art("company", 960 - companyWidth / 2, 475, 48, -1, -0.5);
            save();
            clip(755, 470, 410 * number("highlight"), 60);
            fill(755, 470, 410, 60);
            art("company", 960 - companyWidth / 2, 475, 48, -1, -0.5,
                {238.0 / 255, 237.0 / 255, 232.0 / 255, mask ? 0.06 : 1});
            restore();
            restore();
        }
        save();
        alpha(number("databaseOpacity"));
        art("database", 960 - m_glyphs->artWidth("database", 36) / 2, 537, 36);
        restore();
        if (boot["welcomeLogo"].toBool()) {
            this->logo(858.5, 590, 203);
        }
        restore();
    }
    restore();
    const auto brand = boot["brand"].toArray();
    for (int index = 0; index < brand.size(); ++index) {
        const auto line = brand.at(index).toObject();
        save();
        alpha(line["opacity"].toDouble());
        translate(line["x"].toDouble(), 0);
        brandLine(index);
        restore();
    }
    if (number("poweredLetters") > 0) {
        save();
        clip(width - 354, 945, 295 * number("poweredLetters") / 19, 35);
        text("POWERED BY", width - 354, 947, 19);
        text("RHINE LAB", width - 218, 947, 19, "bold");
        fill(width - 84, 955, 25, 6);
        restore();
    }
    button("ENTER SYSTEM ↗", width - 261, 994, 202, 40, "skip", 14);
}

void NativeHud::scan(const QJsonObject &boot) {
    const auto music = boot["scan"].toObject();
    const auto orbit = boot["scanOrbit"].toObject();
    if (music.isEmpty() || orbit.isEmpty()) {
        return;
    }
    const auto arc = [this](double radius, double start, double sweep, double x = 960, double y = 540,
                            double width = 2, QJsonArray color = {}) {
        if (radius > 0 && sweep > 0) {
            op({"arc", x, y, radius, start, sweep, width, color.isEmpty() ? ink() : color});
        }
    };
    const auto dot = [this](double x, double y, double radius, QJsonArray color = {}) {
        if (radius > 0) {
            op({"ellipse", color.isEmpty() ? ink() : color, x - radius, y - radius, radius * 2, radius * 2});
        }
    };
    save();
    translate(960, 540);
    const auto ringScale = boot["ringScale"].toDouble();
    scale(ringScale, ringScale);
    translate(-960, -540);
    alpha(boot["ringOpacity"].toDouble());
    arc(music["radius"].toDouble(), music["outerStart"].toDouble(), music["outerSweep"].toDouble(), 960, 540,
        2.4);
    arc(music["whiteRadius"].toDouble(), music["whiteStart"].toDouble(), music["whiteSweep"].toDouble(), 960,
        540, 4, {1, 1, 1, 1});
    arc(music["innerRadius"].toDouble(), music["innerStart"].toDouble(), music["innerSweep"].toDouble());
    arc(music["innerRadius"].toDouble(), music["innerStart"].toDouble() + std::numbers::pi,
        music["innerSweep"].toDouble());
    if (orbit["sideVisible"].toBool()) {
        for (const auto &value : orbit["sides"].toArray()) {
            const auto side = value.toObject();
            arc(side["radius"].toDouble(), side["start"].toDouble(), side["sweep"].toDouble(),
                side["x"].toDouble(), side["y"].toDouble());
        }
    }
    for (const auto &value : orbit["satellites"].toArray()) {
        const auto point = value.toObject();
        dot(point["x"].toDouble(), point["y"].toDouble(), point["radius"].toDouble());
    }
    if (boot["ornament"].toBool()) {
        dot(959.5, 539.5, boot["coreRadius"].toDouble());
    }
    for (int index = 0; index < 2; ++index) {
        const auto angle = music["orbit"].toDouble() + index * std::numbers::pi;
        dot(960 + std::cos(angle) * music["orbitRadius"].toDouble(),
            540 + std::sin(angle) * music["orbitRadius"].toDouble(), music["dotRadius"].toDouble(),
            {237.0 / 255, 130.0 / 255, 27.0 / 255, 1});
    }
    const auto black = music["outerStart"].toDouble() + music["outerSweep"].toDouble();
    const auto white = music["whiteStart"].toDouble();
    dot(960 + std::cos(black) * music["radius"].toDouble(),
        540 + std::sin(black) * music["radius"].toDouble(), music["blackCap"].toDouble());
    dot(960 + std::cos(white) * music["whiteRadius"].toDouble(),
        540 + std::sin(white) * music["whiteRadius"].toDouble(), music["whiteCap"].toDouble(), {1, 1, 1, 1});
    restore();
    save();
    alpha(boot["permissionOpacity"].toDouble());
    const auto font = boot["scanFont"].toDouble();
    const auto tracking = boot["scanTracking"].toDouble();
    art("permission", 960 - m_glyphs->artWidth("permission", font, tracking) / 2, 540 - font / 2, font, -1,
        tracking);
    restore();
}
