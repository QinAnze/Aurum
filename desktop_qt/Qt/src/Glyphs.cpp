#include "Glyphs.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRadialGradient>
#include <QRegularExpression>
#include <cmath>
static QJsonObject load(const QString &name) {
    QFile f(name);
    if (!f.open(QIODevice::ReadOnly)) {
        qFatal("Missing glyph resource: %s", qPrintable(name));
    }
    return QJsonDocument::fromJson(f.readAll()).object();
}
static QColor color(const QJsonValue &value) {
    const auto a = value.toArray();
    // 普通 RGBA 只有四项；色彩空间标记是可选的第五项，不能通过可写代理越界读取。
    const bool calibrated = a.size() > 4 && a.at(4).toString().startsWith("calibrated");
    auto channel = [&](int i) {
        double value = a.at(i).toDouble();
        // 原 calibrated 颜色使用 Gamma 1.8；显式转到 sRGB，避免平台默认色彩空间差异。
        if (calibrated) {
            auto linear = std::pow(value, 1.8);
            value = linear <= .0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1 / 2.4) - .055;
        }
        return value;
    };
    return QColor::fromRgbF(channel(0), channel(1), channel(2), a.size() > 3 ? a[3].toDouble() : 1);
}
Glyphs::Glyphs(const QString &root) {
    for (auto weight : {"light", "regular", "demibold", "bold"}) {
        fonts[weight] = QRawFont(root + "/RhineMiSans-" + weight + ".otf", 1000, QFont::PreferNoHinting);
    }
    fonts["symbols"] = QRawFont(root + "/NotoSansSymbols2-Regular.ttf", 1000, QFont::PreferNoHinting);
    const auto data = load(root + "/misans-glyphs.json");
    for (auto font = data.begin(); font != data.end(); ++font) {
        auto entries = font.value().toObject()["glyphs"].toObject();
        for (auto it = entries.begin(); it != entries.end(); ++it) {
            auto o = it.value().toObject();
            glyphs[font.key() + ":" + it.key()] = {o["advance"].toDouble(), path(o["path"].toString())};
        }
    }
    const auto art = load(root + "/boot-lettering-art.json");
    for (auto it = art.begin(); it != art.end(); ++it) {
        for (auto letter : it.value().toObject()["letters"].toArray()) {
            auto o = letter.toObject();
            lettering[it.key()].append({o["width"].toDouble(), path(o["path"].toString())});
        }
    }
}
QPainterPath Glyphs::path(const QString &svg) {
    QMutexLocker lock(&mutex);
    if (paths.contains(svg)) {
        return *paths.object(svg);
    }
    static const QRegularExpression re(
        "[a-zA-Z]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?");
    QStringList tokens;
    auto matches = re.globalMatch(svg);
    while (matches.hasNext()) {
        tokens << matches.next().captured();
    }
    QPainterPath path;
    path.setFillRule(Qt::WindingFill);
    int i = 0;
    QChar command = 'M';
    QPointF point{}, start{};
    auto number = [&]() { return i < tokens.size() ? tokens[i++].toDouble() : 0.; };
    while (i < tokens.size()) {
        if (tokens[i][0].isLetter()) {
            command = tokens[i++][0];
            if (command.toUpper() == 'Z') {
                path.closeSubpath();
                point = start;
                continue;
            }
        }
        const bool relative = command.isLower();
        const auto origin = relative ? point : QPointF{};
        auto pair = [&]() {
            double x = number() + origin.x();
            double y = number() + origin.y();
            return QPointF(x, y);
        };
        switch (command.toUpper().unicode()) {
        case 'M':
            point = pair();
            path.moveTo(point);
            start = point;
            command = relative ? 'l' : 'L';
            break;
        case 'L':
            point = pair();
            path.lineTo(point);
            break;
        case 'H':
            point.setX(number() + (relative ? point.x() : 0));
            path.lineTo(point);
            break;
        case 'V':
            point.setY(number() + (relative ? point.y() : 0));
            path.lineTo(point);
            break;
        case 'C': {
            auto a = pair();
            auto b = pair();
            auto p = pair();
            path.cubicTo(a, b, p);
            point = p;
            break;
        }
        case 'Q': {
            auto a = pair();
            auto p = pair();
            path.quadTo(a, p);
            point = p;
            break;
        }
        default:
            i = tokens.size();
            break;
        }
    }
    paths.insert(svg, new QPainterPath(path));
    return path;
}
Glyphs::Glyph Glyphs::glyph(QString ch, QString weight) {
    QMutexLocker lock(&mutex);
    const auto key = weight + ":" + ch;
    if (glyphs.contains(key)) {
        return glyphs[key];
    }
    auto font = fonts.value(weight, fonts["regular"]);
    auto ids = font.glyphIndexesForString(ch);
    if (ids.isEmpty() || !ids.first()) {
        font = fonts["symbols"];
        ids = font.glyphIndexesForString(ch);
    }
    if (ids.isEmpty() || !ids.first()) {
        return {};
    }
    auto advances = font.advancesForGlyphIndexes(ids);
    // Qt 字形坐标朝下；资源轮廓保持原始字体朝上的坐标。
    auto outline = QTransform::fromScale(1, -1).map(font.pathForGlyph(ids.first()));
    return glyphs[key] = {advances.first().x() / 1000, outline};
}
double Glyphs::width(QString text, double size, QString weight, double tracking) {
    QMutexLocker lock(&mutex);
    const auto key = QString::fromUtf8(
        QJsonDocument(QJsonArray{text, size, weight, tracking}).toJson(QJsonDocument::Compact));
    if (const auto cached = widths.object(key)) {
        return *cached;
    }
    double result = 0;
    for (auto ch : text) {
        auto g = glyph(QString(ch), weight);
        result += g.advance * size + tracking;
    }
    result = qMax(0., result - tracking);
    if (text.size() <= 4096) {
        widths.insert(key, new double(result));
    }
    return result;
}
QVariantMap Glyphs::bounds(QString value, double size, QString weight) {
    QMutexLocker lock(&mutex);
    QRectF bounds;
    bool visible = false;
    double x = 0;
    // 使用和实际绘制完全相同的轮廓变换，避免中英文字体基线造成视觉错位。
    for (auto ch : value) {
        const auto g = glyph(QString(ch), weight);
        if (!g.path.isEmpty()) {
            QTransform transform;
            transform.translate(x, size * 1.044);
            transform.scale(size / 1000, -size / 1000);
            const auto rect = transform.map(g.path).boundingRect();
            bounds = visible ? bounds.united(rect) : rect;
            visible = true;
        }
        x += g.advance * size;
    }
    return {{"x", bounds.x()}, {"y", bounds.y()}, {"width", bounds.width()}, {"height", bounds.height()}};
}
double Glyphs::inset(QString text, double size, QString weight) {
    QMutexLocker lock(&mutex);
    if (text.isEmpty()) {
        return 0;
    }
    auto g = glyph(text.first(1), weight);
    return !g.path.isEmpty() ? g.path.boundingRect().x() * size / 1000 : 0;
}
QStringList Glyphs::wrap(QString value, double limit, double size, QString weight) {
    QMutexLocker lock(&mutex);
    const auto key = QString::fromUtf8(
        QJsonDocument(QJsonArray{value, limit, size, weight}).toJson(QJsonDocument::Compact));
    if (const auto cached = wrapped.object(key)) {
        return *cached;
    }
    QStringList lines;
    QString line;
    double length = 0;
    for (auto ch : value) {
        if (ch == '\n') {
            lines << line;
            line.clear();
            length = 0;
            continue;
        }
        double advance = width(QString(ch), size, weight);
        if (!line.isEmpty() && length + advance > limit) {
            lines << line;
            line.clear();
            length = 0;
        }
        line += ch;
        length += advance;
    }
    lines << line;
    // 有界缓存包含完整布局参数；窗口缩放和内容变化使用不同 key。
    wrapped.insert(key, new QStringList(lines), qMax(1, value.size()));
    return lines;
}
double Glyphs::artWidth(QString key, double size, double tracking, int count) {
    QMutexLocker lock(&mutex);
    double result = 0;
    const auto letters = lettering.value(key);
    const auto visible = letters.mid(0, count < 0 ? letters.size() : count);
    for (auto g : visible) {
        result += g.advance * size + tracking;
    }
    return visible.isEmpty() ? 0 : result - tracking;
}
void Glyphs::text(QPainter &c, QString value, double x, double y, double size, QString weight,
                  double tracking, QColor ink) {
    QMutexLocker lock(&mutex);
    for (auto ch : value) {
        auto g = glyph(QString(ch), weight);
        c.save();
        c.translate(x, y + size * 1.044);
        c.scale(size / 1000, -size / 1000);
        c.fillPath(g.path, ink);
        c.restore();
        x += g.advance * size + tracking;
    }
}
void Glyphs::art(QPainter &c, QString key, double x, double y, double size, int count, double tracking) {
    QMutexLocker lock(&mutex);
    for (auto g : lettering[key].mid(0, count < 0 ? lettering[key].size() : count)) {
        c.save();
        c.translate(x, y);
        c.scale(size / 1000, size / 1000);
        c.fillPath(g.path, c.brush());
        c.restore();
        x += g.advance * size + tracking;
    }
}
void Glyphs::commands(QPainter &c, const QJsonArray &commands, std::function<QImage(QString)> image) {
    QMutexLocker lock(&mutex);
    c.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform);
    for (auto v : commands) {
        const auto a = v.toArray();
        auto op = a[0].toString();
        auto n = [&](int i) { return a[i].toDouble(); };
        if (op == "save") {
            c.save();
        } else if (op == "restore") {
            c.restore();
        } else if (op == "alpha") {
            c.setOpacity(c.opacity() * n(1));
        } else if (op == "translate") {
            c.translate(n(1), n(2));
        } else if (op == "scale") {
            c.scale(n(1), n(2));
        } else if (op == "rotate") {
            c.rotate(n(1) * 180 / 3.14159265358979323846);
        } else if (op == "clip") {
            c.setClipRect(QRectF(n(1), n(2), n(3), n(4)), Qt::IntersectClip);
        } else if (op == "fill") {
            c.fillRect(QRectF(n(2), n(3), n(4), n(5)), color(a[1]));
        } else if (op == "ellipse") {
            c.setPen(Qt::NoPen);
            c.setBrush(color(a[1]));
            c.drawEllipse(QRectF(n(2), n(3), n(4), n(5)));
        } else if (op == "text") {
            text(c, a[1].toString(), n(2), n(3), n(4), a[5].toString(), n(6), color(a[7]));
        } else if (op == "art") {
            c.setBrush(color(a[7]));
            art(c, a[1].toString(), n(2), n(3), n(4), a[5].toInt(-1), n(6));
        } else if (op == "fill-path") {
            // 实心几何图标不受字体字形边距影响。
            c.fillPath(path(a[1].toString()), color(a[2]));
        } else if (op == "path") {
            QPen pen(color(a[3]), n(2), Qt::SolidLine, Qt::FlatCap, Qt::MiterJoin);
            auto dash = a[4].toArray();
            QList<qreal> d;
            for (auto x : dash) {
                d << x.toDouble() / qMax(n(2), .0001);
            }
            if (!d.isEmpty()) {
                pen.setDashPattern(d);
                pen.setDashOffset(n(5) / qMax(n(2), .0001));
            }
            c.setPen(pen);
            c.setBrush(Qt::NoBrush);
            c.drawPath(path(a[1].toString()));
        } else if (op == "arc") {
            QPainterPath p;
            QRectF r(n(1) - n(3), n(2) - n(3), n(3) * 2, n(3) * 2);
            p.arcMoveTo(r, -n(4) * 180 / 3.14159265358979323846);
            p.arcTo(r, -n(4) * 180 / 3.14159265358979323846, -n(5) * 180 / 3.14159265358979323846);
            c.setPen(QPen(color(a[7]), n(6), Qt::SolidLine, Qt::RoundCap));
            c.setBrush(Qt::NoBrush);
            c.drawPath(p);
        } else if (op == "gradient") {
            QRadialGradient gradient(QPointF(979.2, 518.4), 1100);
            gradient.setColorAt(0, QColor(231, 231, 225));
            gradient.setColorAt(.76, QColor(227, 225, 220));
            gradient.setColorAt(1, QColor(228, 223, 219));
            c.fillRect(QRectF(-4096, -4096, 8192, 8192), gradient);
        } else if (op == "image") {
            auto img = image(a[1].toString());
            if (!img.isNull()) {
                c.drawImage(QRectF(n(2), n(3), n(4), n(5)), img);
            }
        }
    }
}
QImage Glyphs::label(const QJsonObject &value) {
    QMutexLocker lock(&mutex);
    QImage img(1024, 440, QImage::Format_RGBA8888_Premultiplied);
    img.fill(QColor::fromRgbF(.902, .886, .851));
    QPainter c(&img);
    c.setRenderHint(QPainter::Antialiasing);
    QColor ink = QColor::fromRgbF(.09, .09, .075);
    c.fillRect(QRectF(12, 12, 1000, 6), ink);
    auto fit = [&](QString s, double y, double maximum, QString weight) {
        double size = maximum;
        while (width(s, size, weight) > 954 && size > 34) {
            size -= 2;
        }
        QString shown = s;
        while (width(shown, size, weight) > 954 && shown.size() > 1) {
            shown.chop(1);
        }
        if (shown != s) {
            shown.chop(1);
            shown += "…";
        }
        text(c, shown, 30, y, size, weight, 0, ink);
    };
    fit(value["title"].toString("音乐资料库"), 40, 125, "bold");
    auto artist = value["artist"].toString();
    fit(artist.isEmpty() ? "暂无歌手" : artist, 210, 78, "demibold");
    fit(value["kind"].toString("MUSIC").toUpper() + " ID " + value["id"].toString("—"), 340, 40, "regular");
    return img;
}
void saveImageNative(const QImage &image, const QString &path) {
    image.save(path);
}
