/// Aurum · 主页：背景层 → 全屏词云 → 侧栏 + 播放器 → Toast。
/// 布局对应原版 .app：桌面端侧栏 340px + 播放器；窄屏（<880px）侧栏收为抽屉。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../effects/edge_light.dart';
import '../effects/imager_field.dart';
import '../effects/linear_spectrum.dart';
import '../effects/pitch_badge.dart';
import '../effects/pitch_scatter.dart';
import '../effects/viz_controller.dart';
import '../effects/word_cloud.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import '../widgets/bg_layers.dart';
import '../widgets/controls.dart';
import '../widgets/cover.dart';
import '../widgets/fx_checklist.dart';
import '../widgets/glass.dart';
import '../widgets/glow_text.dart';
import '../widgets/master_toggle.dart';
import '../widgets/progress_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/svg_icon.dart';
import '../widgets/toast.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});

  final AppState app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final WordCloudController _cloud;
  late final VizController _viz;
  late final FocusNode _rootFocus;
  int _lastLyricsRev = -1;
  bool _lastCloudOn = true;
  bool _lastPitchOn = true;
  bool _drawerOpen = false;
  int _volAnimToken = 0;

  @override
  void initState() {
    super.initState();
    _rootFocus = FocusNode(debugLabel: 'aurum-root');
    _cloud = WordCloudController();
    _viz = VizController(
      engine: widget.app.engine,
      isPlaying: () => widget.app.playing,
      volume: () => widget.app.volume,
      fxOn: () => widget.app.fxOn,
      fxCloud: () => widget.app.fxCloud,
      fxSpectrum: () => widget.app.fxSpectrum,
      fxKick: () => widget.app.fxKick,
      fxPitch: () => widget.app.fxPitch,
      fxImager: () => widget.app.fxImager,
      lyrics: () => widget.app.lyrics,
      cloudColorsFn: () => cloudColors(widget.app.palette ?? const []),
      coverPaletteFn: () => widget.app.palette ?? const [],
      cloud: _cloud,
    );
    widget.app.addListener(_onApp);
    _lastCloudOn = widget.app.fxItemOn('cloud');
    _lastPitchOn = widget.app.fxItemOn('pitch');
    _onApp();
  }

  void _onApp() {
    final a = widget.app;
    if (a.playing || a.fxItemOn('cloud') || a.fxItemOn('spectrum')) _viz.start();
    if (a.lyricsRev != _lastLyricsRev) {
      _lastLyricsRev = a.lyricsRev;
      _viz.resetCloud();
    }
    // 词云单独关掉时也要清场，不然旧词会冻在屏上
    final cloudNow = a.fxItemOn('cloud');
    if (cloudNow != _lastCloudOn) {
      _lastCloudOn = cloudNow;
      if (!cloudNow) _viz.resetCloud();
    }
    // 音高关掉时散落字同样要清空
    final pitchNow = a.fxItemOn('pitch');
    if (pitchNow != _lastPitchOn) {
      _lastPitchOn = pitchNow;
      if (!pitchNow) _viz.scatter.clear();
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    _viz.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  /* ---------------- 键盘快捷键（对应原版 document keydown） ---------------- */
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 焦点在子控件（按钮/输入框/旋钮）上时不拦截，由其自行处理
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused != _rootFocus) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      widget.app.togglePlay();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      widget.app.seekBy(5);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      widget.app.seekBy(-5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleMute() {
    _volAnimToken++;
    widget.app.toggleMute();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final mobile = MediaQuery.sizeOf(context).width < kMobileBreakpoint;

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _handleKey,
      // AppState 变化驱动整树重建（播放态/进度/列表/开关…）
      child: AnimatedBuilder(
        animation: widget.app,
        builder: (context, _) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                // 动态背景
                Positioned.fill(
                  child: BackgroundLayers(
                    coverUrl: app.bgUrl,
                    c1: app.c1,
                    c2: app.c2,
                    flip: app.bgFlip,
                  ),
                ),
                // 声像颗粒：整个界面最底层的特效（背景之上、其它一切之下）
                _imagerLayer(),
                // 音高散落（乐器段）：铺在**背景层之上**、UI 之下 ——
                // 用户要的是「铺在背景上」，不是浮在面板前面的顶层贴纸。
                if (app.fxItemOn('pitch')) _pitchScatter(),
                // 全屏词云（垫在 UI 之下、背景层之上）
                _wordCloudLayer(),
                // 应用主体
                Padding(
                  padding: appPadding(context),
                  child: mobile
                      ? _player()
                      : Row(
                          children: [
                            SizedBox(
                              width: kSidebarWidth,
                              child: Sidebar(app: app),
                            ),
                            const SizedBox(width: 20),
                            Expanded(child: _player()),
                          ],
                        ),
                ),
                // 移动端抽屉 + 遮罩
                if (mobile) ...[
                  _scrim(),
                  _drawer(),
                ],
                // kick 打光：整窗四周的光圈（在面板之上、抽屉/Toast 之下）
                if (app.fxItemOn('kick')) _edgeLight(),
                // 封面内下方的直线频谱（与环形同一份数据）
                if (app.fxItemOn('spectrum')) _linearSpectrum(),
                // 音高：人声段是封面中央的字母（顶层），乐器段散落已在背景层
                if (app.fxItemOn('pitch')) _pitchBadge(),
                // Toast
                Toast(message: app.toastMsg, visible: app.toastVisible),
              ],
            ),
          );
        },
      ),
    );
  }

  /* ---------------- 词云层 ---------------- */
  Widget _wordCloudLayer() {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, cons) {
          _viz.setCanvasSize(cons.biggest);
          return IgnorePointer(
            child: AnimatedBuilder(
              animation: _viz,
              builder: (_, __) {
                if (!widget.app.fxItemOn('cloud')) {
                  return const SizedBox.shrink();
                }
                return Transform.translate(
                  offset: Offset(_viz.cloudJx, _viz.cloudJy),
                  child: Transform.scale(
                    scale: _viz.cloudScale,
                    alignment: Alignment.center,
                    child: CustomPaint(
                      size: cons.biggest,
                      painter: WordCloudPainter(
                        controller: _cloud,
                        climax: _viz.climax,
                        overclock: true,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /* ---------------- kick 打光层 ---------------- */
  /// 底鼓响起时整窗四周亮一圈（只在特效开关打开时挂载）
  Widget _edgeLight() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _viz,
        builder: (_, __) => EdgeLight(
          level: _viz.kick.env,
          c1: widget.app.c1,
          c2: widget.app.c2,
        ),
      ),
    );
  }

  /* ---------------- 音高字母层 ---------------- */
  /// 乐器段：底部随机散落的音高字（无动画、无发光）
  Widget _pitchScatter() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _viz,
        // 不播放就淡出：平铺字的数据停在最后一帧，留着像画面卡死。
        // 透明度 0 时 Flutter 直接跳过子树绘制，不额外产生图层开销。
        builder: (_, __) => AnimatedOpacity(
          opacity: _viz.pitchLive ? 1 : 0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          child: PitchScatter(controller: _viz.scatter),
        ),
      ),
    );
  }

  /// 人声段：检测到的音（E5），顶层覆盖在封面中央
  Widget _pitchBadge() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _viz,
        builder: (_, __) => PitchBadge(
          note: _viz.pitchNote,
          revision: _viz.pitchRevision,
          rect: _viz.coverRect,
          c1: widget.app.c1,
          // 与歌曲标题同一套 climax 驱动：发光 + 放大
          glow: _viz.pitchGlow,
          blur: _viz.pitchBlur,
          scale: _viz.pitchScale,
        ),
      ),
    );
  }

  /// 声像颗粒层：最底层，只在背景没被面板盖住的地方露出来
  Widget _imagerLayer() {
    if (!widget.app.fxItemOn('imager')) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _viz,
        builder: (_, __) => ImagerField(controller: _viz.imagerField),
      ),
    );
  }

  /// 封面圆内的直线频谱：左低频右高频，宽度收在弦长以内
  Widget _linearSpectrum() {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _viz,
        builder: (_, __) {
          final r = _viz.coverRect;
          if (r == null || r.isEmpty) return const SizedBox.shrink();
          // 宽度 0.62 直径 → 半宽 0.31w；整条落在 0.60h~0.82h，
          // 端点距圆心 √(0.31² + 0.32²) w ≈ 0.45w = 0.89r < r，仍整条在圆内。
          // 画布给高一点，曲线才有足够的纵向行程（用户要「最大高度更高」）。
          return Stack(
            children: [
              Positioned(
                left: r.left + r.width * 0.19,
                top: r.top + r.height * 0.60,
                width: r.width * 0.62,
                height: r.height * 0.22,
                // 不播放时淡出：暂停后 specVals 会冻在最后一帧，
                // 留在封面上会像「卡住的线」
                child: AnimatedOpacity(
                  opacity: _viz.specLive ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOut,
                  child: CustomPaint(
                    painter: LinearSpectrumPainter(
                      vals: _viz.specVals,
                      climax: _viz.climax,
                      oc: true,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /* ---------------- 播放器 ---------------- */
  Widget _player() {
    final app = widget.app;
    final pad = playerPadding(context);
    final h = MediaQuery.sizeOf(context).height;
    final cover = coverSize(context);

    return GlassPanel(
      // 不裁剪：频谱环画布是封面的 1.6 倍，高潮辉光会溢出面板边界
      // （原版 CSS 面板无 overflow:hidden，环本就可以画到面板外）
      clip: false,
      child: Stack(
        children: [
          // 顶栏（脱离居中流、绝对定位贴顶）
          Positioned(
            top: pad.top,
            left: pad.left,
            right: pad.right,
            child: _topbar(),
          ),
          Padding(
            padding: pad,
            child: Column(
              children: [
                // 封面组：占满剩余高度并垂直居中
                Expanded(
                  child: Center(
                    child: CoverArt(
                      url: app.coverUrl,
                      spinning: app.playing,
                      viz: _viz,
                      c1: app.c1,
                      size: cover,
                    ),
                  ),
                ),
                // 进度 + 控件：贴底
                Column(
                  children: [
                    SizedBox(
                      width: zoneWidth(MediaQuery.sizeOf(context).width -
                          pad.left -
                          pad.right),
                      // 只订阅进度通道：位置每 200ms 变一次，
                      // 没必要为此重建整页（侧栏列表 + 封面 + 控件）。
                      child: ValueListenableBuilder<double>(
                        valueListenable: app.progress,
                        builder: (_, pos, __) => ProgressBar(
                          position: pos,
                          duration: app.duration,
                          dragging: app.dragging,
                          dragRatio: app.dragRatio,
                          onBeginDrag: app.beginDrag,
                          onUpdateDrag: app.updateDrag,
                          onEndDrag: app.endDrag,
                        ),
                      ),
                    ),
                    SizedBox(height: clampD(h * 0.02, 12, 22)),
                    Padding(
                      padding: EdgeInsets.only(top: clampD(h * 0.02, 10, 20)),
                      child: SizedBox(
                        width: zoneWidth(MediaQuery.sizeOf(context).width -
                            pad.left -
                            pad.right),
                        child: Controls(
                          mode: app.mode,
                          playing: app.playing,
                          volume: app.volume,
                          muted: app.muted,
                          volAnimToken: _volAnimToken,
                          onTogglePlay: app.togglePlay,
                          onNext: app.next,
                          onPrev: app.prev,
                          onCycleMode: app.cycleMode,
                          onToggleMute: _toggleMute,
                          onVolume: app.setVolume,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topbar() {
    final app = widget.app;
    final mobile = MediaQuery.sizeOf(context).width < kMobileBreakpoint;
    return Row(
      children: [
        if (mobile)
          _IconGlassButton(
            key: const ValueKey('menu-button'),
            icon: AIcon.menu,
            tooltip: '打开播放列表',
            onTap: () => setState(() => _drawerOpen = true),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _npInfo(),
          ),
        ),
        // 总开关 + 折叠式特效面板：和左边的「打开列表」按钮**同一行同一中线**
        // （Row 默认 crossAxisAlignment.center）。特效展开是浮层，不撑高这一行，
        // 所以高度恒定、左右永远对齐。
        MasterToggle(
          on: app.fxOn,
          c1: app.c1,
          c2: app.c2,
          onChanged: (_) => app.toggleFx(),
        ),
        const SizedBox(width: 8),
        FxChecklist(
          masterOn: app.fxOn,
          c1: app.c1,
          c2: app.c2,
          onToggle: app.toggleFxItem,
          items: [
            FxItem(key: 'cloud', label: '词云', value: app.fxCloud),
            FxItem(key: 'spectrum', label: '频谱', value: app.fxSpectrum),
            FxItem(key: 'kick', label: '打光', value: app.fxKick),
            FxItem(key: 'pitch', label: '音高', value: app.fxPitch),
            FxItem(key: 'imager', label: '声像', value: app.fxImager),
          ],
        ),
      ],
    );
  }

  /// 歌名/歌手：高潮发光 + 非线性放大 + 跷跷板摆动（挂在同一容器，对应原版 np-info）
  Widget _npInfo() {
    final app = widget.app;
    final track = app.current;
    // 歌名响应式字号：clamp(1.2rem, 2.4vw, 1.55rem)（对应原版 topbar .song-title）
    final w = MediaQuery.sizeOf(context).width;
    final titleSize = clampD(w * 0.024, 19.2, 24.8);
    return AnimatedBuilder(
      animation: _viz,
      builder: (_, __) {
        return Transform.rotate(
          angle: _viz.npAngle * math.pi / 180,
          alignment: Alignment.center,
          child: Transform.scale(
            scale: _viz.npScale,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlowText(
                  track?.name ?? '还没有放歌哦…',
                  glow: _viz.npGlow,
                  blur: _viz.npBlur,
                  style: fontStyle(
                    size: titleSize,
                    weight: FontWeight.w700,
                    color: kText,
                  ).copyWith(letterSpacing: -0.01 * titleSize, height: 1.2),
                ),
                const SizedBox(height: 2),
                GlowText(
                  track?.artist ?? '点一首嘛？人家等着呢',
                  glow: _viz.npGlow,
                  blur: _viz.npBlur,
                  style: fontStyle(size: 14.7, weight: FontWeight.w500, color: kTextDim),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /* ---------------- 移动端抽屉 ---------------- */
  Widget _scrim() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_drawerOpen,
        child: AnimatedOpacity(
          opacity: _drawerOpen ? 1 : 0,
          duration: const Duration(milliseconds: 300),
          child: GestureDetector(
            onTap: () => setState(() => _drawerOpen = false),
            child: Container(
              color: const Color(0x73050610),
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawer() {
    return AnimatedSlide(
      offset: _drawerOpen ? Offset.zero : const Offset(-1.2, 0),
      duration: const Duration(milliseconds: 380),
      curve: kEaseDrawer,
      child: AnimatedOpacity(
        opacity: _drawerOpen ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        curve: kEaseOut,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, top: 12, bottom: 12),
          child: SizedBox(
            width: mathMin(kSidebarWidth, MediaQuery.sizeOf(context).width * 0.84),
            child: Sidebar(
              app: widget.app,
              onTrackTap: () => setState(() => _drawerOpen = false),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏玻璃小按钮（移动端菜单键）
class _IconGlassButton extends StatefulWidget {
  const _IconGlassButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final List<String> icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<_IconGlassButton> createState() => _IconGlassButtonState();
}

class _IconGlassButtonState extends State<_IconGlassButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip ?? '',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
        scale: _pressed ? kPressScale : 1,
        duration: const Duration(milliseconds: 120),
        curve: kEaseOut,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0x29FFFFFF)),
            color: const Color(0x14FFFFFF),
          ),
            child: Center(
              child: AurumIcon(widget.icon,
                  size: 18, color: kText, strokeWidth: 2.2),
            ),
          ),
        ),
      ),
    );
  }
}

double mathMin(double a, double b) => a < b ? a : b;
