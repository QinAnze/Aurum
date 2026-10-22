/// Aurum · 数据模型与全局常量（对齐原版 index.html 中的 state / 常量结构）
/// 契约层：叶子模块统一 import 本文件，禁止修改。
library;

import 'package:flutter/foundation.dart';

/* ---------------- API 端点 ---------------- */
const String kApi = 'https://music-api.gdstudio.xyz/api.php';
const String kApi2 = 'https://api.injahow.cn/meting/'; // 备用播放地址解析（302 直链）
const String kLocalApi = 'http://127.0.0.1:4530'; // 本地 NCMApi sidecar

/// 网易云**直连**（音乐数据库那个项目走的就是这条路：不经第三方镜像，
/// 直接打 music.163.com 的站内 JSON 接口）。
///
/// 实测 2026-10-22：搜索 0.35s、详情 0.2s，比公共镜像稳；
/// 取流走 outer/url —— 免费曲目 302 到 CDN，付费曲目 302 到 /404，
/// 引擎拿到 HTML 会判为坏候选并自动跳下一个。
const String kNeteaseSearch = 'https://music.163.com/api/search/get/web';
const String kNeteaseDetail = 'https://music.163.com/api/song/detail';
const String kNeteaseOuterUrl = 'https://music.163.com/song/media/outer/url';

const List<String> kSources = ['netease', 'kuwo']; // 搜索双源：网易优先，酷我兜底
const List<int> kBitrates = [320, 192, 128]; // 码率回退链
const List<String> kLocalLevels = ['exhigh', 'standard', 'lossless']; // 本地音质回退链

/// 本地 NCMApi 探测结果（原版 localApiOn）
final ValueNotifier<bool> localApiOn = ValueNotifier<bool>(false);

/* ---------------- 音轨 ---------------- */
class Track {
  Track({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    this.picId = '',
    this.picUrl = '',
    required this.source,
  });

  /// 音源侧 id（网易/酷吾/本地均为字符串化数字）
  final String id;
  final String name;
  String artist;
  String album;
  String picId;
  String picUrl;

  /// 'netease' | 'kuwo' | 'local'
  String source;

  /// 跨源解析后允许替换 id/picId/picUrl/source（原版 kuwo → netease 改写并缓存）
  Track copyWith({
    String? id,
    String? picId,
    String? picUrl,
    String? source,
  }) {
    return Track(
      id: id ?? this.id,
      name: name,
      artist: artist,
      album: album,
      picId: picId ?? this.picId,
      picUrl: picUrl ?? this.picUrl,
      source: source ?? this.source,
    );
  }
}

/* ---------------- 歌词行（含词云预分词缓存） ---------------- */
class LyricLine {
  LyricLine({required this.t, required this.text});

  /// 出现时间（秒）
  final double t;
  final String text;

  /// 词云跳过：歌名行 / 作者行 / 纯音乐提示
  bool skip = false;

  /// 预分词缓存（原版 setLyrics 一次性分词，播放时按行取用）
  List<String> tokens = const [];
}

/* ---------------- 循环模式 ---------------- */
enum PlayMode {
  list('列表循环喵～'),
  one('单曲循环…就、就宠你这一次喵'),
  shuffle('随机播放，交给命运喵');

  const PlayMode(this.label);
  final String label;

  PlayMode get next => PlayMode.values[(index + 1) % PlayMode.values.length];
}

/* ---------------- 工具 ---------------- */
/// 秒 → "m:ss"（原版 fmt）
String fmtTime(double s) {
  if (!s.isFinite || s < 0) s = 0;
  final m = (s / 60).floor();
  final ss = (s % 60).floor();
  return '$m:${ss.toString().padLeft(2, '0')}';
}
