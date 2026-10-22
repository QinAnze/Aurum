/// Aurum · 音乐 API 数据层（GDStudio 公共 API + injahow 备用直链 + 本地 NCMApi sidecar）
/// 契约层：AppState / widgets 只经本文件访问网络。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:http/http.dart' as http;

import '../net_image.dart';

import '../models.dart';
import '../theme/cover_color.dart';

export '../lyrics/lyrics_engine.dart' show prepareLyricLines;
export '../theme/cover_color.dart' show quantizeCoverColors;

/* ---------------- 通用 ---------------------------- */

/// 浏览器 UA：GDStudio 网易搜索对非浏览器 UA 返空；netease CDN 对无 UA 请求返 403
const String _kUa = kBrowserUa;

final http.Client _client = http.Client();

const Duration _kTimeout = Duration(seconds: 12);

Future<dynamic> _getJson(Uri url, {Map<String, String>? headers}) async {
  final r = await _client
      .get(url, headers: {..._kHeaders, if (headers != null) ...headers})
      .timeout(_kTimeout);
  if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
  return jsonDecode(utf8.decode(r.bodyBytes));
}

final Map<String, String> _kHeaders = {'User-Agent': _kUa};

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}

/// GDStudio 公共 API（对应原版 api()）
Future<dynamic> api(Map<String, String> params, String source) {
  final uri = Uri.parse(kApi).replace(queryParameters: {
    ...params,
    'source': source,
  });
  return _getJson(uri);
}

/// 探测本地 NCMApi sidecar（exe 场景：随壳启动 127.0.0.1:4530）
Future<void> detectLocalApi() async {
  try {
    final d = await _getJson(
      Uri.parse('$kLocalApi/search?keywords=ping&limit=1'),
    ).timeout(const Duration(milliseconds: 1500));
    if (d is Map && d['code'] == 200) localApiOn.value = true;
  } catch (_) {
    /* 无本地服务，走公共 API 链 */
  }
}

/* ---------------- 搜索 ---------------- */

Track _trackFromPublicJson(Map<String, dynamic> s, String src) {
  final artist = s['artist'];
  return Track(
    id: '${s['id']}',
    name: '${s['name'] ?? ''}',
    artist: artist is List
        ? artist.map((a) => '$a').join(' / ')
        : (artist == null || '$artist'.isEmpty ? '未知歌手' : '$artist'),
    album: '${s['album'] ?? ''}',
    picId: '${s['pic_id'] ?? ''}',
    source: '${s['source'] ?? src}',
  );
}

/* ---------------- 网易直连（Rhine 用的那套） ---------------- */

/// 直接打 music.163.com 的站内接口：不经任何第三方镜像。
///
/// 这是「音乐数据库」项目的做法 —— 它对网易、QQ、酷狗都是直连平台本体，
/// 所以没有镜像挂了的风险。这里只取网易的搜索 + 详情（封面）：
/// 搜索 0.3s 级、详情一次批量补封面，比公共镜像快且稳。
Future<List<Track>> _searchNeteaseDirect(String keyword,
    {int limit = 24}) async {
  final uri = Uri.parse(kNeteaseSearch).replace(queryParameters: {
    's': keyword,
    'type': '1',
    'limit': '$limit',
    'offset': '0',
  });
  final d = await _getJson(uri);
  final result = (d is Map) ? d['result'] : null;
  final songs = (result is Map) ? result['songs'] : null;
  if (songs is! List || songs.isEmpty) return const [];

  final out = <Track>[];
  for (final raw in songs) {
    if (raw is! Map) continue;
    final m = raw.cast<String, dynamic>();
    final album = (m['album'] is Map) ? m['album'] as Map : const {};
    final artists = (m['artists'] is List) ? m['artists'] as List : const [];
    final names = artists
        .whereType<Map>()
        .map((a) => '${a['name'] ?? ''}')
        .where((n) => n.isNotEmpty)
        .join(' / ');
    out.add(Track(
      id: '${m['id']}',
      name: '${m['name'] ?? ''}',
      artist: names.isEmpty ? '未知歌手' : names,
      album: '${album['name'] ?? ''}',
      picId: album['picId'] == null ? '' : '${album['picId']}',
      source: 'netease',
    ));
  }
  await _fillNeteasePics(out);
  return out;
}

