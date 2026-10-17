// 本地路径识别回归测试。
//
// 这段判断决定「读文件」还是「发 HTTP」：一旦把网络 URL 误判成本地路径，
// 播放会去 File 读取失败；反过来把本地路径误判成网络地址，就会拿
// `C:\Music\a.mp3` 去构造 URI 然后报错。两种都是静默失败，必须钉死。

import 'package:aurum/net_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localPathOf', () {
    test('file:/// 形式的 Windows 路径', () {
      expect(
        localPathOf('file:///C:/Music/a.mp3'),
        anyOf('C:/Music/a.mp3', r'C:\Music\a.mp3', '/C:/Music/a.mp3'),
      );
    });

    test('file:/// 形式的本地路径（分隔符随平台）', () {
      final p = localPathOf('file:///home/me/a.mp3');
      expect(p, isNotNull);
      expect(p!.endsWith('a.mp3'), isTrue);
    });

    test('裸盘符路径', () {
      expect(localPathOf(r'D:\Music\周杰伦\a.mp3'), r'D:\Music\周杰伦\a.mp3');
      expect(localPathOf('D:/Music/a.flac'), 'D:/Music/a.flac');
    });

    test('UNC 路径', () {
      expect(localPathOf(r'\\nas\share\a.mp3'), r'\\nas\share\a.mp3');
      // 正斜杠 UNC：主机名不带点 → 仍是路径
      expect(localPathOf('//nas/share/a.mp3'), '//nas/share/a.mp3');
    });

    test('协议相对 URL 不当成本地路径', () {
      // //cdn.example.com/a.jpg 与 UNC 同形，但主机名带点 → 是 URL
      expect(localPathOf('//cdn.example.com/a.jpg'), isNull);
    });

    test('网络地址一律不是本地路径', () {
      for (final url in [
        'https://p3.music.126.net/a.jpg',
        'http://127.0.0.1:4530/song/url/v1?id=1',
        '//cdn.example.com/a.jpg',
        '',
      ]) {
        expect(localPathOf(url), isNull, reason: url);
      }
    });
  });

  group('imageUrlCandidates 与本地文件', () {
    test('本地文件不给候选（没有 host 可换）', () {
      const p = r'D:\Music\cover.jpg';
      expect(imageUrlCandidates(p), [p]);
    });

    test('被挡的 p1/p2 把 p3 排到最前', () {
      final list =
          imageUrlCandidates('https://p2.music.126.net/x/y.jpg?param=500y500');
      expect(list.first, contains('p3.music.126.net'));
      // 原 URL 仍保留为最后兜底，且查询参数不能丢
      expect(list.last, contains('p2.music.126.net'));
      expect(list.first, contains('param=500y500'));
    });

    test('非 netease 域名不生成候选', () {
      const url = 'https://example.com/a.jpg';
      expect(imageUrlCandidates(url), [url]);
    });
  });
}
