/// Aurum · 侧栏（对应原版 .sidebar）：品牌 + 搜索 + 播放列表。
/// 列表行 30ms stagger 入场；正在播放行显示迷你均衡器。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/music_api.dart';
import '../local/local_library.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../net_image.dart';
import '../theme/tokens.dart';
import 'glass.dart';
import 'svg_icon.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, required this.app, this.onTrackTap});

  final AppState app;
  /// 移动端点歌后收起抽屉
  final VoidCallback? onTrackTap;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _hasText = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _hasText = v.trim().isNotEmpty);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      widget.app.search(v);
    });
  }

  void _submit(String v) {
    _debounce?.cancel();
    widget.app.search(v);
  }

  void _clear() {
    _debounce?.cancel();
    _searchCtrl.clear();
    setState(() => _hasText = false);
    widget.app.clearSearch();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return GlassPanel(
      heavy: true,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Brand(),
          const SizedBox(height: 8),
          _SearchBox(
            controller: _searchCtrl,
            searching: app.searching,
            hasText: _hasText,
            onChanged: _onChanged,
            onSubmit: _submit,
            onClear: _clear,
          ),
          const SizedBox(height: 8),
          _LibraryTabs(
            tab: app.tab,
            localCount: app.localTracks.length,
            onlineCount: app.tracks.length,
            onChanged: (t) => widget.app.setTab(t),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: '▸ ',
                        style: fontStyle(
                            size: 11.5,
                            weight: FontWeight.w600,
                            color: app.c1),
                      ),
                      TextSpan(
                        text: app.listLabel,
                        style: fontStyle(
                            size: 11.5,
                            weight: FontWeight.w600,
                            color: kTextFaint),
                      ),
                    ]),
                  ),
                ),
                _FolderButton(
                  busy: app.scanning,
                  onTap: () async {
                    await widget.app.importFolder();
                  },
                ),
                if (app.localTracks.isNotEmpty)
                  _ClearLocalButton(
                    onTap: () => widget.app.clearLocal(),
                  ),
              ],
            ),
          ),
          Expanded(
            child: app.tracks.isEmpty
                ? _ListEmpty(local: app.tab == LibraryTab.local)
                : ListView.builder(
                    padding: const EdgeInsets.only(right: 2),
                    itemCount: app.tracks.length,
                    itemBuilder: (context, i) {
                      final t = app.tracks[i];
                      final cur = app.current;
                      return _TrackRow(
                        key: ValueKey('${t.source}-${t.id}-$i'),
                        track: t,
                        index: i,
                        // 按「歌源 + id」比对而不是比 index：切视图后 index
                        // 指向的是另一份列表，用 index 会高亮错误的行。
                        isCurrent: cur != null &&
                            cur.id == t.id &&
                            cur.source == t.source,
                        isPlaying: app.playing,
                        onTap: () {
                          app.playAt(i);
                          widget.onTrackTap?.call();
                        },
                        c1: app.c1,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- 品牌 ---------------- */
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
      child: Row(
        children: [
          // 金色倒三角 logo + 同色光晕
          SizedBox(
            width: 24,
            height: 24,
            child: CustomPaint(
              painter: _LogoTrianglePainter(),
            ),
          ),
          const SizedBox(width: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'Aurum',
                style: fontStyle(
                  size: 18.4,
                  weight: FontWeight.w700,
                  color: kBrandTitle,
                ),
              ),
              const _BlinkCursor(),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogoTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(3, 5)
      ..lineTo(21, 5)
      ..lineTo(12, 20)
      ..close();
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s, s);
    canvas.drawShadow(path, kBrandGold.withValues(alpha: 0.55), 7, false);
    canvas.drawPath(
      path,
      Paint()..color = kBrandGold,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoTrianglePainter old) => false;
}

class _BlinkCursor extends StatefulWidget {
  const _BlinkCursor();

  @override
  State<_BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<_BlinkCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // steps(1) 风格：前 550ms 可见，后 550ms 隐藏
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Opacity(
        opacity: _c.value < 0.5 ? 1 : 0,
        child: Text(
          '_',
          style: fontStyle(size: 18.4, weight: FontWeight.w700, color: kBrandGold),
        ),
      ),
    );
  }
}

/* ---------------- 搜索框 ---------------- */
class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.searching,
    required this.hasText,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool searching;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x24FFFFFF)),
        color: const Color(0x12FFFFFF),
      ),
      child: Row(
        children: [
          const SizedBox(width: 13),
          const AurumIcon(AIcon.search,
              size: 15, color: kTextFaint, strokeWidth: 2.2),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmit,
              style: fontStyle(size: 13.8, color: kText),
              cursorColor: kText,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜歌名 / 歌手喵…',
                hintStyle: fontStyle(size: 13.8, color: kTextFaint),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          // 转圈 / 清除 ×（同位置互斥）
          if (searching)
            const Padding(
              padding: EdgeInsets.only(right: 11),
              child: _Spinner(),
            )
          else if (hasText)
            _ClearButton(onTap: onClear),
          const SizedBox(width: 11),
        ],
      ),
    );
  }
}

class _Spinner extends StatefulWidget {
  const _Spinner();

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          painter: _SpinnerPainter(_c.value),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width / 2 - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x33FFFFFF),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xCCFFFFFF);
    canvas.drawArc(rect.deflate(1), t * 6.2831853 - 1.5707963, 1.2, false, paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.t != t;
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SizedBox(
        width: 16,
        height: 16,
        child: AurumIcon(AIcon.clear,
            size: 16, color: Color(0xD9FFFFFF), strokeWidth: 2.4),
      ),
    );
  }
}

