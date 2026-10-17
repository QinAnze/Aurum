#include "NativeHud.h"
#include "MusicData.h"
#include <QJsonDocument>
#include <algorithm>
#include <cmath>

QJsonArray NativeHud::ink() const {
    if (dark) {
        return {0.92, 0.92, 0.92, 1, "calibratedWhite"};
    }
    return {0.08, 0.085, 0.075, 1, "calibratedRGB"};
}
void NativeHud::op(QJsonArray command) {
    commands.append(command);
}
void NativeHud::save() {
    op({"save"});
}
void NativeHud::restore() {
    op({"restore"});
}
void NativeHud::alpha(double value) {
    op({"alpha", value});
}
void NativeHud::translate(double x, double y) {
    op({"translate", x, y});
}
void NativeHud::scale(double x, double y) {
    op({"scale", x, y});
}
void NativeHud::clip(double x, double y, double width, double height) {
    op({"clip", x, y, width, height});
}
void NativeHud::fill(double x, double y, double width, double height, QJsonArray color) {
    op({"fill", color.isEmpty() ? ink() : color, x, y, width, height});
}
void NativeHud::text(QString value, double x, double y, double size, QString weight, double tracking,
                     QJsonArray color) {
    op({"text", value, x, y, size, weight, tracking, color.isEmpty() ? ink() : color});
}
void NativeHud::aligned(QString value, double x, double y, double size, QString weight, double tracking) {
    text(value, x - m_glyphs->inset(value, size, weight), y, size, weight, tracking);
}

