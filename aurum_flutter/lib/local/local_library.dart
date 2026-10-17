/// Aurum · 本地音乐库（文件夹选择 → 递归扫描 → 元数据解析 → 内嵌封面）
///
/// 在线音源之外的一条完整链路：
///  - [pickMusicFolder] 用系统对话框选目录（桌面端）
///  - [scanFolder] 递归收集音频文件，带上限保护（防止误选磁盘根目录卡死）
///  - [parseFileName] 从文件名猜测 歌手 / 歌名（"歌手 - 歌名" 是主流命名）
///  - [embeddedCover] 读取文件内嵌封面，让本地歌也能驱动背景取色
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../audio/audio_cover.dart';
import '../models.dart';

/// 支持的音频扩展名（原版只走网络，这里补本地）
const Set<String> kAudioExts = {
  '.mp3',
  '.flac',
  '.wav',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
  '.wma',
};

/// 递归扫描的文件数上限：误选 C:\ 之类的根目录时及时止损
const int kMaxScanFiles = 4000;
/// 返回的音轨上限
const int kMaxTracks = 1500;

/// 跳过明显不含音乐的目录（缩短扫描时间）
const Set<String> kSkipDirs = {
  'node_modules',
  '.git',
  '.svn',
  'windows',
  'system32',
  'appdata',
  'program files',
  'program files (x86)',
  '\$recycle.bin',
  'cache',
  'temp',
  'tmp',
};

/// 选择音乐文件夹；用户取消或平台不支持时返回 null
Future<String?> pickMusicFolder() async {
  try {
    return await getDirectoryPath(confirmButtonText: '就这个喵');
  } catch (_) {
    return null;
  }
}

/// 扫描目录 → 音轨列表。
///
/// 排序规则：父目录名 → 文件名，保证同一目录的专辑相邻且结果稳定，
/// 不依赖文件系统返回顺序（不同平台顺序不一致会让列表跳动）。
Future<List<Track>> scanFolder(String dir) async {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];

  // 只按「相对扫描根目录」的路径段做跳过判断：
  // 用户完全可能把音乐放在 ...\AppData\...\Temp 这类目录里，
  // 用绝对路径判断会把整个根目录一起毙掉。
  final base = _trimSep(dir);

  final found = <_Found>[];
  var scanned = 0;
  try {
    final stream = root.list(recursive: true, followLinks: false);
    await for (final entity in stream) {
      if (++scanned > kMaxScanFiles) break;
      if (entity is! File) continue;
      if (_inSkipDir(base, entity.path)) continue;
      final lower = entity.path.toLowerCase();
      if (!kAudioExts.any(lower.endsWith)) continue;
      found.add(_Found(entity.path));
      if (found.length >= kMaxTracks) break;
    }
  } catch (_) {
    // 权限不足 / 路径非法：返回已收集到的部分
  }

  found.sort((a, b) {
    final c = a.dir.compareTo(b.dir);
    return c != 0 ? c : a.file.compareTo(b.file);
  });

  return [
    for (final f in found)
      Track(
        id: f.path,
        name: f.title,
        artist: f.artist,
        album: f.dirName,
        source: 'file',
      ),
  ];
}

class _Found {
  _Found(this.path)
      : dir = _dirOf(path),
        file = _baseOf(path) {
    final parsed = parseFileName(_stemOf(file));
    title = parsed.name;
    artist = parsed.artist;
  }

  final String path;
  final String dir;
  final String file;
  late final String title;
  late final String artist;

  String get dirName => _baseOf(dir);
}

String _dirOf(String p) {
  final i = p.lastIndexOf('\\');
  final j = p.lastIndexOf('/');
  final k = i > j ? i : j;
  return k <= 0 ? '' : p.substring(0, k);
}

String _baseOf(String p) {
  final i = p.lastIndexOf('\\');
  final j = p.lastIndexOf('/');
  final k = i > j ? i : j;
  return k < 0 ? p : p.substring(k + 1);
}

String _stemOf(String fileName) {
  final i = fileName.lastIndexOf('.');
  return i <= 0 ? fileName : fileName.substring(0, i);
}

