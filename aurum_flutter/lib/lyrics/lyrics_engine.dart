/// Aurum · 歌词解析与中文分词引擎（移植自原版 index.html 的 setLyrics / tokenizeWords 体系）
/// 契约层：api / effects 只经本文件做歌词相关计算。
library;

import 'dart:math' as math;

import '../models.dart';

/* ---------------- LRC 解析 ---------------- */
/// [mm:ss.xx] 时间标签（一行可有多个）
final RegExp _lrcTagRe = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');

/// 解析 LRC → 按时间排序的歌词行（一行多标签会展开为多行，与原版一致）
List<LyricLine> parseLRC(String lrc) {
  final out = <LyricLine>[];
  for (final line in lrc.split('\n')) {
    final text = line.replaceAll(_lrcTagRe, '').trim();
    if (text.isEmpty) continue;
    for (final m in _lrcTagRe.allMatches(line)) {
      final t = int.parse(m.group(1)!) * 60 + double.parse(m.group(2)!);
      out.add(LyricLine(t: t, text: text));
    }
  }
  out.sort((a, b) => a.t.compareTo(b.t));
  return out;
}

/* ---------------- 分词 ----------------
   原版 Web 走 Intl.Segmenter（浏览器内置中文分词），桌面端无此 API，
   这里直接落地其回退方案：拉丁按空白切；CJK 连续段切 2~3 字小块。
   预编译正则，避免逐次构造（对应原版 RE_SEP / RE_CJK_SPLIT / RE_CJK_ANY）。 */

/// 纯分隔符（整词都是标点/空白则丢弃）。
/// 字符类同时含半角与全角引号，用 \u 转义避开 Dart 字符串引号冲突（原样传给正则引擎解释）。
final RegExp _reSep = RegExp(
    r'^[\s,，。！？、；：\u0022\u0027（）()\[\]【】…—\-·.]+$');

/// CJK 连续段（中日韩统一表意 + 扩展A + 兼容 + 假名 + 谚文），用 \u 转义保证源码纯 ASCII
final RegExp _reCjkSplit =
    RegExp(r'([\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]+)');
final RegExp _reCjkChar =
    RegExp(r'[\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]');
final RegExp _reWhitespace = RegExp(r'\s+');

final math.Random _chunkRng = math.Random();

/// 把一句歌词切成词（词云消费）。
/// 注意：JS 的 String.split(带捕获组正则) 会把捕获段插回结果，
/// Dart 的 split 会丢弃捕获段——这里手动遍历匹配来复刻原版行为。
List<String> tokenizeWords(String text) {
  if (text.isEmpty) return const [];
  final result = <String>[];
  void addLatin(String part) {
    for (final t in part.split(_reWhitespace)) {
      if (t.trim().isNotEmpty && !_reSep.hasMatch(t)) result.add(t);
    }
  }

  void addCjk(String run) {
    var pos = 0;
    while (pos < run.length) {
      final remain = run.length - pos;
      // remain>=3 时随机取 2~3 字；不足 3 字则全取
      final len = remain >= 3 ? 2 + _chunkRng.nextInt(2) : remain;
      final chunk = run.substring(pos, pos + len);
      if (!_reSep.hasMatch(chunk)) result.add(chunk);
      pos += len;
    }
  }

  var last = 0;
  for (final m in _reCjkSplit.allMatches(text)) {
    addLatin(text.substring(last, m.start));
    addCjk(m.group(1)!);
    last = m.end;
  }
  addLatin(text.substring(last));
  return result;
}

/* ---------------- 歌词行清洗 / 判定 ---------------- */

/// 归一化：去标点/空格/符号、转小写，仅留字母数字与 CJK（供「是否等于歌名/作者」比较）
String normText(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// 制作信息行前缀（作词/作曲/编曲…），命中后整行替换为歌名
final RegExp _reMeta = RegExp(
    r'^(?:作词|作曲|编曲|混音|母带|制作人|制作|和声|录音|监制|吉他|贝斯|键盘|鼓|弦乐|词|曲|编|混|录|和声编写|配唱|出品|发行|厂牌|艺人|专辑)');

/// 「纯音乐，请欣赏」类提示行
final RegExp _rePureMusic = RegExp(r'纯音乐|请欣赏');

/// 翻译 / 括号注记清理；制作信息行替换为歌名（对应原版 cleanLyricLine）
String cleanLyricLine(String raw, String title) {
  var txt = raw.trim();
  if (txt.isEmpty) return '';
  // 去「/ 译文」形式的翻译行尾
  txt = txt.replaceAll(RegExp(r'\s*/\s*.+$'), '');
  // 去带标注的括号（中译/英文/feat/remix…）
  txt = txt.replaceAll(
      RegExp(
          r'[（(]\s*(?:中?译|翻译|英文?|日文?|韩文?|中文?|原曲|原词|cover|ver|feat|prod|remix)\s*[：:]\s*[^)）]*[)）]',
          caseSensitive: false),
      '');
  // 去其余圆括号 / 方括号注记
  txt = txt.replaceAll(RegExp(r'[（(][^)）]*[)）]'), '');
  txt = txt.replaceAll(RegExp(r'[【[][^\]】]*[\]】]'), '').trim();
  if (txt.isEmpty) return '';
  if (_reMeta.hasMatch(txt)) return title.isNotEmpty ? title : txt;
  return txt;
}

/// 估算一个词的音节数：CJK 每字 1 音节；拉丁词按元音组估算（词云按音节节奏出场）
int countSyllables(String word) {
  if (word.isEmpty) return 1;
  final cjk = _reCjkChar.allMatches(word).length;
  final latin = word.replaceAll(_reCjkChar, ' ').trim().toLowerCase();
  var lat = 0;
  if (latin.isNotEmpty) {
    final groups = RegExp(r'[aeiouy]+').allMatches(latin).length;
    lat = groups > 0 ? groups : latin.split(_reWhitespace).where((s) => s.isNotEmpty).length;
  }
  return math.max(1, cjk + lat);
}

/* ---------------- 预分词装载（对应原版 setLyrics） ---------------- */

/// 解析 LRC 并一次性预分词 + 打 skip 标记（歌名行 / 作者行 / 纯音乐提示不进词云）
List<LyricLine> prepareLyricLines(String? lrc, Track? track) {
  final lines = lrc == null ? const <LyricLine>[] : parseLRC(lrc);
  final titleN = normText(track?.name ?? '');
  final artistParts = (track?.artist ?? '')
      .split(RegExp(r'\s*[/／、]\s*'))
      .map(normText)
      .where((s) => s.isNotEmpty)
      .toList();
  for (final ln in lines) {
    final clean = cleanLyricLine(ln.text, track?.name ?? '');
    final n = normText(clean);
    ln.skip = n.isNotEmpty &&
        (n == titleN || artistParts.contains(n) || _rePureMusic.hasMatch(n));
    ln.tokens = ln.skip ? const <String>[] : tokenizeWords(clean);
  }
  return lines;
}