QString NativeHud::fit(QString value, double size, double width, QString weight) {
    const auto key = QString::fromUtf8(
        QJsonDocument(QJsonArray{value, size, width, weight}).toJson(QJsonDocument::Compact));
    if (const auto cached = m_fitCache.object(key)) {
        return *cached;
    }
    auto length = value.size();
    if (m_glyphs->width(value, size, weight) > width) {
        qsizetype low = 1;
        auto high = length;
        while (low < high) {
            const auto middle = (low + high + 1) / 2;
            if (m_glyphs->width(value.left(middle), size, weight) <= width) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        length = low;
    }
    auto result = value;
    if (length != value.size()) {
        result = value.left(std::max(qsizetype(0), length - 1)) + "…";
    }
    m_fitCache.insert(key, new QString(result));
    return result;
}
void NativeHud::limited(QString value, double x, double y, double size, double width, QString weight) {
    text(fit(value, size, width, weight), x, y, size, weight);
}
void NativeHud::centeredText(QString value, double x, double cy, double size, QString weight,
                             bool horizontal) {
    const auto bounds = m_glyphs->bounds(value, size, weight);
    text(value, x - bounds["x"].toDouble() - (horizontal ? bounds["width"].toDouble() / 2 : 0),
         cy - bounds["y"].toDouble() - bounds["height"].toDouble() / 2, size, weight);
}
void NativeHud::rollingText(QString key, QString value, double x, double y, double size, QString weight,
                            double tracking, bool numeric) {
    const auto result = m_rolling[key].render(
        value, x, y, size, weight, tracking, lastTime, !reduced && frame["mode"] == "archive", numeric, ink(),
        [this](const QString &text, double size, const QString &weight, double tracking) {
            return m_glyphs->width(text, size, weight, tracking);
        });
    for (const auto &command : result) {
        commands.append(command);
    }
}
void NativeHud::roll(QString key, QString value, double x, double y, double size, double width,
                     QString weight, bool numeric) {
    const auto shown = fit(value, size, width, weight);
    rollingText(key, shown, x - m_glyphs->inset(shown, size, weight), y, size, weight, 0, numeric);
}
void NativeHud::hit(double x, double y, double width, double height, QString action, QString label) {
    hits.append(QJsonObject{{"x", x},
                            {"y", y},
                            {"width", width},
                            {"height", height},
                            {"action", action},
                            {"label", label.isNull() ? action : label}});
}
void NativeHud::button(QString label, double x, double y, double width, double height, QString action,
                       double size, QString weight) {
    hit(x, y, width, height, action, label);
    const auto inset = m_modalControls ? std::min(10.0, width / 8) : 0;
    if (m_modalControls) {
        fill(x, y, width, height,
             dark ? QJsonArray{0.55, 0.59, 0.46, 0.13} : QJsonArray{0.44, 0.49, 0.36, 0.1});
    }
    text(m_modalControls ? fit(label, size, width - inset * 2) : label, x + inset,
         y + (height - size) / 2 - 4, size, weight);
}
void NativeHud::control(QString label, double x, double y, double width, QString action) {
    hit(x - 10, y, width + 20, 54, action, label);
    aligned(label, x, y + 14, 20, "demibold");
}
void NativeHud::rule(double x, double y, double width, double opacity) {
    auto color = ink();
    color[3] = opacity;
    fill(x, y, width, 1, color);
}
void NativeHud::image(QString key, double x, double y, double width, double height) {
    if (!key.isEmpty()) {
        op({"image", key, x, y, width, height});
    }
}
void NativeHud::art(QString key, double x, double y, double size, int count, double tracking,
                    QJsonArray color) {
    op({"art", key, x, y, size, count, tracking, color.isEmpty() ? ink() : color});
}

QRectF NativeHud::modalBounds(double width) const {
    double modalWidth = std::min(1260.0, width - 100);
    if (modal == "search") {
        modalWidth = std::min(width - 100, std::max(760.0, std::min(1000.0, width * 0.5 - 59)));
    }
    const auto left = modal == "search" ? width - modalWidth - 59 : (width - modalWidth) / 2;
    return {left, 122, modalWidth, 836};
}
NativeHud::Layout NativeHud::containerLayout(double width) const {
    Layout layout;
    layout.sidebar = std::clamp(width * 0.23 - 40, 250.0, 340.0);
    layout.x = layout.left + layout.sidebar + 36;
    layout.width = width - layout.x - 40;
    return layout;
}
QJsonObject NativeHud::state() const {
    const auto bounds = modalBounds(width);
    const auto rect = [](const std::optional<QRectF> &value) -> QJsonValue {
        if (!value) {
            return QJsonValue::Null;
        }
        return QJsonObject{
            {"x", value->x()}, {"y", value->y()}, {"width", value->width()}, {"height", value->height()}};
    };
    return {{"inputX", bounds.x() + 53},
            {"inputY", bounds.y() + 180},
            {"inputWidth", bounds.width() - 106},
            {"seek", rect(playerSeekRect)},
            {"volume", rect(playerVolumeRect)},
            {"loginMethod", m_music->loginMethod},
            {"formKind", formKind},
            {"formPID", formPID},
            {"modal", modal},
            {"query", query},
            {"closing", closing},
            {"modalOpacity", motion.opacity},
            {"modalOffset", motion.offset},
            {"dark", dark},
            {"reduced", reduced},
            {"mode", frame["mode"]},
            {"viewer", frame["viewer"]},
            {"status", m_music->status}};
}

/** 每帧清空绘制与命中数组，再按原顺序生成；文字动画由原生曲线维护。 */
void NativeHud::draw(QJsonObject next, double stageWidth, double time) {
    if (themeMode == "system" && dark != m_host->systemDark()) {
        dark = m_host->systemDark();
        m_scene.theme(dark);
    }
    frame = next;
    width = stageWidth;
    lastTime = time;
    commands = {};
    hits = {};
    playerSeekRect.reset();
    playerVolumeRect.reset();
    motion.sample(time);
    if (closing && motion.finished()) {
        modal.clear();
        closing = false;
    }
    if (frame["viewer"].toBool()) {
        viewer(width);
    } else if (frame["mode"] == "boot") {
        boot(width);
    } else {
        brand();
        navigation(width);
        footer(width);
        if (modal != "search") {
            if (frame["mode"] == "detail" || (lyricsMode && !m_music->player.current.isEmpty())) {
                detail(width, lyricsMode ? 1 : frame["detail"].toDouble());
            } else {
                archive(width);
            }
        }
    }
    if (!modal.isEmpty()) {
        modalDraw(width);
    }
    if (frame["mode"] != "boot") {
        playerBar(0, 984, width);
    }
}
void NativeHud::brand() {
    roll("music-brand", m_music->libraryName(), 59, 115.425, 44, std::min(720.0, width * 0.45), "bold");
    aligned("RHINE LAB / MUSIC DATABASE", 59, 173, 14, "demibold", 1);
}
void NativeHud::brandLine(int index) {
    if (index == 0) {
        text("RHINE LAB", 59, 115.425, 50.75, "bold", 1);
    } else if (index == 1) {
        text("MUSIC DATABASE", 59, 169, 22, "demibold", 1.7);
    } else {
        rule(59, 212, 300, 0.65);
        text("INDEX / COLLECTION / TRACK", 59, 228, 11, "regular", 1.2);
    }
}
void NativeHud::navigation(double width) {
    const auto x = width - 579;
    control("发现音乐 ↗", x - 210, 118, 184, "discover");
    control("音乐检索  /", x, 118, 184, "search");
    control("＋ 我的音乐", x + 200, 118, 184, "saved");
    control("设置", x + 400, 118, 120, "settings");
}
void NativeHud::footer(double width) {
    fill(59, 971, 5, 5, {119.0 / 255, 123.0 / 255, 96.0 / 255, 1});
    QString session = "GUEST SESSION";
    if (!m_music->uid.isEmpty()) {
        session = "NETEASE SESSION";
        if (m_music->provider == "qq") {
            session = "QQ SESSION";
        } else if (m_music->provider == "kugou") {
            session = "KUGOU SESSION";
        }
    }
    text(session, 75, 967, 10, "regular", 0.9);
    limited(m_music->status, width - 361.203, 967, 10, 195);
    button("REINITIALIZE ↗", width - 145.57, 965, 86.57, 20, "replay", 10);
    text("POWERED BY RHINE LAB", width / 2 - 85, 967, 10, "demibold");
}
void NativeHud::empty(double width) {
    const auto x = width * 0.50520833;
    auto &music = *m_music;
    if (music.directory) {
        control("← 返回上一级", 59, 211, 280, "music:parent");
    }
    text("MUSIC DATABASE / " + music.libraryName(), x, 471, 12);
    QString title = "音乐资料库";
    QString label = "检索音乐 →";
    QString action = "search";
    if (music.directory) {
        title = music.libraryName();
        label = "查看音乐详情 →";
        action = "music:directory-info";
    } else if (music.selectedLane > 0) {
        if (music.uid.isEmpty()) {
            title = "登录后查看";
        }
        label = "登录" + music.providerName() + " →";
        action = "music:login";
    }
    limited(title, x, 509, 28, width - x - 59, "bold");
    rule(x, 601, width - x - 59);
    limited(music.status, x, 624, 16, width - x - 117);
    button(label, x, 703, 300, 32, action, 14);
}
void NativeHud::archive(double width) {
    auto &music = *m_music;
    const auto item = music.current;
    if (!item.isEmpty()) {
        const auto x = width * 0.50520833;
        if (music.directory) {
            control("← 返回上一级", 59, 211, 280, "music:parent");
            control("查看音乐详情 ↗", 59, 347, 310, "music:directory-info");
        }
        roll("music-source", "MUSIC DATABASE / " + music.libraryName(), x, 471, 12, width - x - 59);
        roll("music-title", item["title"].toString(), x, 509, 28, width - x - 59, "bold");
        hit(x, 509, 414, 37, "open", item["title"].toString());
        rule(x, 601, width - x - 59);
        fill(x - 12, 598, 6, 6);
        const auto kind = item["kind"].toString();
        roll("music-id", kind.toUpper() + " ID: " + item["id"].toString() + " / " + item["artist"].toString(),
             x, 624, 16, width - x - 210);
        text(kind.toUpper(), width - 170, 627, 11);
        QString label = "打开歌单资料库 →";
        if (kind == "song") {
            label = "查看歌曲详情 →";
        } else if (kind == "album") {
            label = "打开专辑资料库 →";
        } else if (kind == "artist") {
            label = "浏览歌手作品 →";
        }
        control(label, x, 703, 300, "open");
        aligned("点击打开 · ENTER 键也可打开", x, 771, 14);
        text("TRACK / SELECT", 60, 865, 11);
        rollingText("music-number", MusicData::pad(music.libraryIndex() + 1), 60, 901.2, 58, "regular", 0,
                    true);
        text("/", 141, 925, 32, "light");
        text(QString::number(music.libraryTotal()), 172, 932, 22);
    } else {
        empty(width);
    }
    const auto nav = width * 0.2625;
    button("↑", nav, 903, 46, 46, "prev", 28);
    for (int index = 0; index < 8; ++index) {
        const auto x = nav + 85 + index * 26;
        const auto row =
            std::max(0, int(music.physicalSlots[music.selectedLane].indexOf(frame["selected"].toInt())));
        auto color = ink();
        color[3] = index == row ? 1 : 0.45;
        fill(x, index == row ? 909 : 920, 2, index == row ? 33 : 12, color);
        if (!music.libraryItems().isEmpty()) {
            hit(x - 6, 900, 26, 50, "music:slot:" + QString::number(index),
                "选曲 " + QString::number(index + 1));
        }
    }
    button("↓", nav + 320, 903, 46, 46, "next", 28);
    const auto col = width * 0.5234375;
    button("←", col, 903, 46, 46, "column-prev", 28);
    if (!music.directory) {
        text("COLLECTION " + MusicData::pad(music.selectedLane + 1) + " / " +
                 MusicData::pad(music.provider == "kugou" ? 4 : 5),
             col + 70, 904, 10);
        roll("music-column", music.libraryName(), col + 70, 925, 15, width - col - 360);
    } else {
        const auto label = "TRACK COLUMN " + MusicData::pad(music.selectedLane + 1) + " / 05";
        text(label, col + 62 + (171 - m_glyphs->width(label, 15)) / 2, 916, 15);
    }
    button("→", col + 233, 903, 46, 46, "column-next", 28);
    text(music.directory ? "← → 浏览曲目列 / ↑ ↓ 选曲 / ENTER 查看 / ESC 上一级"
                         : "← → 切换来源 / ↑ ↓ 选曲 / ENTER 查看 / 检索",
         nav, 850, 12);
}
void NativeHud::actionButton(QString label, double x, double y, double width, QString action, bool primary) {
    auto color = ink();
    if (primary) {
        color = {119.0 / 255, 123.0 / 255, 96.0 / 255, 1};
    } else {
        color[3] = 0.075;
    }
    fill(x, y, width, 44, color);
    hit(x, y, width, 44, action, label);
    text(label, x + 14, y + 12, 15, "demibold", 0, primary ? QJsonArray{0.96, 0.95, 0.91, 1} : ink());
}
std::array<double, 2> NativeHud::rowMotion(const QString &signature, int index) {
    if (signature != m_resultSignature) {
        m_resultSignature = signature;
        m_resultStart = lastTime;
    }
    const auto progress =
        reduced ? 1 : std::clamp((lastTime - m_resultStart - index * 0.025) / 0.24, 0.0, 1.0);
    const auto remainder = std::pow(1 - progress, 3);
    return {1 - remainder, 10 * remainder};
}
QString NativeHud::clock(double ms) {
    return MusicData::pad(int(std::floor(ms / 60000))) + ":" +
           MusicData::pad(int(std::floor(ms / 1000)) % 60);
}
