/// Aurum · 音频文件内嵌元数据（封面 / 歌词 / 基本信息）
///
/// 本地文件没有元数据库，封面与歌词只能从容器里挖：
///  - MP3  → ID3v2 的 `APIC`（封面）、`USLT` / `SYLT`（歌词，通常直接就是 LRC 文本）
///  - FLAC → `PICTURE` 块（封面）、`VORBIS_COMMENT` 的 `LYRICS` 字段
///  - M4A  → `ilst` 下的 `covr`（封面）、`©lyr`（歌词）
///
/// 两个关键细节（都踩过）：
/// 1. **帧长必须按版本解析**：ID3v2.3 的帧长是普通 32 位大端，v2.4 才是 syncsafe。
///    早期实现取了「syncsafe 与 32 位里较小的那个」当作长度，
///    v2.3 下 330827 会被算成 83531 → 逐帧走位全乱 → 永远找不到 APIC。
/// 2. **标签总长要按头部的 size 读**，不能固定读 512KB：
///    内嵌 PNG 封面常见 600~700KB，固定窗口会把标签截断。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 标签读取上限：防损坏文件把整个文件读进内存
const int _kMaxTagBytes = 24 * 1024 * 1024;

/// 解析结果（均为 null 表示文件里没有）
class AudioTags {
  const AudioTags({this.picture, this.lyrics, this.title, this.artist,
      this.album});

  final Uint8List? picture;

  /// 歌词原文。绝大多数国内文件把整段 LRC（含 `[mm:ss.xxx]` 时间轴）
  /// 塞进 USLT / LYRICS 字段，所以这里可能就是可直接解析的 LRC。
  final String? lyrics;

  final String? title;
  final String? artist;
  final String? album;

  static const AudioTags empty = AudioTags();
}

