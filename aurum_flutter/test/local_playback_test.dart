// 本地歌播放链路的端到端回归测试（引擎用桩，不碰网络与音频设备）。
//
// 覆盖用户报的两个问题：
//  1. 本地歌点开后有封面、有歌词（内嵌 USLT 的 LRC）
//  2. 换到「没有封面」的歌时，上一首的封面/主题色必须被清掉，
//     否则界面会顶着上一首的图 —— 即「点本地歌封面错位」

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aurum/audio/player_engine.dart';
import 'package:aurum/models.dart';
import 'package:aurum/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 能播放但不出声的引擎桩
class _StubEngine implements PlayerEngine {
  @override
  Future<void> init() async {}
  @override
  Future<bool> loadAndPlay(List<String> urls) async => true;
  @override
  bool get hasSource => true;
  @override
  bool get isPlaying => false;
  @override
  double get positionSec => 0;
  @override
  double get durationSec => 0;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(double sec) async {}
  @override
  double get volume => 1.0;
  @override
  Future<void> setVolume(double v) async {}
  @override
  Stream<EngineEvent> get events => const Stream.empty();
  @override
  Float32List? get fft => null;
  @override
  Float32List? get wave => null;
  @override
  void dispose() {}
}

/* ---------------- ID3v2.3 构造 ---------------- */

List<int> _encSyncsafe(int n) =>
    [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

List<int> _encBe32(int n) =>
    [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];

List<int> _utf16le(String s) {
  final out = <int>[0xFF, 0xFE];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

List<int> _frame(String id, List<int> body) =>
    [...ascii.encode(id), ..._encBe32(body.length), 0, 0, ...body];

/// 8×8 的洋红 PNG（有效图片，取色能取到）
final Uint8List kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGO8o9HDgA0wYRUdtBIAPMcBoHRCwF4AAAAASUVORK5CYII=',
);

Uint8List _mp3({Uint8List? pic, String? lrc, String? desc}) {
  final body = <int>[];
  if (pic != null) {
    body.addAll(_frame('APIC', [
      0,
      ...ascii.encode('image/png'), 0,
      3, 0,
      ...pic,
    ]));
  }
  if (lrc != null) {
    body.addAll(_frame('USLT', [
      1,
      ...ascii.encode('eng'),
      if (desc != null) ...[..._utf16le(desc), 0, 0],
      ..._utf16le(lrc),
    ]));
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

  setUp(() => tmp = Directory.systemTemp.createTempSync('aurum_play_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String write(String name, Uint8List bytes) {
    final p = '${tmp.path}${Platform.pathSeparator}$name';
    File(p).writeAsBytesSync(bytes);
    return p;
  }

  /// 等待封面/歌词这类 fire-and-forget 的异步落地
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  test('本地歌：封面与内嵌 LRC 歌词都到位，索引指向点中的那首', () async {
    final a = write('a.mp3', _mp3(
      pic: kTinyPng,
      lrc: '[00:01.000]第一句\n[00:05.000]第二句',
      desc: 'Lyrics', // 真实文件常见写法
    ));
    final b = write('b.mp3', _mp3(pic: kTinyPng, lrc: '[00:02.000]b 的歌词'));

    final app = AppState(engine: _StubEngine(), autoStart: false);
    addTearDown(app.dispose);

    app.localTracks = [
      Track(id: a, name: 'A', artist: 'x', album: '', source: 'file'),
      Track(id: b, name: 'B', artist: 'y', album: '', source: 'file'),
    ];
    app.setTab(LibraryTab.local);

    await app.playAt(1); // 点第二首
    await settle();

    expect(app.current?.id, b, reason: '点的哪首就该是哪首');
    expect(app.index, 1);
    expect(app.coverUrl, isNotNull, reason: '内嵌封面必须被提取');
    expect(app.coverUrl!, startsWith('file:'));
    expect(app.lyrics, isNotEmpty, reason: '内嵌 USLT 歌词必须被提取');
    expect(app.lyrics.first.text, contains('b 的歌词'));

    // 主题色跟着封面走（8×8 洋红）
    expect(app.c1.r * 255, greaterThan(150), reason: '主色应偏洋红');
  });

  test('切到没有封面的歌：旧封面与主题色必须清空（不再错位）', () async {
    final withCover = write('c.mp3', _mp3(pic: kTinyPng, lrc: '[00:01.000]c'));
    final noCover = write('d.mp3', _mp3());

    final app = AppState(engine: _StubEngine(), autoStart: false);
    addTearDown(app.dispose);

    app.localTracks = [
      Track(id: withCover, name: 'C', artist: 'x', album: '', source: 'file'),
      Track(id: noCover, name: 'D', artist: 'y', album: '', source: 'file'),
    ];
    app.setTab(LibraryTab.local);

    await app.playAt(0);
    await settle();
    expect(app.coverUrl, isNotNull);
    final colorAfterCover = app.c1;

    await app.playAt(1); // 这首没有任何封面
    await settle();

    expect(app.current?.id, noCover);
    expect(app.coverUrl, isNull, reason: '无封面时不能留着上一首的图');
    expect(app.bgUrl, isNull, reason: '背景大图同样要清掉');
    expect(app.c1, isNot(colorAfterCover), reason: '主题色要回默认，不能延续上一首');
  });

  test('切视图后 index 按当前播放曲目重新定位', () async {
    final a = write('e.mp3', _mp3(pic: kTinyPng, lrc: '[00:01.000]e'));

    final app = AppState(engine: _StubEngine(), autoStart: false);
    addTearDown(app.dispose);

    app.localTracks = [Track(id: a, name: 'E', artist: 'x', album: '', source: 'file')];
    app.setTab(LibraryTab.local);
    await app.playAt(0);
    await settle();

    app.setTab(LibraryTab.online); // 列表换成搜索结果（空）
    expect(app.index, -1, reason: '在线列表里没有这首 → index 归 -1');

    app.setTab(LibraryTab.local);
    expect(app.index, 0, reason: '切回来应重新定位到 0，而不是沿用旧值');
  });
}