/* ---------------- 库视图切换（在线 / 本地） ---------------- */
class _LibraryTabs extends StatelessWidget {
  const _LibraryTabs({
    required this.tab,
    required this.localCount,
    required this.onlineCount,
    required this.onChanged,
  });

  final LibraryTab tab;
  final int localCount;
  final int onlineCount;
  final ValueChanged<LibraryTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _chip('在线', LibraryTab.online, tab == LibraryTab.online, onlineCount),
          const SizedBox(width: 6),
          _chip('本地', LibraryTab.local, tab == LibraryTab.local, localCount),
        ],
      ),
    );
  }

  Widget _chip(String label, LibraryTab value, bool active, int count) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: kEaseOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          color: active ? const Color(0x2EFFFFFF) : Colors.transparent,
          border: Border.all(
            color: active ? const Color(0x3DFFFFFF) : const Color(0x18FFFFFF),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: fontStyle(
                size: 11.5,
                weight: FontWeight.w600,
                color: active ? kText : kTextFaint,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: fontStyle(
                  size: 10.5,
                  weight: FontWeight.w700,
                  color: active ? kTextDim : kTextFaint,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/* ---------------- 本地库入口按钮 ---------------- */

/// 选择本地文件夹
class _FolderButton extends StatelessWidget {
  const _FolderButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '选择本地音乐文件夹',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: const Color(0x18FFFFFF),
          ),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(5),
                  child: _Spinner(),
                )
              : const Center(
                  child: AurumIcon(AIcon.folder,
                      size: 14, color: kTextDim, strokeWidth: 2.2),
                ),
        ),
      ),
    );
  }
}

/// 清空本地列表
class _ClearLocalButton extends StatelessWidget {
  const _ClearLocalButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '清空本地列表',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const SizedBox(
          width: 22,
          height: 22,
          child: Center(
            child: AurumIcon(AIcon.clear,
                size: 13, color: kTextFaint, strokeWidth: 2.4),
          ),
        ),
      ),
    );
  }
}

/* ---------------- 列表 ---------------- */
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({this.local = false});

  /// 本地视图的空态文案不同（引导去选文件夹，而不是去搜索）
  final bool local;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 34),
        child: Text(
          local
              ? '还没有本地音乐喵。\n点右边的小文件夹，\n挑一个装歌的目录给我～'
              : '喵？想听什么就自己搜啦，\n人家又不会读心…',
          textAlign: TextAlign.center,
          style: fontStyle(size: 13, color: kTextFaint, height: 1.8),
        ),
      ),
    );
  }
}

class _TrackRow extends StatefulWidget {
  const _TrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    required this.c1,
  });

  final Track track;
  final int index;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  /// 主题主色（均衡器渐变用，随封面取色变化）
  final Color c1;

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  @override
  void initState() {
    super.initState();
    // 30ms stagger 入场（上限 420ms）
    final delay = (widget.index * kRowStaggerMs).clamp(0, kRowStaggerMaxMs);
    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted) _in.forward();
    });
    _loadPic();
  }

  Future<void> _loadPic() async {
    final t = widget.track;
    if (t.picUrl.isNotEmpty) return;

    // 本地歌：封面从文件里取（内嵌图 / 同目录 cover.jpg）
    if (t.source == 'file') {
      final url = await localCoverUrl(t.id);
      if (url != null && mounted) {
        t.picUrl = url;
        setState(() {});
      }
      return;
    }

    if (t.picId.isEmpty) return;
    final url = await fetchPicUrl(t, size: 300);
    if (url != null && mounted) {
      t.picUrl = url; // 缓存回列表项
      setState(() {});
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return AnimatedBuilder(
      animation: _in,
      builder: (context, child) {
        final e = kEaseOut.transform(_in.value);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(-8 * (1 - e), 0),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            color: widget.isCurrent
                ? const Color(0x1CFFFFFF)
                : Colors.transparent,
            border: Border.all(
              color: widget.isCurrent
                  ? const Color(0x2EFFFFFF)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: t.picUrl.isNotEmpty
                      ? Image(
                          image: aurumImage(t.picUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const ColoredBox(color: Color(0x14FFFFFF)),
                        )
                      : const ColoredBox(color: Color(0x14FFFFFF)),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: fontStyle(
                        size: 13.6,
                        weight: FontWeight.w600,
                        color: widget.isCurrent ? kText : kText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: fontStyle(size: 11.5, color: kTextDim),
                    ),
                  ],
                ),
              ),
              if (widget.isCurrent)
                _EqBars(playing: widget.isPlaying, c1: widget.c1),
            ],
          ),
        ),
      ),
    );
  }
}

class _EqBars extends StatefulWidget {
  const _EqBars({required this.playing, required this.c1});

  final bool playing;
  final Color c1;

  @override
  State<_EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<_EqBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(_EqBars old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_c.isAnimating) _c.repeat();
    if (!widget.playing && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(0.0),
              _bar(0.33),
              _bar(0.61),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double phase) {
    final t = (_c.value + phase) % 1.0;
    // 22% ↔ 100% 往复（alternate）
    final tri = t < 0.5 ? t * 2 : (1 - t) * 2;
    final h = 0.22 + tri * 0.78;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: FractionallySizedBox(
          heightFactor: h,
          alignment: Alignment.bottomCenter,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [widget.c1, const Color(0xFFFFFFFF)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
