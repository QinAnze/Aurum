/// AppState：全局唯一可监听状态（对应原版 state 对象 + 所有事件编排）。
/// 契约层：widgets/effects 只经本类读写状态与触发动作。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/music_api.dart';
import '../audio/player_engine.dart';
import '../local/local_library.dart';
import '../models.dart';
import '../net_image.dart';
import '../theme/tokens.dart' show kDefaultC1, kDefaultC2;

/// 侧栏视图
enum LibraryTab { online, local }

class AppState extends ChangeNotifier {
  /// [autoStart] 为 false 时不发起启动搜索（单测里避免打网络）
  AppState({required this.engine, bool autoStart = true}) {
    engine.init();
    engine.events.listen(_onEngineEvent);
    if (autoStart) {
      _startup();
    } else {
      _skipStartup = true;
    }
  }

  final PlayerEngine engine;
  StreamSubscription<EngineEvent>? _engineSub;

  /// 已被销毁：启动搜索 / 封面取色等 fire-and-forget 任务可能晚于 dispose 回来
  bool _disposed = false;
  bool _skipStartup = false;

  /* ---------------- 播放列表 ---------------- */
  /// 在线搜索结果（与本地库分开存放，切视图互不影响）
  List<Track> _onlineTracks = [];
  int index = -1;

  /// 当前播放音轨：与列表 index 解耦，切换视图也不影响标题显示
  Track? _current;
  Track? get current => _current;

  /// 当前视图下的列表
  List<Track> get tracks =>
      tab == LibraryTab.local ? localTracks : _onlineTracks;

  /// 本地库：从用户选择的文件夹扫描出来的音轨（source == 'file'）
  List<Track> localTracks = [];
  /// 已导入的文件夹路径（用于侧栏展示与重复导入判断）
  List<String> localFolders = [];
  /// 当前侧栏视图：在线搜索结果 / 本地音乐库
  LibraryTab tab = LibraryTab.online;
  /// 正在扫描本地文件夹
  bool scanning = false;

  PlayMode mode = PlayMode.list;

  /// 搜索状态：转圈 + 清除按钮（互斥显隐，对应原版 .search.loading/.has-x）
  bool searching = false;
  String searchText = '';

  /// 列表标题：'播放列表' / '「关键词」· N 首'
  String listLabel = '播放列表';

  /* ---------------- 播放状态 ---------------- */
  bool playing = false;
  double position = 0;
  double duration = 0;

  /// 播放进度专用通知源。
  /// 引擎每 200ms 推一次位置，若走 [_notify] 会把整棵树（侧栏列表 + 封面 +
  /// 控件）每秒重建 5 次，肉眼就是轻微的顿感；进度条只需自己跟着动，
  /// 所以单独开一条通知通道。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  /// 进度条拖拽（1:1 跟踪，pointerup 才 seek）
  bool dragging = false;
  double dragRatio = 0;

  /* ---------------- 音量 ---------------- */
  double volume = 1.0;
  bool muted = false;
  double _volPrev = 1.0;

  /* ---------------- 视觉特效总开关（词云/频谱/超频 合一） ---------------- */
  bool fxOn = true;

  /* ---------------- 主题色（封面取色） ---------------- */
  Color c1 = const Color(0xFFC9A06A); // 默认：香槟金
  Color c2 = const Color(0xFF7FA693); // 默认：灰绿
  List<Color>? palette;
  bool bgFlip = false;

  /// 当前展示封面（大图 500）
  String? coverUrl;
  /// 背景封面（与 coverUrl 同步，交给 bg 层）
  String? bgUrl;

  /* ---------------- 歌词（供词云消费） ---------------- */
  List<LyricLine> lyrics = [];
  /// 歌词版本号：home 层监听以触发词云重置（对应 setLyrics → cloudReset）
  int lyricsRev = 0;

  /* ---------------- Toast ---------------- */
  String? toastMsg;
  bool toastVisible = false;
  Timer? _toastTimer;

