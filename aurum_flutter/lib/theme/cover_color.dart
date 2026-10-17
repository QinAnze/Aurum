/// Aurum · 封面取色（对应原版 extractColors）
///
/// 24×24 缩略采样 → 三元组：
///  - c1：有效亮度区间像素的均值色（主题主色）
///  - c2：饱和度×亮度评分最高的单像素（高饱和点缀色）
///  - palette：5 位/通道量化桶里像素最多的前 5 色（词云配色）
///
/// 放在中立层，在线音源（网络封面）与本地音源（内嵌封面）共用同一套数学，
/// 避免两边取色口径不一致导致主题跳变。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;
import 'dart:ui' as ui;

class _Bucket {
  int n = 0, r = 0, g = 0, b = 0;
}

/// 24×24 RGBA 缩略图 → (c1, c2, palette)。
///
/// 纯函数便于单测；全部像素过暗/过亮时返回 null（保留默认配色，
/// 与原版 try/catch 后不写回 state 的行为一致）。
(Color, Color, List<Color>)? quantizeCoverColors(ByteData data) {
  int r1 = 0, g1 = 0, b1 = 0, n1 = 0;
  double best = -1;
  int r2 = 0, g2 = 0, b2 = 0;
  final buckets = <int, _Bucket>{};
  for (int i = 0; i < data.lengthInBytes; i += 4) {
    final r = data.getUint8(i), g = data.getUint8(i + 1), b = data.getUint8(i + 2);
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final sat = mx - mn;
    final lum = (r + g + b) / 3;
    if (lum > 26 && lum < 235) {
      r1 += r;
      g1 += g;
      b1 += b;
      n1++;
    }
    final score = sat * 1.6 + (120 - (lum - 120).abs());
    if (score > best && sat > 24) {
      best = score;
      r2 = r;
      g2 = g;
      b2 = b;
    }
    if (lum > 30 && lum < 240) {
      final key = ((r >> 5) << 10) | ((g >> 5) << 5) | (b >> 5);
      final bk = buckets.putIfAbsent(key, _Bucket.new);
      bk.n++;
      bk.r += r;
      bk.g += g;
      bk.b += b;
    }
  }
  if (n1 == 0) return null;

  final c1r = (r1 / n1).round(), c1g = (g1 / n1).round(), c1b = (b1 / n1).round();
  final c1 = Color.fromARGB(255, c1r, c1g, c1b);
  final c2 = best > -1
      ? Color.fromARGB(255, r2, g2, b2)
      : Color.fromARGB(
          255,
          (255 - c1r * 0.5).round(),
          (255 - c1g * 0.5).round(),
          (255 - c1b * 0.5).round());

  final top = buckets.values.toList()..sort((a, b) => b.n.compareTo(a.n));
  final palette = top
      .take(5)
      .map((q) => Color.fromARGB(
          255, (q.r / q.n).round(), (q.g / q.n).round(), (q.b / q.n).round()))
      .toList(growable: false);
  return (c1, c2, palette);
}

/// 任意图片字节（JPEG / PNG / WebP…）→ (c1, c2, palette)。
/// 解码失败返回 null，由调用方保留默认配色。
Future<(Color, Color, List<Color>)?> extractColorsFromBytes(
    Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 24,
      targetHeight: 24,
    );
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    frame.image.dispose();
    if (data == null) return null;
    return quantizeCoverColors(data);
  } catch (_) {
    return null;
  }
}