/// 批量补封面：搜索接口只给 picId，详情接口才带 picUrl。
/// ids 必须带方括号（`[1,2]`，URL 编码成 %5B…%5D），裸逗号会报 400。
Future<void> _fillNeteasePics(List<Track> list) async {
  if (list.isEmpty) return;
  try {
    final ids = list.map((t) => t.id).join(',');
    final uri = Uri.parse(kNeteaseDetail)
        .replace(queryParameters: {'ids': '[$ids]'});
    final d = await _getJson(uri);
    final songs = (d is Map) ? d['songs'] : null;
    if (songs is! List) return;
    final pics = <String, String>{};
    for (final raw in songs) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();
      final al = m['album'] ?? m['al'];
      final pic = (al is Map) ? al['picUrl'] : null;
      if (pic is String && pic.isNotEmpty) pics['${m['id']}'] = pic;
    }
    for (final t in list) {
      final pic = pics[t.id];
      if (pic != null && t.picUrl.isEmpty) {
        t.picUrl = pic.contains('?') ? pic : '$pic?param=300y300';
      }
    }
  } catch (_) {
    /* 封面缺失不致命，后面还有 types=pic 兜底 */
  }
}

/// 搜索（对应原版 search()）：本地 NCMApi 优先 → 网易 → 酷我
Future<List<Track>> searchTracks(String keyword) async {
  var list = <Track>[];

  // 本地 NCMApi 优先：完整曲库、无限流
  if (localApiOn.value) {
    try {
      final d = await _getJson(Uri.parse(
          '$kLocalApi/search?keywords=${Uri.encodeQueryComponent(keyword)}&limit=24'));
      final result = (d is Map) ? d['result'] : null;
      final songs = (result is Map) ? result['songs'] : null;
      list = (songs is List ? songs : const []).map((s) {
        final m = s as Map<String, dynamic>;
        final artists = (m['artists'] as List<dynamic>? ?? [])
            .map((a) => '${(a as Map<String, dynamic>)['name']}')
            .join(' / ');
        return Track(
          id: '${m['id']}',
          name: '${m['name'] ?? ''}',
          artist: artists.isEmpty ? '未知歌手' : artists,
          album: '${(m['album'] as Map<String, dynamic>?)?['name'] ?? ''}',
          source: 'local',
        );
      }).toList();
      // /search 不带封面，批量 /song/detail 补 picUrl
      if (list.isNotEmpty) {
        try {
          final ids = list.map((t) => t.id).join(',');
          final dd = await _getJson(Uri.parse('$kLocalApi/song/detail?ids=$ids'));
          final picMap = <String, String>{};
          for (final s in ((dd as Map)['songs'] as List<dynamic>? ?? [])) {
            final m = s as Map<String, dynamic>;
            final al = m['al'] as Map<String, dynamic>?;
            final pic = al?['picUrl'];
            if (pic != null) picMap['${m['id']}'] = '$pic?param=300y300';
          }
          for (final t in list) {
            final pic = picMap[t.id];
            if (pic != null) t.picUrl = pic;
          }
        } catch (_) {
          /* 封面缺失不致命 */
        }
      }
    } catch (_) {
      localApiOn.value = false;
    }
  }

  // 网易直连（中间没有镜像，最不容易挂）
  if (list.isEmpty) {
    try {
      list = await _searchNeteaseDirect(keyword);
    } catch (_) {
      /* 直连不通就退到镜像链 */
    }
  }

  // 公共镜像链：网易优先（常被限流），酷我兜底（稳定）
  if (list.isEmpty) {
    for (final src in kSources) {
      try {
        final d = await api(
            {'types': 'search', 'name': keyword, 'count': '24', 'pages': '1'},
            src);
        final arr = (d is List ? d : const [])
            .cast<Map<String, dynamic>>()
            .toList();
        list = arr.map((s) => _trackFromPublicJson(s, src)).toList();
        if (list.isNotEmpty) break;
      } catch (_) {
        /* 换下一个源 */
      }
    }
  }
  return list;
}

/* ---------------- 跨源解析（酷我 → 网易） ---------------- */

/// 酷我搜索稳定但播不了：用「歌名+歌手」搜网易匹配同名，换 netease id 走正常播放链
Future<Track?> resolveKuwoToNetease(Track track) async {
  try {
    final q = '${track.name} ${track.artist.split(' / ')[0]}';
    final d = await api(
        {'types': 'search', 'name': q, 'count': '5', 'pages': '1'}, 'netease');
    final arr = (d is List ? d : const []).cast<Map<String, dynamic>>().toList();
    if (arr.isEmpty) return null;
    final hit = arr.firstWhere((s) => s['name'] == track.name,
        orElse: () => arr.first);
    final id = hit['id'];
    if (id == null) return null;
    return track.copyWith(
      id: '$id',
      source: 'netease',
      picId: hit['pic_id'] == null ? null : '${hit['pic_id']}',
    );
  } catch (_) {
    return null;
  }
}

/* ---------------- 封面 ---------------- */