  /* ---------------- 内部 ---------------- */
  int _reqToken = 0; // 防止快速切歌时旧请求覆盖新状态
  bool _tryingUrls = false; // 候选链试错中（error 事件不应触发跳下一首）
  Timer? _skipTimer;
  static final math.Random _rng = math.Random();

  /* ================================================================
     启动：探测本地 NCMApi + 默认推荐
     ================================================================ */
  Future<void> _startup() async {
    if (_skipStartup) return;
    await detectLocalApi();
    if (_disposed) return;
    await search('周杰伦');
  }

  /* ================================================================
     搜索（原版 search()：本地 → 网易 → 酷我）
     ================================================================ */
  Future<void> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    searching = true;
    _notify();
    try {
      final list = await searchTracks(kw);
      if (list.isEmpty) {
        toast('什么都没找到喵…换个词试试嘛？');
        return;
      }
      _onlineTracks = list;
      tab = LibraryTab.online; // 搜索即回到在线视图
      index = -1;
      listLabel = '「$kw」· ${list.length} 首';
      _notify();
    } catch (e) {
      toast('接口好像睡着了喵…再试一次啦！');
    } finally {
      searching = false;
      _notify();
    }
  }

  /// 清除搜索（原版 searchClear click）
  void clearSearch() {
    searchText = '';
    _onlineTracks = [];
    index = -1;
    listLabel = '播放列表';
    _notify();
  }

  /* ================================================================
     本地音乐库（文件夹选择 + 扫描）
     ================================================================ */

  /// 切换侧栏视图（在线 / 本地）
  void setTab(LibraryTab t) {
    if (tab == t) return;
    tab = t;
    // 两个视图各自维护列表；正在播放的曲目不受切换影响
    if (t == LibraryTab.local) {
      listLabel = localTracks.isEmpty
          ? '本地音乐（还没有导入喵）'
          : '本地音乐 · ${localTracks.length} 首';
    } else {
      listLabel = searchText.trim().isEmpty ? '播放列表' : listLabel;
    }
    // index 是「当前视图列表里的下标」，切视图后必须按 current 重新定位，
    // 否则上一首/下一首会从另一个列表的位置接着走（表现为跳错歌）。
    _syncIndexToCurrent();
    _notify();
  }

  /// 按当前播放曲目在新列表里重新定位 index；找不到就 -1
  void _syncIndexToCurrent() {
    final cur = _current;
    if (cur == null) {
      index = -1;
      return;
    }
    final list = tracks;
    final at = list.indexWhere((t) => t.id == cur.id && t.source == cur.source);
    index = at;
  }

  /// 弹出系统目录选择框并扫描；返回是否导入成功。
  /// 用户取消 / 平台不支持 / 目录无音频时返回 false。
  Future<bool> importFolder() async {
    final dir = await pickMusicFolder();
    if (dir == null || dir.isEmpty) return false;

    scanning = true;
    _notify();
    try {
      final found = await scanFolder(dir);
      if (found.isEmpty) {
        toast('这个文件夹里没有找到音乐喵…');
        return false;
      }
      // 去重：同路径不重复入库
      final seen = <String>{for (final t in localTracks) t.id};
      final added = <Track>[
        for (final t in found)
          if (seen.add(t.id)) t,
      ];
      localTracks = [...localTracks, ...added];
      if (!localFolders.contains(dir)) localFolders = [...localFolders, dir];

      tab = LibraryTab.local;
      listLabel = '本地音乐 · ${localTracks.length} 首';
      _syncIndexToCurrent();
      toast('导入 ${added.length} 首喵～随便听！');
      return true;
    } catch (_) {
      toast('扫描文件夹失败了喵…换个试试？');
      return false;
    } finally {
      scanning = false;
      _notify();
    }
  }

  /// 清空本地库（保留在线搜索结果）
  void clearLocal() {
    localTracks = [];
    localFolders = [];
    if (tab == LibraryTab.local) {
      index = -1;
      listLabel = '本地音乐（还没有导入喵）';
    }
    toast('本地列表已清空喵');
    _notify();
  }

  /* ================================================================
     播放（原版 playAt：跨源解析 → 封面/取色 → 歌词 → URL 候选链试错）
     ================================================================ */
  Future<void> playAt(int i) async {
    if (i < 0 || i >= tracks.length) return;
    Track track = tracks[i];
    index = i;
    _current = track;
    setLyrics(null);
    duration = 0;
    position = 0;
    progress.value = 0;
    _notify();
    _skipTimer?.cancel();

    final token = ++_reqToken;

    // 酷我源：跨源解析到网易拿播放链（解析结果缓存回列表）
    if (track.source == 'kuwo') {
      final resolved = await resolveKuwoToNetease(track);
      if (token != _reqToken) return;
      if (resolved != null) {
        track = resolved;
        tracks[i] = resolved; // 缓存解析结果，下次直接播
      }
    }

    // 封面 + 背景色
    unawaited(_loadCover(track, token));

    // 歌词
    unawaited(_loadLyrics(track, token));

    // 播放地址：逐级试错
    try {
      final urls = await urlCandidates(track);
      if (token != _reqToken) return;
      _tryingUrls = true;
      final ok = await engine.loadAndPlay(urls);
      _tryingUrls = false;
      if (token != _reqToken) return;
      if (!ok) {
        final unresolved = track.source == 'kuwo';
        toast(unresolved ? '这首没解析到播放源喵…跳、跳过了！' : '这首要 VIP 才能听喵…哼，跳、跳过了！');
        _skipTimer = Timer(const Duration(milliseconds: 900), () => next());
      }
    } catch (e) {
      _tryingUrls = false;
      if (token == _reqToken) toast('播放地址没拿到喵…');
    }
  }

  Future<void> _loadCover(Track track, int token) async {
    String? url;
    if (track.source == 'file') {
      url = await localCoverUrl(track.id); // 内嵌封面 → 临时文件
    } else if (track.source == 'local') {
      if (track.picUrl.isNotEmpty) {
        url = imageUrlCandidates(track.picUrl).first;
      }
    } else if (track.picId.isNotEmpty) {
      url = await fetchPicUrl(track, size: 500);
    }
    if (token != _reqToken) return;
    if (url == null) {
      // 这首歌没有任何封面（本地文件很常见：没有内嵌图、目录里也没 cover.jpg）。
      // 必须把上一首的封面与主题色一起清掉，否则界面会一直顶着上一首的图 ——
      // 这就是「点本地歌时封面/背景错位」的真正原因。
      coverUrl = null;
      bgUrl = null;
      c1 = kDefaultC1;
      c2 = kDefaultC2;
      palette = null;
      bgFlip = !bgFlip;
      _notify();
      return;
    }
    coverUrl = url;
    bgUrl = url;
    _notify();
    await extractColorsFromUrl(url, onResult: (c1, c2, pal) {
      if (token != _reqToken) return;
      this.c1 = c1;
      this.c2 = c2;
      palette = pal;
      bgFlip = !bgFlip; // 双层交叉淡入淡出
      _notify();
    });
  }

  Future<void> _loadLyrics(Track track, int token) async {
    String? lrc;
    if (track.source == 'file') {
      // 本地：内嵌歌词（ID3 USLT / FLAC LYRICS / M4A ©lyr）优先，
      // 没有再退回同目录同名 .lrc
      lrc = await localLyrics(track.id);
    } else {
      lrc = await fetchLyricLrc(track);
    }
    if (token != _reqToken) return;
    setLyrics(lrc);
  }

  /* ---------------- 基本控制 ---------------- */
  void togglePlay() {
    if (!engine.hasSource) {
      toast('先、先搜一首歌啦喵！');
      return;
    }
    if (engine.isPlaying) {
      engine.pause();
    } else {
      engine.play();
    }
  }

  /// 原版 stepIndex(dir)：shuffle 不重复随机，其余环形
  int stepIndex(int dir) {
    final n = tracks.length;
    if (n == 0) return -1;
    if (mode == PlayMode.shuffle) {
      if (n == 1) return 0;
      int i;
      do {
        i = _rng.nextInt(n);
      } while (i == index);
      return i;
    }
    return (index + dir + n) % n;
  }

  void next() {
    final i = stepIndex(1);
    if (i >= 0) playAt(i);
  }

  void prev() {
    // iOS 习惯：>3s 回开头
    if (engine.positionSec > 3) {
      engine.seek(0);
      return;
    }
    final i = stepIndex(-1);
    if (i >= 0) playAt(i);
  }

  void cycleMode() {
    mode = mode.next;
    toast(mode.label);
    _notify();
  }

  /* ---------------- 进度拖拽 ---------------- */
  void beginDrag(double ratio) {
    if (duration <= 0) return;
    dragging = true;
    dragRatio = ratio.clamp(0.0, 1.0);
    _notify();
  }

  void updateDrag(double ratio) {
    if (!dragging) return;
    dragRatio = ratio.clamp(0.0, 1.0);
    _notify();
  }

  void endDrag() {
    if (!dragging) return;
    dragging = false;
    if (duration > 0) {
      final target = dragRatio * duration;
      engine.seek(target);
      position = target;
      progress.value = target;
    }
    _notify();
  }

  void seekBy(double delta) {
    if (duration <= 0) return;
    final target = (position + delta).clamp(0.0, duration);
    engine.seek(target);
    position = target;
    progress.value = target;
    _notify();
  }

  /* ---------------- 音量（状态瞬时切换；弧线动画归旋钮 widget） ---------------- */
  Future<void> setVolume(double v) async {
    v = v.clamp(0.0, 1.0);
    volume = v;
    muted = v <= 0;
    if (v > 0) _volPrev = v;
    await engine.setVolume(v);
    _notify();
  }

  /// 静音开关（原版 volBtn click：布尔唯一真相，音量即时切换）
  Future<void> toggleMute() async {
    muted = !muted;
    if (muted) {
      if (volume > 0) _volPrev = volume;
      volume = 0;
    } else {
      volume = _volPrev > 0 ? _volPrev : 1.0;
    }
    await engine.setVolume(volume);
    _notify();
  }

  /* ---------------- 视觉特效总开关 ---------------- */
  void toggleFx() {
    fxOn = !fxOn;
    toast(fxOn ? '视觉特效全开喵～都给我燃起来' : '特效关了，安分守己喵');
    _notify();
  }

  /* ---------------- 歌词装载（原版 setLyrics：解析 + 预分词 + skip 标记） ---------------- */
  void setLyrics(String? lrc) {
    final track = current;
    lyrics = prepareLyricLines(lrc, track);
    lyricsRev++;
    _notify();
  }

  /* ---------------- Toast ---------------- */
  void toast(String msg) {
    toastMsg = msg;
    toastVisible = true;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      toastVisible = false;
      _notify();
    });
    _notify();
  }

  /* ================================================================
     引擎事件
     ================================================================ */
  void _onEngineEvent(EngineEvent e) {
    switch (e) {
      case EnginePlayingChanged(:final playing):
        this.playing = playing;
        _notify();
      case EnginePositionChanged(:final positionSec):
        position = positionSec;
        if (!dragging) progress.value = positionSec; // 只通知进度条，不重建整树
      case EngineDurationChanged(:final durationSec):
        duration = durationSec;
        _notify();
      case EngineEnded():
        if (mode == PlayMode.one) {
          engine.seek(0);
          engine.play();
        } else {
          next();
        }
      case EngineLoadFailed():
        // 候选链试错期间由引擎换下一个 URL；链外失败才跳歌
        if (!_tryingUrls) {
          if (engine.hasSource) {
            toast('播放出错了喵！换、换下一首…');
            _skipTimer = Timer(const Duration(milliseconds: 900), () => next());
          }
        }
      case EngineAllCandidatesFailed():
        break; // playAt 里已处理
    }
  }

  /// 已销毁后静默丢弃：启动搜索、封面下载、字体/封面取色都是 fire-and-forget，
  /// 关窗时它们可能刚好回来，直接 notifyListeners 会抛「used after being disposed」。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _engineSub?.cancel();
    _toastTimer?.cancel();
    _skipTimer?.cancel();
    progress.dispose();
    engine.dispose();
    super.dispose();
  }
}
