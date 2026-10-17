/// Aurum · 音频时长探测器。
/// flutter_soloud 不暴露音源时长，而进度条/seek 需要 duration。
/// 这里在把字节喂给引擎前，直接从文件头解析时长：
///  - MP3：ID3v2 跳过 → Xing/Info(VBR) 帧数 → 否则 CBR 按 文件大小×8/码率
///  - FLAC：STREAMINFO totalSamples / sampleRate
///  - WAV ：data chunk / byteRate
/// 解析失败返回 null（时长未知，UI 按 0 处理，行为同 Web 版 NaN）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 尝试探测音频时长（秒）；失败返回 null。
double? probeAudioDuration(Uint8List b) {
  try {
    if (b.length >= 12) {
      final riff = String.fromCharCodes(b.sublist(0, 4));
      final wave = String.fromCharCodes(b.sublist(8, 12));
      if (riff == 'RIFF' && wave == 'WAVE') return _wavDuration(b);
    }
    if (b.length >= 8 && String.fromCharCodes(b.sublist(0, 4)) == 'fLaC') {
      return _flacDuration(b);
    }
    return _mp3Duration(b);
  } catch (_) {
    return null;
  }
}

/* ---------------- WAV ---------------- */
double? _wavDuration(Uint8List b) {
  double? byteRate;
  int dataSize = -1;
  int dataStart = -1;
  var pos = 12;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final size = _le32(b, pos + 4);
    if (id == 'fmt ') {
      // audioFormat(2) channels(2) sampleRate(4) byteRate(4) …
      byteRate = _le32(b, pos + 8 + 8).toDouble();
    } else if (id == 'data') {
      dataSize = size;
      dataStart = pos + 8;
    }
    pos += 8 + size + (size & 1); // chunk 按 2 字节对齐
    if (byteRate != null && dataStart >= 0) break;
  }
  if (byteRate == null || byteRate <= 0 || dataSize < 0) return null;
  // 声明的 data 大小可能超过实际字节（流式/截断文件），取小者
  final usable = math.min(dataSize, b.length - dataStart);
  return usable / byteRate;
}

/* ---------------- FLAC ---------------- */
double? _flacDuration(Uint8List b) {
  if (b.length < 4 + 4 + 34) return null;
  // 第一个 metadata block：1 字节 type + 3 字节长度（STREAMINFO 固定 34 字节）
  final blockLen = (b[5] << 16) | (b[6] << 8) | b[7];
  if (blockLen < 34) return null;
  final s = 8; // STREAMINFO 数据起点
  final sampleRate = (b[s + 10] << 12) | (b[s + 11] << 4) | (b[s + 12] >> 4);
  final totalSamples = ((b[s + 13] & 0x0F) << 32) |
      (b[s + 14] << 24) |
      (b[s + 15] << 16) |
      (b[s + 16] << 8) |
      b[s + 17];
  if (sampleRate <= 0 || totalSamples == 0) return null;
  return totalSamples / sampleRate;
}

/* ---------------- MP3 ---------------- */

// 码率表（kbps），index 1..14；0=free，15=bad
const List<List<int>> _kBitratesV1L1 = [
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // MPEG1 L1
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // MPEG1 L2
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // MPEG1 L3
];
const List<List<int>> _kBitratesV2 = [
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // MPEG2/2.5 L1
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // MPEG2/2.5 L2/L3
];
const List<List<int>> _kSampleRates = [
  [44100, 48000, 32000], // MPEG1
  [22050, 24000, 16000], // MPEG2
  [11025, 12000, 8000], // MPEG2.5
];

double? _mp3Duration(Uint8List b) {
  var pos = 0;
  // 跳过 ID3v2
  if (b.length >= 10 &&
      b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    final size = ((b[6] & 0x7F) << 21) |
        ((b[7] & 0x7F) << 14) |
        ((b[8] & 0x7F) << 7) |
        (b[9] & 0x7F);
    pos = 10 + size;
  }

  // 找第一帧同步
  while (pos + 4 < b.length) {
    if (b[pos] == 0xFF && (b[pos + 1] & 0xE0) == 0xE0) {
      final h = _parseHeader(b, pos);
      if (h != null) {
        // VBR：Xing/Info 头里的总帧数最准
        final vbr = _xingFrames(b, pos, h);
        if (vbr != null && vbr > 0) {
          return vbr * h.samplesPerFrame / h.sampleRate;
        }
        // CBR：文件剩余大小 × 8 / 码率
        if (h.bitrateBps > 0) {
          final payload = b.length - pos;
          return payload * 8 / h.bitrateBps;
        }
        return null;
      }
    }
    pos++;
  }
  return null;
}

class _Mp3Header {
  const _Mp3Header(this.bitrateBps, this.sampleRate, this.samplesPerFrame);
  final int bitrateBps;
  final int sampleRate;
  final int samplesPerFrame;
}

_Mp3Header? _parseHeader(Uint8List b, int p) {
  final b1 = b[p + 1];
  final versionBits = (b1 >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
  final layerBits = (b1 >> 1) & 0x03; // 1=L3, 2=L2, 3=L1
  if (versionBits == 1 || layerBits == 0) return null;
  final b2 = b[p + 2];
  final brIdx = (b2 >> 4) & 0x0F;
  final srIdx = (b2 >> 2) & 0x03;
  if (brIdx == 0 || brIdx == 15 || srIdx == 3) return null;

  final isV1 = versionBits == 3;
  final layer = layerBits == 3
      ? 1
      : layerBits == 2
          ? 2
          : 3;
  final kbps = isV1
      ? _kBitratesV1L1[layer - 1][brIdx]
      : _kBitratesV2[layer == 1 ? 0 : 1][brIdx];
  final sampleRate =
      _kSampleRates[isV1 ? 0 : (versionBits == 2 ? 1 : 2)][srIdx];
  final samplesPerFrame = isV1
      ? (layer == 1 ? 384 : 1152)
      : (layer == 1 ? 384 : 576);
  return _Mp3Header(kbps * 1000, sampleRate, samplesPerFrame);
}

/// 解析 Xing/Info 头中的总帧数（VBR）
int? _xingFrames(Uint8List b, int frameStart, _Mp3Header h) {
  // side info 区大小由声道模式决定：MPEG1 单声道 17 / 立体声 32；
  // MPEG2/2.5 单声道 9 / 立体声 17。声道模式在帧头 byte3 高 2 位（3=mono）。
  final b1 = b[frameStart + 1];
  final isV1 = ((b1 >> 3) & 0x03) == 3;
  final mono = ((b[frameStart + 3] >> 6) & 0x03) == 3;
  final sideInfo = isV1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
  final p = frameStart + 4 + sideInfo;
  if (p + 8 > b.length) return null;
  final tag = String.fromCharCodes(b.sublist(p, p + 4));
  if (tag != 'Xing' && tag != 'Info') return null;
  final flags = _be32(b, p + 4);
  if ((flags & 0x01) != 0 && p + 12 <= b.length) {
    final frames = _be32(b, p + 8);
    if (frames > 0) return frames;
  }
  return null;
}

int _le32(Uint8List b, int p) =>
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);

int _be32(Uint8List b, int p) =>
    (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
