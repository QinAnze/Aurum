/// Aurum · 加载代次门闩（防「切歌并发交叉」导致两首歌叠播）。
///
/// 背景：A 的音频还在下载时用户切到 B，B 的清场已经跑完；
/// 随后 A 的下载完成并 `play()` —— 结果两首同时响。
/// 规则：**只有最新一次请求（代号）允许把音源落到引擎里**，
/// 落后的请求必须在每个 await 之后自检并销毁自己刚建的东西。
library;

/// 极小的代次门闩（无音频依赖，可直接单测）
class LoadGate {
  int _gen = 0;
  bool _loading = false;

  /// 最新代号
  int get generation => _gen;

  /// 是否还有一轮加载在途
  bool get busy => _loading;

  /// 开启一次新的加载，返回它的代号
  int begin() => ++_gen;

  /// 该代号是否仍是最新
  bool isCurrent(int gen) => gen == _gen;

  /// 串行化：等上一轮收尾。返回 false 表示「等的过程中已被更新的请求抢占」
  Future<bool> acquire(int gen) async {
    while (_loading) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!isCurrent(gen)) return false;
    }
    _loading = true;
    return true;
  }

  /// 释放占用（务必在 finally 里调用）
  void release() => _loading = false;
}