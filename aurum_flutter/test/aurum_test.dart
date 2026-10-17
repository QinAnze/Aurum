// Aurum · 纯逻辑单测（歌词/分词/时长探测/SVG 路径/格式化）。
// 不触网、不依赖 Flutter binding 之外的引擎状态。
import 'dart:typed_data';

import 'package:aurum/audio/audio_probe.dart';
import 'package:aurum/lyrics/lyrics_engine.dart';
import 'package:aurum/models.dart';
import 'package:aurum/widgets/svg_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fmtTime', () {
    test('秒 → m:ss', () {
      expect(fmtTime(0), '0:00');
      expect(fmtTime(9.9), '0:09');
      expect(fmtTime(75.4), '1:15');
      expect(fmtTime(-3), '0:00');
      expect(fmtTime(double.nan), '0:00');
    });
  });

  group('parseLRC', () {
    test('多标签行展开 + 排序', () {
      final lines = parseLRC('[01:02.50]第二句\n[00:01.00]第一句\n[00:01.00]同位');
      expect(lines.length, 3);
      expect(lines[0].t, 1.0);
      expect(lines[1].t, 1.0);
      expect(lines[2].t, 62.5);
      expect(lines.map((l) => l.text).toList(), contains('同位'));
    });

    test('空行/无文本行忽略', () {
      expect(parseLRC('[00:01.00]\n[00:02.00]   \n'), isEmpty);
    });
  });

  group('tokenizeWords', () {
    test('CJK 切 2~3 字块且全覆盖', () {
      final tokens = tokenizeWords('你好世界啊');
      expect(tokens, isNotEmpty);
      expect(tokens.join(), '你好世界啊');
      for (final t in tokens) {
        expect(t.length, inInclusiveRange(1, 3));
      }
    });

    test('拉丁按空白切', () {
      expect(tokenizeWords('hello world'), ['hello', 'world']);
    });

    test('纯标点被丢弃', () {
      expect(tokenizeWords('你好 ， 。'), ['你好']);
    });
  });

  group('normText / cleanLyricLine', () {
    test('normText 去符号转小写', () {
      expect(normText('Hello, 世界！'), 'hello世界');
    });

    test('cleanLyricLine 去翻译与括号', () {
      expect(cleanLyricLine('你好 (翻译：hello)', ''), '你好');
      expect(cleanLyricLine('走 / 译文内容', ''), '走');
    });

    test('制作信息行替换为歌名', () {
      expect(cleanLyricLine('作词：张三', '夜曲'), '夜曲');
    });
  });

  group('countSyllables', () {
    test('CJK 每字一音节', () {
      expect(countSyllables('你好'), 2);
    });

    test('拉丁按元音组', () {
      expect(countSyllables('hello'), 2);
      expect(countSyllables('a'), 1);
    });
  });

  group('prepareLyricLines', () {
    test('歌名行/作者行/纯音乐行进 skip', () {
      final lrc = '[00:01.00]夜曲\n'
          '[00:03.00]作词：方文山\n'
          '[00:05.00]纯音乐，请欣赏\n'
          '[00:07.00]一群嗜血的蚂蚁';
      final track = Track(
        id: '1',
        name: '夜曲',
        artist: '周杰伦',
        album: '十一月的萧邦',
        source: 'netease',
      );
      final lines = prepareLyricLines(lrc, track);
      expect(lines.length, 4);
      expect(lines[0].skip, isTrue); // == 歌名
      expect(lines[0].tokens, isEmpty);
      expect(lines[1].skip, isTrue); // 制作信息行 → 替换为歌名
      expect(lines[2].skip, isTrue); // 纯音乐
      expect(lines[3].skip, isFalse);
      expect(lines[3].tokens, isNotEmpty);
    });
  });

  group('probeAudioDuration', () {
    test('WAV：data/byteRate', () {
      final b = BytesBuilder();
      b.add('RIFF'.codeUnits);
      b.add(_le(36 + 8000));
      b.add('WAVE'.codeUnits);
      b.add('fmt '.codeUnits);
      b.add(_le(16));
      b.add([1, 0]); // PCM
      b.add([1, 0]); // mono
      b.add(_le(8000)); // sampleRate
      b.add(_le(8000)); // byteRate
      b.add([1, 0]); // blockAlign
      b.add([8, 0]); // bits
      b.add('data'.codeUnits);
      b.add(_le(16000)); // 2 秒 @8000B/s
      b.add(Uint8List(16000));
      expect(probeAudioDuration(b.takeBytes()), 2.0);
    });

    test('FLAC：totalSamples/sampleRate', () {
      final b = Uint8List(4 + 4 + 34);
      b.setRange(0, 4, 'fLaC'.codeUnits);
      b[4] = 0x00; // STREAMINFO
      b[5] = 0x00;
      b[6] = 0x00;
      b[7] = 34;
      const s = 8; // STREAMINFO 起点
      b[s + 10] = 0x0A;
      b[s + 11] = 0xC4;
      b[s + 12] = 0x42; // 44100Hz / 1ch / 16bit
      // totalSamples = 441000（10 秒）
      b[s + 13] = 0x00;
      b[s + 14] = 0x00;
      b[s + 15] = 0x06;
      b[s + 16] = 0xBA;
      b[s + 17] = 0xA8;
      expect(probeAudioDuration(b), 10.0);
    });

    test('MP3 CBR：大小×8/码率', () {
      final b = Uint8List(10 + 417 * 100);
      b[0] = 0x49;
      b[1] = 0x44;
      b[2] = 0x33; // ID3
      // 帧头：MPEG1 Layer3 128kbps 44100Hz
      b[10] = 0xFF;
      b[11] = 0xFB;
      b[12] = 0x90;
      b[13] = 0x00;
      final d = probeAudioDuration(b);
      expect(d, isNotNull);
      expect(d!, closeTo(41600 * 8 / 128000, 0.01));
    });

    test('无法识别返回 null', () {
      expect(probeAudioDuration(Uint8List(64)), isNull); // MP3 分支但无同步位
      expect(probeAudioDuration(Uint8List(4)), isNull); // 太短
    });
  });

  group('parseSvgPath', () {
    test('三角路径边界', () {
      final p = parseSvgPath('M3 5 L21 5 L12 20 Z');
      final bounds = p.getBounds();
      expect(bounds.left, 3);
      expect(bounds.top, 5);
      expect(bounds.right, 21);
      expect(bounds.bottom, 20);
    });

    test('相对命令 + 弧 + 隐式重复', () {
      // 两段 180° 弧拼整圆：左点(4,11) → 右点(18,11) → 回左点
      final p = parseSvgPath('m4 11 A7 7 0 1 1 18 11 a7 7 0 1 1 -14 0 Z');
      final bounds = p.getBounds();
      expect(bounds.left, closeTo(4, 0.5));
      expect(bounds.right, closeTo(18, 0.5));
      expect(bounds.top, closeTo(4, 0.5));
      expect(bounds.bottom, closeTo(18, 0.5));
    });
  });
}

List<int> _le(int v) => [
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ];
