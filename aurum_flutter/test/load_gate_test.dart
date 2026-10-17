// Aurum · 切歌并发门闩回归测试 —— 对应用户报的 bug「切歌后回原歌曲和切的歌一块放」。
//
// 真实成因：A 的音频还在下载时用户切到 B，B 的清场已经跑完；
// 随后 A 下载完成并 play() → 两首同时响。
// 这里用 LoadGate（无音频依赖）把「只有最新请求能落地」的不变量钉死。
import 'package:aurum/audio/load_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoadGate', () {
    test('begin() 递增代号，旧代号立刻失效', () {
      final gate = LoadGate();
      final g1 = gate.begin();
      expect(gate.isCurrent(g1), isTrue);
      final g2 = gate.begin();
      expect(gate.generation, g2);
      expect(gate.isCurrent(g1), isFalse, reason: '旧请求必须立刻作废');
      expect(gate.isCurrent(g2), isTrue);
    });

    test('acquire 串行化：第二个请求要等第一个 release', () async {
      final gate = LoadGate();
      final g1 = gate.begin();
      expect(await gate.acquire(g1), isTrue);
      expect(gate.busy, isTrue);

      final g2 = gate.begin();
      var g2Acquired = false;
      final f2 = gate.acquire(g2).then((ok) {
        g2Acquired = ok;
        return ok;
      });

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(g2Acquired, isFalse, reason: '在途时新请求不能直接拿到锁');
      expect(gate.busy, isTrue);

      gate.release();
      expect(await f2, isTrue, reason: '前一轮释放后新请求才能进');
      gate.release();
    });

    test('等待期间被更新的请求抢占 → acquire 返回 false', () async {
      final gate = LoadGate();
      final g1 = gate.begin();
      await gate.acquire(g1);

      final g2 = gate.begin();
      final waiting = gate.acquire(g2);
      // 第三个请求插进来
      gate.begin();
      gate.release();

      expect(await waiting, isFalse,
          reason: '等锁期间代号已变旧 → 必须放弃，不能清场/加载');
    });

    test('复现原始竞态：A 在途时切 B，A 必须被判定为过期', () async {
      final gate = LoadGate();
      // A 开始加载
      final genA = gate.begin();
      await gate.acquire(genA);

      // 用户切到 B
      final genB = gate.begin();
      // B 的清场此刻就跑完了（A 的音源还没建，清场无事可做）
      gate.release();
      expect(await gate.acquire(genB), isTrue);

      // A 的下载这时才结束 → 它自检，发现自己过期
      expect(gate.isCurrent(genA), isFalse,
          reason: 'A 若不检查代号就会把旧歌 play 出来，与 B 叠播');
      expect(gate.isCurrent(genB), isTrue);
      gate.release();
    });

    test('连续快速切换多次，只有最后一次是 current', () {
      final gate = LoadGate();
      final gens = [for (var i = 0; i < 5; i++) gate.begin()];
      expect(gate.isCurrent(gens.last), isTrue);
      for (final g in gens.take(4)) {
        expect(gate.isCurrent(g), isFalse);
      }
    });
  });
}