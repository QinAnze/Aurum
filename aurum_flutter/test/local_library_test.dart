// 本地音乐库回归测试：文件名元数据解析 + 目录扫描筛选。

import 'dart:io';

import 'package:aurum/local/local_library.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _tmp() => Directory.systemTemp.createTempSync('aurum_test_');

void main() {
  group('parseFileName', () {
    test('歌手 - 歌名', () {
      final r = parseFileName('周杰伦 - 晴天');
      expect(r.artist, '周杰伦');
      expect(r.name, '晴天');
    });

    test('带轨道序号 → 去掉序号', () {
      final r = parseFileName('03. 周杰伦 - 稻香');
      expect(r.artist, '周杰伦');
      expect(r.name, '稻香');
    });

    test('下划线分隔', () {
      final r = parseFileName('Artist _ Title');
      expect(r.artist, 'Artist');
      expect(r.name, 'Title');
    });

    test('纯歌名无分隔符 → 歌名即全文', () {
      final r = parseFileName('夜曲');
      expect(r.name, '夜曲');
      expect(r.artist, '本地音乐');
    });

    test('歌名里的连字符不被误切（无空格包围）', () {
      final r = parseFileName('X-O-Dus');
      expect(r.name, 'X-O-Dus');
      expect(r.artist, '本地音乐');
    });

    test('尾部杂注被剥离', () {
      final r = parseFileName('周杰伦 - 晴天 [HQ]');
      expect(r.name, '晴天');
      expect(r.artist, '周杰伦');
    });

    test('空输入不崩', () {
      final r = parseFileName('   ');
      expect(r.name, isNotNull);
    });
  });

  group('scanFolder', () {
    test('只收音频文件，按目录聚拢', () async {
      final root = _tmp();
      try {
        File('${root.path}${Platform.pathSeparator}a.mp3')
            .writeAsStringSync('x');
        File('${root.path}${Platform.pathSeparator}b.flac')
            .writeAsStringSync('x');
        File('${root.path}${Platform.pathSeparator}c.txt')
            .writeAsStringSync('x');
        File('${root.path}${Platform.pathSeparator}cover.jpg')
            .writeAsStringSync('x');

        final tracks = await scanFolder(root.path);
        expect(tracks.length, 2);
        expect(tracks.map((t) => t.name).toList(), ['a', 'b']);
        expect(tracks.every((t) => t.source == 'file'), isTrue);
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('递归子目录', () async {
      final root = _tmp();
      try {
        final sub = Directory(
            '${root.path}${Platform.pathSeparator}sub${Platform.pathSeparator}deep');
        sub.createSync(recursive: true);
        File('${sub.path}${Platform.pathSeparator}nested.wav')
            .writeAsStringSync('x');

        final tracks = await scanFolder(root.path);
        expect(tracks.length, 1);
        expect(tracks.first.name, 'nested');
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('跳过系统/缓存目录', () async {
      final root = _tmp();
      try {
        final nm = Directory(
            '${root.path}${Platform.pathSeparator}node_modules');
        nm.createSync(recursive: true);
        File('${nm.path}${Platform.pathSeparator}junk.mp3')
            .writeAsStringSync('x');
        File('${root.path}${Platform.pathSeparator}good.mp3')
            .writeAsStringSync('x');

        final tracks = await scanFolder(root.path);
        expect(tracks.length, 1);
        expect(tracks.first.name, 'good');
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('目录不存在 → 空列表', () async {
      final tracks = await scanFolder('${_tmp().path}${Platform.pathSeparator}nope');
      expect(tracks, isEmpty);
    });
  });
}
