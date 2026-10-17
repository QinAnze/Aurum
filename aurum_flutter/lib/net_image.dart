/// Aurum · 图片加载（网络带 CDN 故障转移 + 本地文件直读）。
///
/// 关键坑（实测，2026-10）：
/// netease 图片 CDN 的边缘节点对**非浏览器客户端（dart:io / BoringSSL）**直接返回
/// `403 Forbidden nginx`——p1/p2.music.126.net 全被挡，而 p3.music.126.net 放行；
/// UA 头、加不加浏览器 UA、是否走代理都**不影响**这个判定（curl/python 能过、
/// dart 不能），所以不能靠「加 UA」解决。
/// 音频 CDN（m801 等）没有这个限制，播放不受影响。
///
/// 网络方案：自建 ImageProvider，把同一张图的多个 host 候选按序尝试
///（p3 优先 → 原 host），谁先成功用谁；仍失败才走 errorBuilder 占位图。
/// 本地方案：`file://` / 裸绝对路径直接读字节，无需 HTTP。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'audio/audio_cover.dart';

/// 浏览器 UA（部分 CDN / 接口对非浏览器 UA 直接拒绝）
const String kBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 图片请求头
const Map<String, String> kImageHeaders = {'User-Agent': kBrowserUa};

/// 备选图片 CDN 主机（按顺序尝试）
const List<String> kFallbackImageHosts = [
  'p3.music.126.net',
  'p1.music.126.net',
  'p2.music.126.net',
];

/// 展开候选 URL：原 host 若在已知被挡名单里，p3 优先；其余情况原 URL 优先。
List<String> imageUrlCandidates(String url) {
  // 本地文件没有候选概念，直接返回
  if (localPathOf(url) != null) return [url];

  final out = <String>[];
  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return [url];
  }
  final host = uri.host;
  final isMusic126 = host.endsWith('music.126.net');
  final blocked = host.startsWith('p1.') || host.startsWith('p2.');
  if (isMusic126 && blocked) {
    // 已知的被挡节点：直接把可用的排前面，省掉一次 403 往返
    for (final h in kFallbackImageHosts) {
      if (h != host) out.add(uri.replace(host: h).toString());
    }
    out.add(url);
  } else {
    out.add(url);
    if (isMusic126) {
      for (final h in kFallbackImageHosts) {
        if (h != host) out.add(uri.replace(host: h).toString());
      }
    }
  }
  return out;
}

/// 带头 UA、且能在 CDN 故障时自动换 host 的图片加载器
class AurumNetworkImage extends ImageProvider<AurumNetworkImage> {
  const AurumNetworkImage(this.url, {this.headers = kImageHeaders});

  final String url;
  final Map<String, String> headers;

  @override
  Future<AurumNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AurumNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AurumNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    // 本地文件：直接读字节解码（file:///C:/x/y.mp3 或 C:\x\y.mp3）
    final localPath = localPathOf(key.url);
    if (localPath != null) {
      return MultiFrameImageStreamCompleter(
        codec: _loadLocal(localPath, decode),
        scale: 1,
        debugLabel: key.url,
        informationCollector: () => [
          DiagnosticsProperty<ImageProvider>('Image provider', this),
        ],
      );
    }
    return MultiFrameImageStreamCompleter(
      codec: _loadRemote(key, decode),
      scale: 1,
      debugLabel: key.url,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
      ],
    );
  }

  Future<ui.Codec> _loadLocal(String path, ImageDecoderCallback decode) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) throw StateError('empty file: $path');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<ui.Codec> _loadRemote(
    AurumNetworkImage key,
    ImageDecoderCallback decode,
  ) async {
    final candidates = imageUrlCandidates(key.url);
    Object? lastError;
    final client = HttpClient();
    try {
      for (final candidate in candidates) {
        try {
          final req = await client.getUrl(Uri.parse(candidate));
          key.headers.forEach(req.headers.add);
          final resp = await req.close();
          if (resp.statusCode != HttpStatus.ok) {
            await resp.drain<void>();
            throw HttpException('HTTP ${resp.statusCode} @ $candidate');
          }
          final bytes = await consolidateHttpClientResponseBytes(resp);
          if (bytes.lengthInBytes == 0) {
            throw HttpException('empty body @ $candidate');
          }
          return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
        } catch (e) {
          lastError = e; // 试下一个候选 host
        }
      }
    } finally {
      client.close();
    }
    throw lastError ?? StateError('image load failed: ${key.url}');
  }

  @override
  bool operator ==(Object other) =>
      other is AurumNetworkImage &&
      other.url == url &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode =>
      Object.hash(url, Object.hashAllUnordered(headers.values));

  @override
  String toString() => 'AurumNetworkImage("$url")';
}

/// 便捷构造
ImageProvider aurumImage(String url) => AurumNetworkImage(url);

/// 若是本地文件地址，返回可直接打开的路径；否则 null。
///
/// 覆盖 `file:///C:/x/y.mp3`、`file://`、Windows 裸盘符路径 `C:\x\y.mp3`、
/// UNC `\\server\share\a.mp3` 与 POSIX 绝对路径。
String? localPathOf(String url) {
  if (url.isEmpty) return null;
  if (url.startsWith('file:')) {
    try {
      return Uri.parse(url).toFilePath();
    } catch (_) {
      return null;
    }
  }
  if (RegExp(r'^[a-zA-Z]:[\\/]').matchAsPrefix(url) != null) return url;
  // 反斜杠 UNC：\\server\share\a.mp3，不存在同形的 URL，直接认作路径
  if (url.startsWith(r'\\')) return url;
  // 正斜杠 UNC 与「协议相对 URL」同形（//host/path）。
  // 真主机名（NetBIOS 名）通常不带点，域名一定带点 —— 用这一点区分，
  // 否则 //cdn.example.com/a.jpg 会被拿去 File 读取，封面静默失败。
  if (url.startsWith('//')) {
    final host = url.substring(2).split(RegExp(r'[\\/]')).first;
    return host.contains('.') ? null : url;
  }
  if (url.startsWith('/')) return url; // POSIX 绝对路径
  return null;
}

/// 本地音频文件 → 可显示的封面 provider。
///
/// 优先读文件内嵌封面（ID3v2 APIC / FLAC PICTURE）；没有则返回 null，
/// 由调用方显示占位图 + 默认主题色。
ImageProvider? localCoverImage(String path) {
  final bytes = embeddedCover(path);
  if (bytes == null || bytes.isEmpty) return null;
  return MemoryImage(bytes);
}
