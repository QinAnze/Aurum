// 本地媒体（封面 / 歌词）取用顺序回归测试。
//
// 规则：内嵌优先 → 同目录同名文件 → 目录通用封面；都没有则返回 null，
// 由界面显示占位图并用默认主题色（不能留着上一首的图）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum/local/local_library.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _encSyncsafe(int n) =>
    [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

List<int> _encBe32(int n) =>
    [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];

Uint8List _fakeJpeg(int len) {
  final b = Uint8List(len);
  b[0] = 0xFF;
  b[1] = 0xD8;
  return b;
}

List<int> _utf16le(String s) {
  final out = <int>[0xFF, 0xFE];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

/// 带 APIC(+USLT) 的 ID3v2.3 文件（无音频，够解析器用）
Uint8List _mp3({Uint8List? pic, String? lrc}) {
  final body = <int>[];
  if (pic != null) {
    // 帧体 = enc(1) + mime("image/jpeg"=10) + \0(1) + picType(1) + desc\0(1) + data
    final f = [
      ...ascii.encode('APIC'),
      ..._encBe32(1 + 10 + 1 + 1 + 1 + pic.length),
      0, 0,
      0, // latin1
      ...ascii.encode('image/jpeg'), 0,
      3, 0,
      ...pic,
    ];
    body.addAll(f);
  }
  if (lrc != null) {
    final text = _utf16le(lrc);
    body.addAll([
      ...ascii.encode('USLT'),
      ..._encBe32(4 + text.length),
      0, 0,
      1, // UTF-16 with BOM
      ...ascii.encode('eng'),
      ...text,
    ]);
  }
  body.addAll(List<int>.filled(16, 0));
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3, 0, 0,
    ..._encSyncsafe(body.length),
    ...body,
  ]);
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('aurum_media_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String pathOf(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  group('localLyrics', () {
    test('内嵌歌词优先于同名 .lrc', () async {
      final p = pathOf('a.mp3');
      File(p).writeAsBytesSync(_mp3(lrc: '[00:01.000]内嵌'));
      File(pathOf('a.lrc')).writeAsStringSync('[00:01.000]外部');

      final lrc = await localLyrics(p);
      expect(lrc, contains('内嵌'));
    });

    test('没有内嵌 → 退回同名 .lrc', () async {
      final p = pathOf('b.mp3');
      File(p).writeAsBytesSync(_mp3());
      File(pathOf('b.lrc')).writeAsStringSync('[00:02.000]外部');

      final lrc = await localLyrics(p);
      expect(lrc, contains('外部'));
    });

    test('两者都没有 → null', () async {
      final p = pathOf('c.mp3');
      File(p).writeAsBytesSync(_mp3());
      expect(await localLyrics(p), isNull);
    });
  });

  group('localCoverUrl', () {
    test('内嵌封面落盘为可读的 file:// URL', () async {
      final p = pathOf('d.mp3');
      File(p).writeAsBytesSync(_mp3(pic: _fakeJpeg(2048)));

      final url = await localCoverUrl(p);
      expect(url, isNotNull);
      expect(url!, startsWith('file:'));

      final f = File(Uri.parse(url).toFilePath());
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), 2048);
      expect(f.readAsBytesSync()[0], 0xFF);
    });

    test('无内嵌 → 用同目录同名图', () async {
      final p = pathOf('e.mp3');
      File(p).writeAsBytesSync(_mp3());
      File(pathOf('e.jpg')).writeAsBytesSync(_fakeJpeg(128));

      final url = await localCoverUrl(p);
      expect(url, isNotNull);
      final f = File(Uri.parse(url!).toFilePath());
      expect(f.lengthSync(), 128);
    });

    test('无内嵌也无同名 → 退回目录通用封面 cover.jpg', () async {
      final p = pathOf('f.mp3');
      File(p).writeAsBytesSync(_mp3());
      File(pathOf('cover.jpg')).writeAsBytesSync(_fakeJpeg(64));

      final url = await localCoverUrl(p);
      expect(url, isNotNull);
      expect(File(Uri.parse(url!).toFilePath()).lengthSync(), 64);
    });

    test('完全没有封面 → null（界面据此清空旧图 + 回默认配色）', () async {
      final p = pathOf('g.mp3');
      File(p).writeAsBytesSync(_mp3());
      expect(await localCoverUrl(p), isNull);
    });
  });
}