/// 读取内嵌元数据；解析失败一律返回 [AudioTags.empty]（不抛异常）。
AudioTags readAudioTags(String path) {
  RandomAccessFile? raf;
  try {
    final f = File(path);
    if (!f.existsSync()) return AudioTags.empty;
    final len = f.lengthSync();
    if (len < 12) return AudioTags.empty;
    raf = f.openSync();
    final head = raf.readSync(16);
    if (head.length >= 10 && _ascii(head, 0, 3) == 'ID3') {
      return _readId3(raf, head);
    }
    if (head.length >= 4 && _ascii(head, 0, 4) == 'fLaC') {
      return _readFlac(raf, len);
    }
    if (head.length >= 12 && _ascii(head, 4, 4) == 'ftyp') {
      return _readMp4(raf, len);
    }
  } catch (_) {
    /* 损坏 / 无权限 */
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return AudioTags.empty;
}

/// 兼容旧入口：只取封面
Uint8List? embeddedCover(String path) => readAudioTags(path).picture;

/// 兼容旧入口：只取歌词
String? embeddedLyrics(String path) => readAudioTags(path).lyrics;

/* ================================================================
   ID3v2（MP3）
   ================================================================ */

AudioTags _readId3(RandomAccessFile raf, Uint8List head) {
  final major = head[3]; // 2 / 3 / 4
  final flags = head[5];
  var size = _syncsafe(head, 6); // 各版本标签总长都是 syncsafe
  if (size <= 0) return AudioTags.empty;
  if (size > _kMaxTagBytes) size = _kMaxTagBytes;
  raf.setPositionSync(10);
  var body = raf.readSync(size);
  if (body.isEmpty) return AudioTags.empty;
  // 标签级反同步：0xFF 0x00 → 0xFF
  if ((flags & 0x80) != 0) body = _deunsync(body);
  return _parseId3Frames(body, major, flags);
}

AudioTags _parseId3Frames(Uint8List b, int major, int flags) {
  final v22 = major == 2;
  final idLen = v22 ? 3 : 4;
  final hdrLen = v22 ? 6 : 10;

  var pos = 0;
  if ((flags & 0x40) != 0 && b.length >= 4) {
    // 扩展头：v2.4 的长度包含自身（syncsafe），v2.3 是 4 字节大端且不含自身
    pos = major >= 4 ? _syncsafe(b, 0) : 4 + _be32(b, 0);
  }

  Uint8List? picture;
  String? lyrics, title, artist, album;

  while (pos + hdrLen <= b.length) {
    if (b[pos] == 0) break; // 进入 padding
    final id = _ascii(b, pos, idLen);
    if (id.isEmpty) break;

    final int size;
    if (v22) {
      size = _be24(b, pos + 3);
    } else if (major >= 4) {
      size = _syncsafe(b, pos + 4); // v2.4：syncsafe
    } else {
      size = _be32(b, pos + 4); // v2.3：普通 32 位
    }

    final start = pos + hdrLen;
    if (size <= 0 || start + size > b.length) break;
    final end = start + size;

    if (id == 'APIC') {
      picture ??= _apic(b, start, end);
    } else if (id == 'PIC') {
      picture ??= _pic(b, start, end); // v2.2
    } else if (id == 'USLT' || id == 'ULT') {
      lyrics ??= _uslt(b, start, end);
    } else if (id == 'SYLT') {
      lyrics ??= _sylt(b, start, end);
    } else if (id == 'TIT2' || id == 'TT2') {
      title ??= _decodeText(b, start, end, b[start]);
    } else if (id == 'TPE1' || id == 'TP1') {
      artist ??= _decodeText(b, start, end, b[start]);
    } else if (id == 'TALB' || id == 'TAL') {
      album ??= _decodeText(b, start, end, b[start]);
    }

    pos = end;
  }

  return AudioTags(
    picture: picture,
    lyrics: _clean(lyrics),
    title: _clean(title),
    artist: _clean(artist),
    album: _clean(album),
  );
}

/// APIC：encoding(1) mime\0 picType(1) desc\0 data
Uint8List? _apic(Uint8List b, int start, int end) {
  if (end - start < 5) return null;
  final enc = b[start];
  var p = start + 1;
  final mimeEnd = _indexOfZero(b, p, end);
  if (mimeEnd < 0) return null;
  p = mimeEnd + 1;
  if (p >= end) return null;
  p++; // picture type
  p = _afterTerminatedText(b, p, end, enc);
  if (p <= 0 || p >= end) return null;
  return Uint8List.sublistView(b, p, end);
}

/// PIC（v2.2）：encoding(1) 图片格式(3) picType(1) desc\0 data
Uint8List? _pic(Uint8List b, int start, int end) {
  if (end - start < 6) return null;
  final enc = b[start];
  var p = start + 1 + 3; // 跳过 3 字节格式串（JPG/PNG）
  if (p >= end) return null;
  p++; // picture type
  p = _afterTerminatedText(b, p, end, enc);
  if (p <= 0 || p >= end) return null;
  return Uint8List.sublistView(b, p, end);
}

/// USLT：encoding(1) language(3) desc\0 text
///
/// 两处真实世界的差异都要容错：
///  - 描述可以非空（很多文件写的是 "Lyrics"），必须跳过，否则歌词会以
///    "Lyrics" 开头；
///  - 空描述时有的写入器不写终止符，语言码后直接就是正文（此时找不到
///    终止符，就把当前位置当正文起点）。
String? _uslt(Uint8List b, int start, int end) {
  if (end - start < 5) return null;
  final enc = b[start];
  final wide = enc == 1 || enc == 2;
  var p = start + 4;

  final term = _indexOfTerminator(b, p, end, wide);
  if (term >= 0) p = term + (wide ? 2 : 1);
  if (p >= end) return null;
  return _decodeText(b, p, end, enc);
}

/// SYLT：encoding(1) language(3) timeFormat(1) contentType(1) desc\0
///       + [text\0 timestamp(4)]*
/// 时间戳格式 2 = 毫秒；其余（MPEG 帧）少见，直接放弃。
String? _sylt(Uint8List b, int start, int end) {
  if (end - start < 9) return null;
  final enc = b[start];
  final timeFormat = b[start + 4];
  if (timeFormat != 2) return null;
  var p = _afterTerminatedText(b, start + 6, end, enc);
  if (p <= 0 || p >= end) return null;

  final wide = enc == 1 || enc == 2;
  final out = <String>[];
  while (p < end) {
    final textEnd = _indexOfTerminator(b, p, end, wide);
    if (textEnd < 0) break;
    final text = _decodeText(b, p, textEnd, enc)?.trim();
    var q = textEnd + (wide ? 2 : 1);
    if (q + 4 > end) break;
    final ms = _be32(b, q);
    q += 4;
    if (text != null && text.isNotEmpty) {
      out.add('[${_lrcStamp(ms)}]$text');
    }
    p = q;
  }
  return out.isEmpty ? null : out.join('\n');
}

String _lrcStamp(int ms) {
  final total = ms < 0 ? 0 : ms;
  final m = total ~/ 60000;
  final s = (total % 60000) ~/ 1000;
  final cs = (total % 1000) ~/ 10;
  return '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}.'
      '${cs.toString().padLeft(2, '0')}';
}

/* ================================================================
   FLAC
   ================================================================ */

AudioTags _readFlac(RandomAccessFile raf, int fileLen) {
  var pos = 4; // 跳过 'fLaC'
  Uint8List? picture;
  String? lyrics, title, artist, album;

  while (pos + 4 <= fileLen) {
    raf.setPositionSync(pos);
    final hdr = raf.readSync(4);
    if (hdr.length < 4) break;
    final last = (hdr[0] & 0x80) != 0;
    final type = hdr[0] & 0x7F;
    final len = _be24(hdr, 1);
    pos += 4;
    if (len < 0 || pos + len > fileLen) break;

    // 只读需要的块：PICTURE(6) / VORBIS_COMMENT(4)
    if ((type == 6 && picture == null) || type == 4) {
      if (len <= _kMaxTagBytes) {
        raf.setPositionSync(pos);
        final body = raf.readSync(len);
        if (type == 6 && picture == null) {
          picture = _flacPicture(body);
        } else if (type == 4) {
          final c = _vorbisComment(body);
          lyrics ??= _clean(c['LYRICS'] ??
              c['UNSYNCEDLYRICS'] ??
              c['UNSYNCHRONISEDLYRICS'] ??
              c['SYNCEDLYRICS']);
          title ??= _clean(c['TITLE']);
          artist ??= _clean(c['ARTIST']);
          album ??= _clean(c['ALBUM']);
        }
      }
    }
    pos += len;
    if (last) break;
  }

  return AudioTags(
    picture: picture,
    lyrics: lyrics,
    title: title,
    artist: artist,
    album: album,
  );
}

/// PICTURE：type(4) mimeLen(4) mime descLen(4) desc w(4) h(4) depth(4) colors(4)
///          dataLen(4) data
Uint8List? _flacPicture(Uint8List b) {
  var p = 4;
  if (p + 4 > b.length) return null;
  final mimeLen = _be32(b, p);
  p += 4 + mimeLen;
  if (p + 4 > b.length) return null;
  final descLen = _be32(b, p);
  p += 4 + descLen;
  p += 16; // width / height / depth / colors
  if (p + 4 > b.length) return null;
  final dataLen = _be32(b, p);
  p += 4;
  if (dataLen <= 0 || p + dataLen > b.length) return null;
  return Uint8List.sublistView(b, p, p + dataLen);
}

/// VORBIS_COMMENT：vendorLen(4) vendor count(4) [len(4) KEY=value]*
Map<String, String> _vorbisComment(Uint8List b) {
  final out = <String, String>{};
  try {
    var p = 0;
    if (p + 4 > b.length) return out;
    final vendorLen = _le32(b, p);
    p += 4 + vendorLen;
    if (p + 4 > b.length) return out;
    final count = _le32(b, p);
    p += 4;
    for (var i = 0; i < count && p + 4 <= b.length; i++) {
      final len = _le32(b, p);
      p += 4;
      if (len < 0 || p + len > b.length) break;
      final kv = utf8.decode(
        Uint8List.sublistView(b, p, p + len),
        allowMalformed: true,
      );
      p += len;
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      out[kv.substring(0, eq).toUpperCase()] = kv.substring(eq + 1);
    }
  } catch (_) {}
  return out;
}

/* ================================================================
   MP4 / M4A
   ================================================================ */

AudioTags _readMp4(RandomAccessFile raf, int fileLen) {
  Uint8List? picture;
  String? lyrics, title, artist, album;

  // moov 可能在文件头（faststart）也可能在尾部，两头各扫一段
  final window = 8 * 1024 * 1024;
  final ranges = <(int, int)>[
    (0, fileLen < window ? fileLen : window),
    if (fileLen > window) (fileLen - window, fileLen),
  ];

  for (final (from, to) in ranges) {
    raf.setPositionSync(from);
    final buf = raf.readSync(to - from);
    if (buf.length < 8) continue;
    final moov = _findAtom(buf, 'moov');
    if (moov == null) continue;
    final ilst = _findNested(moov, const ['udta', 'meta', 'ilst']);
    if (ilst == null) continue;

    picture ??= _mp4Covr(ilst);
    final lyr = _findAtom(ilst, '\u00A9lyr');
    if (lyr != null) lyrics ??= _mp4DataText(lyr);
    final nam = _findAtom(ilst, '\u00A9nam');
    if (nam != null) title ??= _mp4DataText(nam);
    final art = _findAtom(ilst, '\u00A9ART');
    if (art != null) artist ??= _mp4DataText(art);
    final alb = _findAtom(ilst, '\u00A9alb');
    if (alb != null) album ??= _mp4DataText(alb);
    break;
  }

  return AudioTags(
    picture: picture,
    lyrics: _clean(lyrics),
    title: _clean(title),
    artist: _clean(artist),
    album: _clean(album),
  );
}

/// 在容器内查找指定 fourcc 的子 atom，返回其**内容**（不含 8 字节头）
Uint8List? _findAtom(Uint8List b, String type) {
  final target = _fourcc(type);
  var p = 0;
  while (p + 8 <= b.length) {
    final size = _be32(b, p);
    if (size < 8 || p + size > b.length) break;
    if (_matches(b, p + 4, target)) {
      return Uint8List.sublistView(b, p + 8, p + size);
    }
    p += size;
  }
  return null;
}

/// 逐层进入容器（跳过 meta 的 4 字节 version/flags）
Uint8List? _findNested(Uint8List b, List<String> path) {
  var cur = b;
  for (final name in path) {
    final body = _findAtom(cur, name);
    if (body == null) return null;
    // meta 是 full atom：前 4 字节是 version + flags
    cur = name == 'meta' && body.length > 4 ? Uint8List.sublistView(body, 4) : body;
  }
  return cur;
}

/// covr：内含一个 data atom（size + 'data' + type(4) + locale(4) + payload）
Uint8List? _mp4Covr(Uint8List b) {
  final covr = _findAtom(b, 'covr');
  if (covr == null || covr.length < 16) return null;
  final data = _findAtom(covr, 'data');
  if (data == null || data.length <= 8) return null;
  return Uint8List.sublistView(data, 8, data.length);
}

/// 文本 atom（©lyr 等）：data atom 里 payload 同样是 type + locale + 文本
String? _mp4DataText(Uint8List container) {
  final data = _findAtom(container, 'data');
  if (data == null || data.length <= 8) return null;
  final payload = Uint8List.sublistView(data, 8, data.length);
  // type 字段低 24 位：1 = UTF-8, 2 = UTF-16BE
  final type = (_be32(data, 0) & 0xFFFFFF);
  if (type == 2) return _utf16(payload, 0, payload.length, false);
  return utf8.decode(payload, allowMalformed: true);
}

/* ================================================================
   文本解码 / 工具
   ================================================================ */

/// ID3 文本编码：0=ISO-8859-1，1=UTF-16(BOM)，2=UTF-16BE，3=UTF-8
String? _decodeText(Uint8List b, int start, int end, int enc) {
  if (start < 0 || start >= end || end > b.length) return null;
  try {
    switch (enc) {
      case 1:
        return _utf16(b, start, end, null); // 由 BOM 决定端序
      case 2:
        return _utf16(b, start, end, false); // 无 BOM，固定大端
      case 3:
        return utf8.decode(Uint8List.sublistView(b, start, end),
            allowMalformed: true);
      default:
        // Latin-1：字节值即码位
        return String.fromCharCodes(b, start, end);
    }
  } catch (_) {
    return null;
  }
}

/// UTF-16 解码；[bigEndian] 为 null 时读 BOM 决定端序（缺省按小端）
String? _utf16(Uint8List b, int start, int end, bool? bigEndian) {
  var p = start;
  var be = bigEndian ?? false;
  if (bigEndian == null) {
    if (p + 1 < end && b[p] == 0xFF && b[p + 1] == 0xFE) {
      be = false;
      p += 2;
    } else if (p + 1 < end && b[p] == 0xFE && b[p + 1] == 0xFF) {
      be = true;
      p += 2;
    }
  }
  final sb = StringBuffer();
  while (p + 1 < end) {
    final u = be ? (b[p] << 8 | b[p + 1]) : (b[p + 1] << 8 | b[p]);
    p += 2;
    if (u == 0) continue; // 文本里的 NUL 直接丢掉
    if (u >= 0xD800 && u <= 0xDBFF && p + 1 < end) {
      final lo = be ? (b[p] << 8 | b[p + 1]) : (b[p + 1] << 8 | b[p]);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        p += 2;
        sb.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00));
        continue;
      }
    }
    sb.writeCharCode(u);
  }
  return sb.toString();
}

