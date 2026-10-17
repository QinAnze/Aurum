// 内嵌元数据解析回归测试。
//
// 用**合成字节**构造标签，不依赖本机音频文件：
//  - ID3v2.3 / v2.4 的帧长格式不同（BE32 vs syncsafe），混用会让逐帧走位全乱，
//    直接表现为「封面包、歌词全无」——这里用两个版本各测一遍。
//  - FLAC 的 PICTURE / VORBIS_COMMENT 布局。
//  - 无标签文件要安静地返回空。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum/audio/audio_cover.dart';
import 'package:flutter_test/flutter_test.dart';

/* ---------------- 字节构造工具 ---------------- */

int syncsafe(List<int> v) => (v[0] << 21) | (v[1] << 14) | (v[2] << 7) | v[3];

List<int> encSyncsafe(int n) =>
    [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

List<int> encBe32(int n) => [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];

List<int> encBe24(int n) => [(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];

List<int> encLe32(int n) => [n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF];

/// 一个假 JPEG（magic + 填充到指定长度）
Uint8List fakeJpeg(int len) {
  final b = Uint8List(len);
  b[0] = 0xFF;
  b[1] = 0xD8;
  b[2] = 0xFF;
  for (var i = 3; i < len; i++) {
    b[i] = i & 0xFF;
  }
  return b;
}

/// UTF-16LE + BOM 的字节
List<int> utf16le(String s) {
  final out = <int>[0xFF, 0xFE];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

/// 组装一个 ID3v2 标签文件（无音频数据，解析器只看标签）
Uint8List id3File({
  required int major,
  required List<List<int>> frames,
  int flags = 0,
}) {
  final body = <int>[];
  for (final f in frames) {
    body.addAll(f);
  }
  // 补一点 padding，模拟真实文件
  body.addAll(List<int>.filled(32, 0));

  final out = <int>[
    ...ascii.encode('ID3'),
    major,
    0,
    flags,
    ...encSyncsafe(body.length),
    ...body,
  ];
  return Uint8List.fromList(out);
}

/// ID3v2.3/v2.4 帧：id(4) + size(4) + flags(2) + body
List<int> frame(int major, String id, List<int> body) {
  final size = major >= 4 ? encSyncsafe(body.length) : encBe32(body.length);
  return [...ascii.encode(id), ...size, 0, 0, ...body];
}

/// APIC 帧体
List<int> apicBody(Uint8List data, {int enc = 0}) => [
      enc,
      ...ascii.encode('image/jpeg'),
      0,
      3, // COVER_FRONT
      0, // 空描述（latin1 终止符）
      ...data,
    ];

/// USLT 帧体（UTF-16 + BOM）
/// [desc] 非空时按真实文件的样子写：描述自带 BOM，后接 0x0000 终止符，再是正文。
List<int> usltBody(String lrc, {String desc = ''}) => [
      1, // encoding = UTF-16 with BOM
      ...ascii.encode('eng'),
      if (desc.isNotEmpty) ...[...utf16le(desc), 0, 0],
      ...utf16le(lrc),
    ];

/* ---------------- 测试 ---------------- */

void main() {
  late Directory tmp;
  var seq = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aurum_tags_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String write(List<int> bytes, String ext) {
    final f = File('${tmp.path}${Platform.pathSeparator}t${seq++}.$ext');
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  group('ID3v2 帧长', () {
    test('v2.3 的帧长是普通 32 位（330827 不能被当成 syncsafe）', () {
      const lrc = '[00:01.000]第一句\n[00:05.500]第二句';
      final pic = fakeJpeg(330827);
      final path = write(
        id3File(major: 3, frames: [
          frame(3, 'APIC', apicBody(pic)),
          frame(3, 'USLT', usltBody(lrc)),
        ]),
        'mp3',
      );

      final tags = readAudioTags(path);
      expect(tags.picture, isNotNull, reason: 'v2.3 大帧封面必须能取到');
      expect(tags.picture!.length, pic.length);
      expect(tags.picture![0], 0xFF);
      expect(tags.picture![1], 0xD8);
      expect(tags.lyrics, contains('[00:01.000]第一句'));
      expect(tags.lyrics, contains('第二句'));
    });

    test('v2.4 的帧长是 syncsafe', () {
      const lrc = '[00:02.000]v24 line';
      final pic = fakeJpeg(80000);
      final path = write(
        id3File(major: 4, frames: [
          frame(4, 'APIC', apicBody(pic)),
          frame(4, 'USLT', usltBody(lrc)),
        ]),
        'mp3',
      );

      final tags = readAudioTags(path);
      expect(tags.picture, isNotNull);
      expect(tags.picture!.length, pic.length);
      expect(tags.lyrics, contains('v24 line'));
    });

    test('标签超过 512KB 也不会被截断', () {
      // 真实文件里 600~1300KB 的 PNG/JPEG 封面很常见
      final pic = fakeJpeg(900 * 1024);
      final path = write(
        id3File(major: 3, frames: [frame(3, 'APIC', apicBody(pic))]),
        'mp3',
      );
      final tags = readAudioTags(path);
      expect(tags.picture, isNotNull);
      expect(tags.picture!.length, pic.length);
    });

    test('只有封面没有歌词 → lyrics 为 null', () {
      final path = write(
        id3File(major: 3, frames: [frame(3, 'APIC', apicBody(fakeJpeg(5000)))]),
        'mp3',
      );
      final tags = readAudioTags(path);
      expect(tags.picture, isNotNull);
      expect(tags.lyrics, isNull);
    });

    test('USLT 带非空描述时，描述不能混进歌词', () {
      // 真实文件常见写法：描述写的是 "Lyrics"，后面才是 LRC 正文。
      // 若把描述当正文，歌词首行会变成 "Lyrics[00:00.000]..."。
      const lrc = '[00:01.000]第一句\n[00:04.000]第二句';
      final path = write(
        id3File(major: 3, frames: [
          frame(3, 'USLT', usltBody(lrc, desc: 'Lyrics')),
        ]),
        'mp3',
      );

      final tags = readAudioTags(path);
      expect(tags.lyrics, isNotNull);
      expect(tags.lyrics!.startsWith('['), isTrue,
          reason: '开头必须是时间轴，不能是描述文字');
      expect(tags.lyrics, isNot(contains('Lyrics')));
      expect(tags.lyrics, contains('[00:01.000]第一句'));
    });
  });

  group('FLAC', () {
    /// 组装 FLAC：STREAMINFO + VORBIS_COMMENT + PICTURE
    Uint8List flacFile({String? lyrics, Uint8List? picture}) {
      final out = <int>[...ascii.encode('fLaC')];

      void block(int type, List<int> body, {required bool last}) {
        out.add((last ? 0x80 : 0) | type);
        out.addAll(encBe24(body.length));
        out.addAll(body);
      }

      block(0, List<int>.filled(34, 0), last: false);

      if (lyrics != null) {
        final vendor = ascii.encode('aurum-test');
        final entry = utf8.encode('LYRICS=$lyrics');
        block(4, [
          ...encLe32(vendor.length),
          ...vendor,
          ...encLe32(1),
          ...encLe32(entry.length),
          ...entry,
        ], last: false);
      }

      if (picture != null) {
        final mime = ascii.encode('image/jpeg');
        block(6, [
          ...encBe32(3), // picture type
          ...encBe32(mime.length), // PICTURE 里所有长度都是大端
          ...mime,
          ...encBe32(0), // 空描述
          ...encBe32(picture.length), // width（内容无所谓）
          ...encBe32(picture.length), // height
          ...encBe32(24), // depth
          ...encBe32(0), // colors
          ...encBe32(picture.length), // dataLen
          ...picture,
        ], last: true);
      } else {
        block(1, List<int>.filled(16, 0), last: true);
      }
      return Uint8List.fromList(out);
    }

    test('VORBIS_COMMENT 里的 LYRICS 能取到', () {
      const lrc = '[00:03.000]flac line';
      final path = write(flacFile(lyrics: lrc), 'flac');
      final tags = readAudioTags(path);
      expect(tags.lyrics, contains('flac line'));
    });

    test('PICTURE 块能取到', () {
      final pic = fakeJpeg(4000);
      final path = write(flacFile(picture: pic), 'flac');
      final tags = readAudioTags(path);
      expect(tags.picture, isNotNull);
      expect(tags.picture!.length, pic.length);
    });
  });

  group('异常输入', () {
    test('无标签文件返回空', () {
      final path = write(List<int>.filled(4096, 0x11), 'mp3');
      final tags = readAudioTags(path);
      expect(tags.picture, isNull);
      expect(tags.lyrics, isNull);
    });

    test('文件不存在不抛异常', () {
      final tags = readAudioTags('${tmp.path}${Platform.pathSeparator}nope.mp3');
      expect(tags.picture, isNull);
      expect(tags.lyrics, isNull);
    });

    test('截断的标签不会崩', () {
      final full = id3File(major: 3, frames: [
        frame(3, 'APIC', apicBody(fakeJpeg(5000))),
      ]);
      final path = write(full.sublist(0, 40), 'mp3');
      expect(() => readAudioTags(path), returnsNormally);
    });
  });
}