/// 去掉末尾的路径分隔符（`D:\Music\` → `D:\Music`，`/` 同理）
String _trimSep(String p) {
  var s = p;
  while (s.length > 1 && (s.endsWith('\\') || s.endsWith('/'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// [path] 是否位于 [base] 之下的某个「跳过目录」里。
/// 只看相对于 base 的路径段，避免把根目录自身的祖先目录（如
/// `...\AppData\Local\Temp`）也算进来。
bool _inSkipDir(String base, String path) {
  final rel = path.length > base.length ? path.substring(base.length) : '';
  if (rel.isEmpty) return false;
  for (final seg in rel.split(_rePathSep)) {
    if (seg.isEmpty) continue;
    if (kSkipDirs.contains(seg.toLowerCase())) return true;
  }
  return false;
}

final RegExp _rePathSep = RegExp(r'[\\/]');

/* 名称解析用的正则。
   源码保持纯 ASCII —— 中文标点与破折号一律用 \\uXXXX 转义。 */

/// 开头轨道序号：01 / 01. / 01- / 01_ / 01、
final RegExp _reTrackNo = RegExp(r'^\d{1,3}\s*[.\-_\u3001]\s*');

/// 尾部杂注：方括号 / 圆括号 / 六角括号包裹的标记
final RegExp _reSuffix =
    RegExp('\\s*[([\\u3010][^\\]()\\u3010\\u3011]*[)\\]\\u3011]\\s*\$');

/// 歌手 / 歌名分隔符：按优先级依次尝试，避免误切歌名里的连字符
const List<String> _kNameSeps = <String>[
  '\\s+-\\s+', // " - " 最常见
  '\\s+–\\s+', // en dash
  '\\s+—\\s+', // em dash
  '\\s+_\\s+', // 下划线
];

/// 从文件名（不含扩展名）解析 歌手 / 歌名。
///
/// 主流下载器命名是「歌手 - 歌名」，也有「01. 歌手 - 歌名」「歌名」等变体。
/// 只在**分隔符两侧都有内容**时才认定是「歌手 - 歌名」格式，
/// 否则整串当作歌名（避免把 "A-B" 这类歌名误切成两段）。
({String name, String artist}) parseFileName(String stem) {
  var s = stem.trim();

  s = s.replaceFirst(_reTrackNo, '');
  s = s.replaceAll(_reSuffix, '');
  s = s.trim();
  if (s.isEmpty) s = stem.trim();

  for (final sep in _kNameSeps) {
    final m = RegExp('^(.*?)$sep(.*)\$').firstMatch(s);
    if (m == null) continue;
    final left = (m.group(1) ?? '').trim();
    final right = (m.group(2) ?? '').trim();
    if (left.isEmpty || right.isEmpty) continue;
    return (name: right, artist: left);
  }

  return (name: s, artist: '本地音乐');
}

/* ---------------- 歌词（内嵌优先，退回同名 .lrc） ---------------- */

/// 取本地歌的歌词。
///
/// 顺序：音频内嵌（ID3v2 USLT/SYLT、FLAC/Vorbis LYRICS、M4A ©lyr）
/// → 同目录同名 `.lrc`。内嵌的大多本身就是带 `[mm:ss.xxx]` 的 LRC，
/// 可直接进解析器；没有时间轴的纯文本也能作为静态歌词显示。
Future<String?> localLyrics(String audioPath) async {
  final embedded = embeddedLyrics(audioPath);
  if (embedded != null && embedded.trim().isNotEmpty) return embedded;
  return siblingLrc(audioPath);
}

/// 查找同目录下的同名 .lrc 歌词（本地库没有在线歌词接口）。
/// 命中返回 LRC 文本，否则 null。
Future<String?> siblingLrc(String audioPath) async {
  try {
    final dir = Directory(_dirOf(audioPath));
    if (!await dir.exists()) return null;
    final stem = _stemOf(_baseOf(audioPath));
    final target = File('${dir.path}${Platform.pathSeparator}$stem.lrc');
    if (target.existsSync()) {
      return await target.readAsString();
    }
  } catch (_) {
    /* 无权限 / 非法路径 */
  }
  return null;
}

/* ---------------- 封面导出 ---------------- */

/// 同目录封面图候选名（专辑目录里很常见，内嵌缺失时用）
const List<String> _kSiblingCoverNames = [
  'cover',
  'folder',
  'front',
  'album',
  'albumart',
  'albumartsmall',
];
const List<String> _kImageExts = ['.jpg', '.jpeg', '.png', '.webp'];

/// 取本地歌的封面 URL。
///
/// 顺序：音频内嵌封面 → 同目录同名图 → 同目录 cover/folder/front 系列。
/// 命中后落盘为临时文件返回 `file://`，这样显示层与取色层都能沿用
/// 现有的「按 URL 取图」接口。文件名取路径 hash，重复播放直接复用缓存。
/// 全都没有 → null（调用方显示占位图 + 默认主题色）。
Future<String?> localCoverUrl(String audioPath) async {
  final bytes = embeddedCover(audioPath);
  if (bytes != null && bytes.isNotEmpty) {
    return _writeCoverCache(audioPath, bytes);
  }
  return _siblingCoverUrl(audioPath);
}

Future<String?> _writeCoverCache(String audioPath, List<int> bytes) async {
  try {
    final sep = Platform.pathSeparator;
    final dir = Directory('${Directory.systemTemp.path}${sep}aurum_covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}$sep${audioPath.hashCode.toRadixString(36)}');
    if (!f.existsSync() || f.lengthSync() != bytes.length) {
      await f.writeAsBytes(bytes, flush: true);
    }
    return Uri.file(f.path).toString();
  } catch (_) {
    return null;
  }
}

/// 找同目录的图片文件：先试与歌同名的，再试通用封面名
Future<String?> _siblingCoverUrl(String audioPath) async {
  try {
    final dirPath = _dirOf(audioPath);
    if (dirPath.isEmpty) return null;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    final stem = _stemOf(_baseOf(audioPath)).toLowerCase();
    final files = <String, String>{}; // 小写名 → 原名
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final base = _baseOf(e.path);
      final dot = base.lastIndexOf('.');
      if (dot <= 0) continue;
      if (!_kImageExts.contains(base.substring(dot).toLowerCase())) continue;
      files[base.toLowerCase()] = e.path;
    }
    if (files.isEmpty) return null;

    // 1) 与歌同名（同名图优先）
    for (final ext in _kImageExts) {
      final hit = files['$stem$ext'];
      if (hit != null) return Uri.file(hit).toString();
    }
    // 2) 通用封面名
    for (final name in _kSiblingCoverNames) {
      for (final ext in _kImageExts) {
        final hit = files['$name$ext'];
        if (hit != null) return Uri.file(hit).toString();
      }
    }
  } catch (_) {
    /* 无权限 */
  }
  return null;
}