/// 公共源封面地址（types=pic）；本地源不走这里（picUrl 已直给）
Future<String?> fetchPicUrl(Track track, {int size = 500}) async {
  if (track.picId.isEmpty) return null;
  try {
    final d = await api(
        {'types': 'pic', 'id': track.picId, 'size': '$size'}, track.source);
    if (d is Map && d['url'] != null && '${d['url']}'.isNotEmpty) {
      return '${d['url']}';
    }
  } catch (_) {}
  return null;
}

/* ---------------- 歌词 ---------------- */

Future<String?> fetchLyricLrc(Track track) async {
  try {
  if (track.source == 'local') {
    final d = await _getJson(Uri.parse('$kLocalApi/lyric?id=${track.id}'));
    final lrc = (d is Map) ? d['lrc'] : null;
    if (lrc is Map && lrc['lyric'] != null) return '${lrc['lyric']}';
    return null;
  }
    final d = await api({'types': 'lyric', 'id': track.id}, track.source);
    if (d is Map && d['lyric'] != null && '${d['lyric']}'.isNotEmpty) {
      return '${d['lyric']}';
    }
  } catch (_) {}
  return null;
}

/* ---------------- 播放地址候选链 ---------------- */

/// 候选播放地址链（对应原版 playAt 内联逻辑）：
///  - 本地：song/url/v1 音质回退 → injahow netease 302 兜底
///  - 网易（公共）：GDStudio 码率回退(320→192→128) → injahow 302 兜底
///  - 酷我：injahow kuwo 302（约 1/3 命中）
Future<List<String>> urlCandidates(Track track) async {
  final urls = <String>[];
  if (track.source == 'file') {
    // 本地文件：路径即播放源，无候选链
    urls.add(track.id);
  } else if (track.source == 'local') {
    for (final lv in kLocalLevels) {
      try {
        final d = await _getJson(
            Uri.parse('$kLocalApi/song/url/v1?id=${track.id}&level=$lv'));
        final data = (d is Map) ? d['data'] : null;
        final first = (data is List && data.isNotEmpty) ? data[0] : null;
        final u = (first is Map) ? first['url'] : null;
        if (u != null && '$u'.isNotEmpty) {
          urls.add('$u');
          break;
        }
      } catch (_) {
        /* 换下一音质 */
      }
    }
    urls.add('$kApi2?server=netease&type=url&id=${track.id}');
  } else if (track.source == 'netease') {
    for (final br in kBitrates) {
      try {
        final d =
            await api({'types': 'url', 'id': track.id, 'br': '$br'}, 'netease');
        final u = (d is Map) ? d['url'] : null;
        if (u != null && '$u'.isNotEmpty) {
          urls.add('$u');
          break;
        }
      } catch (_) {
        /* 换下一码率 */
      }
    }
    // 直连平台取流：免费曲目 302 到 CDN；付费曲目 302 到 /404，
    // 引擎会把它当坏候选跳过（HTML 过不了时长探测）
    urls.add('$kNeteaseOuterUrl?id=${track.id}.mp3');
    urls.add('$kApi2?server=netease&type=url&id=${track.id}');
  } else {
    urls.add('$kApi2?server=kuwo&type=url&id=${track.id}');
  }
  return urls;
}

/* ---------------- 封面取色 → 主题色 + 调色板 ----------------
   对应原版 extractColors：24×24 缩略采样，
   c1 = 有效亮度区间均值色；c2 = 饱和度×亮度评分最高的单像素；
   palette = 5 位量化桶（5 位/通道 → 32768 桶）。 */


/// 下载封面 → 取色，经 [onResult] 回传 (c1, c2, palette)。
/// 网络/解码失败时静默保留默认配色（与原版 try/catch 行为一致）。
///
/// 注意：这里同样走 dart:io，会撞上 netease 图片 CDN 对非浏览器客户端的 403，
/// 所以必须复用 [imageUrlCandidates] 的候选 host 顺序（p3 优先）逐个试。
Future<void> extractColorsFromUrl(
  String url, {
  required void Function(Color c1, Color c2, List<Color> palette) onResult,
}) async {
  try {
    Uint8List? bytes;

    // 本地文件：直接读字节（file:// 或裸绝对路径）
    final localPath = localPathOf(url);
    if (localPath != null) {
      final f = File(localPath);
      if (await f.exists()) bytes = await f.readAsBytes();
    } else {
      for (final candidate in imageUrlCandidates(url)) {
        try {
          final resp = await _client
              .get(Uri.parse(candidate), headers: _kHeaders)
              .timeout(_kTimeout);
          if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
            bytes = resp.bodyBytes;
            break;
          }
        } catch (_) {
          continue; // 试下一个候选 host
        }
      }
    }
    if (bytes == null || bytes.isEmpty) return;

    final result = await extractColorsFromBytes(bytes);
    if (result == null) return;
    onResult(result.$1, result.$2, result.$3);
  } catch (_) {
    /* 跨域/解码失败时保留默认配色 */
  }
}
