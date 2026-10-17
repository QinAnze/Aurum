#include "AurumWordCloud.h"
#include <cmath>
#include <QJsonObject>

namespace aurum {

constexpr int kRiseMs = 850;
constexpr int kFallMs = 1150;
constexpr double kPadding = 6;

/* 固定浅色调（白 + 浅粉/蓝/绿/黄/紫），对应 Flutter _kCloudPastels。
   封面色提取未接入时先用这套，保证词云浅而鲜艳、杜绝灰字。 */
static const QColor kPastels[] = {
    QColor(255, 255, 255), QColor(255, 238, 246), QColor(238, 244, 255),
    QColor(240, 255, 240), QColor(255, 247, 230), QColor(243, 232, 255),
};
static constexpr int kPastelCount = sizeof(kPastels) / sizeof(kPastels[0]);

WordCloud::WordCloud() {
    m_clock.start();
    m_rng.seed(0xC0FFEE);
}

void WordCloud::reset() {
    m_placed.clear();
    m_chars.clear();
    m_line = -1;
    m_revealed = 0;
    m_spawnTimes.clear();
    m_words.clear();
}

void WordCloud::dropAll() {
    const double now = m_nowMs;
    for (auto &wd : m_words) {
        if (wd.phase == "fall") {
            continue;
        }
        if (wd.phase == "rise") {
            const double p = std::min(1.0, (now - wd.t0) / kRiseMs);
            // 当前高度无缝衔接（上升中的词按当前 p 反算）
            wd.fallFrom = wd.y + (wd.startY - wd.y) * std::pow(1 - p, 2);
        } else {
            wd.fallFrom = wd.y;
        }
        wd.phase = "fall";
        wd.t0 = now + m_rng() % 120; // 错落坠落，不整齐划一
    }
}

void WordCloud::tick(double tMs, const QJsonArray &lines, double width, double height, double /*climax*/,
                     bool /*oc*/, const QRectF *coverRect) {
    m_nowMs = m_clock.elapsed();
    if (lines.isEmpty()) {
        if (m_line != -1) {
            dropAll();
        }
        return;
    }
    int idx = -1;
    for (int i = 0; i < lines.size(); ++i) {
        const double startMs = lines.at(i).toObject()["startMs"].toDouble();
        if (startMs <= tMs) {
            idx = i;
        } else {
            break;
        }
    }
    if (idx < 0) {
        if (m_line != -1) {
            dropAll();
        }
        return;
    }
    if (idx != m_line) {
        m_line = idx;
        m_revealed = 0;
        m_placed.clear();
        // 预分词：连续拉丁字母/数字成词，其余（含中文、标点）逐字，作为词云最小单元
        const QString text = lines.at(idx).toObject()["text"].toString();
        m_chars.clear();
        QString buf;
        const auto flush = [&] {
            if (!buf.isEmpty()) {
                m_chars.append(buf);
                buf.clear();
            }
        };
        for (const QChar c : text) {
            if (c.isSpace()) {
                flush();
            } else if (c.isLetterOrNumber() && c.unicode() < 0x2E80) {
                // 0x2E80 以上视为 CJK / 全角符号，逐字处理
                buf.append(c);
            } else {
                flush();
                m_chars.append(QString(c));
            }
        }
        flush();
        const double t0 = lines.at(idx).toObject()["startMs"].toDouble();
        const double t1 = idx + 1 < lines.size()
                              ? lines.at(idx + 1).toObject()["startMs"].toDouble()
                              : t0 + 4000;
        const double gap = t1 - t0;
        const double span = gap > 9000 ? 4000 : gap * 0.72; // 间隔 >9s 强制 4s 内显示完
        // 按字符均匀分配出场时刻（近似原版按音节占比）
        m_spawnTimes.clear();
        for (int k = 0; k < m_chars.size(); ++k) {
            const double at = (double(k) + 0.5) / std::max(1, (int)m_chars.size()) * span;
            m_spawnTimes.append(t0 + at);
        }
        dropAll();
    }
    if (!m_chars.isEmpty() && !m_spawnTimes.isEmpty()) {
        const double now = m_nowMs;
        int k = 0;
        while (m_revealed < m_chars.size() && tMs >= m_spawnTimes.at(m_revealed)) {
            spawn(m_chars.at(m_revealed), now + k * 90, m_revealed, m_chars.size(), width, height, 0, false,
                  kPastels, kPastelCount, coverRect);
            ++m_revealed;
            ++k;
        }
    }
}

QSizeF WordCloud::measureWord(const QString &word, bool vertical, double size) const {
    if (!m_measure) {
        const double w = vertical ? size : size * word.size();
        return {w + kPadding * 2, (vertical ? word.size() * (size + 2) : size) + kPadding * 2};
    }
    if (vertical) {
        return {size + kPadding * 2, word.size() * (size + 2) + kPadding * 2};
    }
    const double w = m_measure(word, size);
    return {w + kPadding * 2, size + kPadding * 2};
}

void WordCloud::spawn(const QString &word, double t0, int idx, int total, double w, double h,
                     double /*climax*/, bool /*oc*/, const QColor *colors, int colorCount,
                     const QRectF *coverRect) {
    if (w <= 0 || h <= 0 || word.trimmed().isEmpty()) {
        return;
    }
    const bool vertical = m_rng() % 100 < 35;
    double size = 15 + (double(m_rng()) / 0xffffffff) * std::min(w, h) * 0.12;
    size = std::max(12.0, std::min(size, std::min(w, h) * 0.2));
    const bool isLast = total > 0 && idx >= total - 2; // 句末最后两个词：放大
    if (isLast) {
        size = std::min(w, h) * (0.18 + (double(m_rng()) / 0xffffffff) * 0.12);
        double fit = size;
        for (int s = 0; s < 60; ++s) {
            const auto m = measureWord(word, vertical, fit);
            if (m.width() < w && m.height() < h) {
                break;
            }
            fit *= 0.92;
            if (fit < 12) {
                fit = 12;
                break;
            }
        }
        size = fit;
    }

    // 封面圆（HUD 舞台坐标 == 词云画布坐标）：落在圆内的词会被封面挡住 → 禁区
    bool haveCover = false;
    double coverCx = 0, coverCy = 0, coverR = 0;
    if (coverRect && coverRect->width() > 1) {
        haveCover = true;
        coverCx = coverRect->left() + coverRect->width() / 2;
        coverCy = coverRect->top() + coverRect->height() / 2;
        coverR = coverRect->width() / 2 + 14; // 圆本身 + 边距（避开紧贴的频谱环）
    }
    // 词框是否避开封面圆（最近点距离判定）
    const auto coverFree = [&](double x, double y, const QSizeF &m) {
        if (!haveCover) {
            return true;
        }
        const double nx = std::max(x, std::min(coverCx, x + m.width()));
        const double ny = std::max(y, std::min(coverCy, y + m.height()));
        const double dx = coverCx - nx, dy = coverCy - ny;
        return dx * dx + dy * dy >= coverR * coverR;
    };
    // 画布内随机落点
    const auto randomSpot = [&](const QSizeF &m, double &x, double &y) {
        x = std::max(kPadding, std::min(kPadding + (double(m_rng()) / 0xffffffff) * (w - m.width() - 2 * kPadding),
                                        w - m.width() - kPadding));
        y = std::max(kPadding, std::min(kPadding + (double(m_rng()) / 0xffffffff) * (h - m.height() - 2 * kPadding),
                                        h - m.height() - kPadding));
        return x >= 0 && y >= 0;
    };
    const auto commit = [&](double x, double y, const QSizeF &m) {
        m_placed.append({x, y, m.width(), m.height()});
        const QColor col = colors ? colors[m_rng() % colorCount] : QColor(255, 255, 255);
        m_words.append(Word{word, x, y, size, vertical, col, "rise", t0,
                            h + 20 + (double(m_rng()) / 0xffffffff) * 60,
                            4200 + (double(m_rng()) / 0xffffffff) * 3800, 0});
    };

    // 主路径：同时避开已落位的词与封面圆
    for (int attempt = 0; attempt < 200; ++attempt) {
        const auto m = measureWord(word, vertical, size);
        if (m.width() >= w || m.height() >= h) {
            return;
        }
        double x = 0, y = 0;
        if (!randomSpot(m, x, y)) {
            continue;
        }
        bool hit = false;
        for (const auto &r : m_placed) {
            if (x < r.x + r.w && x + m.width() > r.x && y < r.y + r.h && y + m.height() > r.y) {
                hit = true;
                break;
            }
        }
        if (hit || !coverFree(x, y, m)) {
            continue;
        }
        commit(x, y, m);
        return;
    }
    // 兜底：句末最后两词务必显示——忽略碰撞强制落位，但仍避开封面圆
    if (isLast) {
        const auto m = measureWord(word, vertical, size);
        if (m.width() < w && m.height() < h) {
            for (int a = 0; a < 60; ++a) {
                double x = 0, y = 0;
                if (!randomSpot(m, x, y)) {
                    continue;
                }
                if (!coverFree(x, y, m)) {
                    continue;
                }
                commit(x, y, m);
                return;
            }
        }
    }
}

bool WordCloud::advance() {
    m_nowMs = m_clock.elapsed();
    const double now = m_nowMs;
    for (int i = m_words.size() - 1; i >= 0; --i) {
        auto &wd = m_words[i];
        if (wd.phase == "rise") {
            if ((now - wd.t0) / kRiseMs >= 1) {
                wd.phase = "hold";
                wd.t0 = now;
            }
        } else if (wd.phase == "hold") {
            if (now - wd.t0 > wd.holdMs) {
                wd.phase = "fall";
                wd.t0 = now;
                wd.fallFrom = wd.y;
            }
        } else {
            if ((now - wd.t0) / kFallMs >= 1) {
                m_words.removeAt(i);
            }
        }
    }
    return !m_words.isEmpty();
}

void WordCloud::draw(HudOp op, double width, double height, double climax, bool oc) const {
    const double now = m_clock.elapsed();
    const double h = height;
    for (const auto &wd : m_words) {
        double y;
        double alpha = 1;
        if (wd.phase == "rise") {
            const double p = (now - wd.t0) / kRiseMs;
            if (p < 0) {
                continue; // 排队等待入场
            }
            if (p >= 1) {
                y = wd.y;
            } else {
                y = wd.y + (wd.startY - wd.y) * std::pow(1 - p, 2); // 重力减速上升
                alpha = std::min(1.0, p * 2.2);
            }
        } else if (wd.phase == "hold") {
            y = wd.y;
        } else {
            const double p = (now - wd.t0) / kFallMs;
            if (p < 0) {
                y = wd.fallFrom;
            } else if (p >= 1) {
                continue;
            } else {
                y = wd.fallFrom + std::pow(p, 2) * (h + 40 - wd.fallFrom); // 自由落体
                alpha = 1 - std::pow(p, 2.2);
            }
        }
        const double a = std::min(1.0, std::max(0.0, alpha * 0.92));
        const QJsonArray color{QColor::fromRgb(wd.color.rgb()).redF(),
                               QColor::fromRgb(wd.color.rgb()).greenF(),
                               QColor::fromRgb(wd.color.rgb()).blueF(), a};
        if (wd.vertical) {
            for (int ci = 0; ci < wd.text.size(); ++ci) {
                op(QJsonArray{"text", QString(wd.text.at(ci)), wd.x + kPadding,
                              y + kPadding + ci * (wd.size + 2), wd.size, "bold", 0, color});
            }
        } else {
            op(QJsonArray{"text", wd.text, wd.x + kPadding, y + kPadding, wd.size, "bold", 0, color});
        }
        Q_UNUSED(oc);
        Q_UNUSED(climax);
    }
}

} // namespace aurum