/// 找到文本终止符，返回其**之后**的位置；找不到返回 -1
int _afterTerminatedText(Uint8List b, int p, int end, int enc) {
  final wide = enc == 1 || enc == 2;
  final t = _indexOfTerminator(b, p, end, wide);
  if (t < 0) return -1;
  return t + (wide ? 2 : 1);
}

/// 终止符位置：UTF-16 是 0x0000（按 2 字节步进对齐扫描）
int _indexOfTerminator(Uint8List b, int p, int end, bool wide) {
  if (wide) {
    var q = p;
    while (q + 1 < end) {
      if (b[q] == 0 && b[q + 1] == 0) return q;
      q += 2;
    }
    return -1;
  }
  return _indexOfZero(b, p, end);
}

int _indexOfZero(Uint8List b, int p, int end) {
  for (var i = p; i < end; i++) {
    if (b[i] == 0) return i;
  }
  return -1;
}

/// 标签级反同步还原：0xFF 0x00 → 0xFF
Uint8List _deunsync(Uint8List b) {
  final out = <int>[];
  for (var i = 0; i < b.length; i++) {
    out.add(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return Uint8List.fromList(out);
}

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll('\u0000', '').trim();
  return t.isEmpty ? null : t;
}

String _ascii(Uint8List b, int start, int len) {
  if (start < 0 || start + len > b.length) return '';
  final buf = StringBuffer();
  for (var i = start; i < start + len; i++) {
    final c = b[i];
    if (c < 32 || c > 126) return '';
    buf.writeCharCode(c);
  }
  return buf.toString();
}

Uint8List _fourcc(String s) {
  final codes = s.codeUnits;
  return Uint8List.fromList(
      [for (var i = 0; i < 4; i++) i < codes.length ? codes[i] & 0xFF : 0]);
}

bool _matches(Uint8List b, int p, Uint8List target) {
  if (p + 4 > b.length) return false;
  for (var i = 0; i < 4; i++) {
    if (b[p + i] != target[i]) return false;
  }
  return true;
}

int _be32(Uint8List b, int p) =>
    (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

int _be24(Uint8List b, int p) => (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];

int _le32(Uint8List b, int p) =>
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);

/// ID3 同步安全整数（每字节只用低 7 位）
int _syncsafe(Uint8List b, int p) =>
    (b[p] << 21) | (b[p + 1] << 14) | (b[p + 2] << 7) | b[p + 3];
