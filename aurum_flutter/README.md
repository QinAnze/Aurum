# Aurum · 液态玻璃音乐播放器（Flutter 移植版）

`index.html`（Web 版）的完整 Dart + Flutter 桌面移植。视觉与交互 1:1 复刻：
液态玻璃面板、封面取色动态渐变背景、全屏重力词云、360° 频谱闭合曲线、
高潮（climax）驱动的封面抖动 / 歌名发光 / 跷跷板摆动、超频总开关。

## 运行

```bash
flutter pub get
flutter run -d windows        # 亦支持 macOS / Linux（flutter_soloud 跨平台）
```

依赖：Flutter 3.47+ / Dart 3.13+。字体使用 `assets/SmileySans-Oblique.ttf`（得意黑）。

**Windows 打包可运行目录**：

```bash
flutter build windows --release
# 产物在 build/windows/x64/runner/Release/，整个目录可直接分发
```

> `bin/` 是本机打包好的自包含目录（Qt 插件 DLL + 字体），**不入库**（见 `.gitignore`），
> 重新 `flutter build` 即可生成。

**Windows 构建前置**：本机未开「开发者模式」时 Flutter 无法创建插件软链
（`Building with plugins requires symlink support`）。两种解法：
开开发者模式（`start ms-settings:developers`），或在
`windows/flutter/ephemeral/.plugin_symlinks/` 下用**目录联接**预建
`flutter_soloud / jni / path_provider_windows / file_selector_windows`
四个指向 pub 缓存的链接（Flutter 见已存在即跳过创建）。

## 数据源

两种模式，侧栏顶部「在线 / 本地」切换：

| 模式 | 说明 |
| --- | --- |
| 在线 | 本地 NCMApi sidecar（`127.0.0.1:4530`，启动自动探测）→ GDStudio 公共 API → injahow 直链兜底 |
| 本地 | 点侧栏文件夹按钮选目录，递归扫描后完全离线播放（不依赖任何接口） |

**本地模式链路**：`scanFolder` 递归收集 → 文件名解析「歌手 - 歌名」→
播放时直接读文件字节喂给引擎 → 封面取内嵌图（ID3v2 APIC / FLAC PICTURE /
M4A covr），没有再找同目录同名图或 `cover.jpg` → 歌词优先取内嵌
（ID3v2 **USLT** / **SYLT**、FLAC/Vorbis **LYRICS**、M4A **©lyr**），
没有再读同目录同名 `.lrc` → 主题色从封面取。

> 国内文件普遍把**整段带时间轴的 LRC** 塞进 USLT，所以本地歌同样有滚动歌词
> 与逐句词云；`SYLT`（真正的时间戳帧）会被转换成 LRC 再进解析器。

| 容器 | 封面 | 歌词 |
| --- | --- | --- |
| MP3 | ID3v2 `APIC`（兼容 v2.2 `PIC`） | `USLT` / `SYLT` |
| FLAC | `PICTURE` 块 | `VORBIS_COMMENT` 的 `LYRICS` |
| M4A | `ilst.covr` | `ilst.©lyr` |

支持 `.mp3 .flac .wav .m4a .aac .ogg .opus .wma`；
扫描有上限保护（4000 文件 / 1500 首），并跳过 `node_modules`、`.git`、
`AppData` 这类目录——**只按相对扫描根目录的路径段判断**，所以把音乐放在
`AppData` 下也能正常扫到。

| 源 | 用途 |
| --- | --- |
| 本地 NCMApi sidecar（`127.0.0.1:4530`） | exe 场景首选：完整曲库、无限流。启动时自动探测 |
| GDStudio 公共 API | 网易优先、酷我兜底（搜索双源） |
| injahow meting（302 直链） | 播放地址兜底链 |

播放地址候选链（对应原版 `tryPlayUrls`，逐级试错）：
本地 → `song/url/v1` 音质回退 → injahow 302；
网易 → GDStudio 码率回退（320→192→128）→ injahow 302；
酷我 → injahow kuwo 302。酷我歌点击时先用「歌名+歌手」搜网易换源。

### ⚠️ 两个网络坑（实测）

1. **netease 图片 CDN 按客户端指纹拦截**：p1/p2.music.126.net 对
   dart:io（BoringSSL）客户端一律返回 `403 Forbidden nginx`——**加浏览器 UA 没用**、
   走不走代理也没用；同一张图 curl/python 能下、Dart 就是 403。
   p3.music.126.net 放行，音频 CDN（m801 等）也不受影响，播放不受影响。
   所以 `lib/net_image.dart` 自建了 `AurumNetworkImage`：同一张图按
   「p3 → 原 host」展开成候选逐个重试，谁先通用谁，全失败才显示占位图。
2. **接口要带浏览器 UA**：GDStudio 的网易搜索对非浏览器 UA 返回空数组，
   `http.get` 一律带 `kBrowserUa`。

## 架构

```
lib/
├── main.dart                  入口：引擎 + AppState → MaterialApp
├── models.dart                契约层：Track / LyricLine / PlayMode / 常量
├── api/music_api.dart         网络层：搜索/封面/歌词/取色/候选链
├── lyrics/lyrics_engine.dart LRC 解析 + CJK 分词 + 预分词 + skip 判定
├── audio/
│   ├── player_engine.dart     引擎抽象契约（事件流 + fft/wave）
│   ├── soloud_engine.dart     flutter_soloud 实现（候选链试错/seek/音量）
│   ├── load_gate.dart         切歌代次门闩（防并发交叉叠播）
│   ├── audio_probe.dart       音频时长探测（MP3 CBR/VBR、FLAC、WAV）
│   └── audio_cover.dart       内嵌封面解析（ID3v2 APIC / FLAC PICTURE）
├── local/local_library.dart   本地库：选目录 / 递归扫描 / 文件名解析 / 同名歌词
├── effects/
│   ├── viz_controller.dart    可视化主时钟：响度→climax、抖动、发光、频谱平滑
│   ├── spectrum_ring.dart     120 点闭合贝塞尔频谱曲线 painter
│   └── word_cloud.dart        词云：重力生命周期/碰撞/封面圆禁区/句末两词放大
├── theme/
│   ├── tokens.dart            设计 token（色彩/字体/缓动/玻璃材质）
│   └── cover_color.dart       封面取色数学（纯函数，可单测）
├── net_image.dart             带 CDN 故障转移的图片加载器（p1/p2 被挡 → p3）
├── widgets/                   玻璃面板/侧栏/封面/进度条/控件/旋钮/开关/toast
└── ui/home_page.dart          组装：背景 → 词云 → 侧栏+播放器（含响应式抽屉）
```

## 与原版的关键对应关系

- **climax（高潮因子）**：时域 RMS → `loudMax` 峰值保持（全曲 limiter 天花板）
  → `pos = inst/loudMax` → `pos>0.72` smoothstep；门槛 `loudMax<0.26`。
  intro 安静不抖、被压满的 drop 持续抖动发光，偏响/偏轻的歌都按各自高潮炸开。
- **词云**：`rise 850ms`（ease-out quad 上抛）→ `hold 4.2~8s` → `fall 1150ms`
  （ease-in quad 坠落）；换行不硬清场（错落 120ms 坠落）；音节节奏出场；
  句末最后两词放大到 18%~30% 短边；封面圆禁区（词云垫在封面之下）。
- **频谱**：单条白色闭合曲线（120 点二次贝塞尔平滑环），对数分 bin +
  非对称平滑（升 0.82 / 降 0.20），无信号回退 128BPM 模拟。
- **超频总开关**（右上角 pill）：词云 / 频谱 / 高潮抖动发光三合一；
  关闭 → 简单白色频谱、无抖动、无发光、词云清空。
- **音量旋钮**：270° 弧（底部 90° 为几何缺口，不随音量旋转），
  竖向拖拽 / 滚轮 / 方向键；静音时弧线 easeInOutCubic 非线性滑动。

## 与 Web 版的刻意差异

1. **面板不叠 `BackdropFilter`**：Web 版曾因「backdrop-filter 层 + 逐帧 canvas
   重绘」触发 GPU 过载白屏崩溃。Flutter 端改用半透渐变 + 渐变描边 + 大投影
   模拟玻璃（背景本身已高度模糊，观感一致且 60fps 稳定）。
2. **窗口不透明 + 深色底**：Web  exe 版透明窗口透出桌面；Flutter 端绘制深色
   渐变底（`#0b0d14 → #10131f`）。
3. **无 `Intl.Segmenter`**：Dart 无此 API，分词直接落地其回退方案
   （CJK 切 2~3 字块、拉丁按空白切）。
4. **时长探测**：flutter_soloud 不暴露音源时长，由 `audio_probe.dart`
   在把字节喂给引擎前解析文件头（MP3 走 Xing/Info 或 CBR 估算）。

## 动画平滑度（对照原版逐项校准）

Web 版全部动画由 RAF / CSS 合成层驱动，Flutter 端要自己补上等价机制：

- **词云画布必须恒重绘**：`CloudWord` 是可变对象，父子 painter 共享同一份
  controller，按字段比较 `shouldRepaint` 永远为 false → 词只在 climax 变化那帧
  跳一下。改为恒 `true`。
- **进度条补间**：引擎每秒只推 5 次位置，直接画就是「每 200ms 跳一格」；
  用 240ms 线性补间把跨度补满（拖拽时不补间，保持 1:1 跟手）。
- **进度通知独立通道**：位置更新只通知进度条（`AppState.progress`），
  不再走 `notifyListeners()` 把侧栏列表 + 封面 + 控件每秒重建 5 次。
- **光晕量化**：`GlowText` 把 glow/blur 量化到 1/24 与 0.5px。climax 每帧都在动，
  连续值会让 `TextStyle` 每帧都算「新样式」→ CJK 标题每帧重排；
  量化后绝大多数帧样式值相等，`RenderParagraph` 跳过重排，只剩 `Transform` 换矩阵。
- **时钟单调**：ticker 累计时间（`_tsec`）替代 `DateTime.now()`，
  跷跷板摆动与 BPM 回退不会因系统时间跳变而抽搐。

## 测试

```bash
flutter test        # 89 个单测
```

| 文件 | 覆盖 |
| --- | --- |
| `aurum_test.dart` | LRC 解析 / CJK 分词 / 歌词清洗 / 时长探测 / SVG 路径 / 时间格式化 |
| `viz_test.dart` | CDN 候选 host 顺序；频谱取数与标度、BPM 回退、暂停衰减、关开关衰减 |
| `load_gate_test.dart` | 切歌并发门闩：代号失效 / 串行化 / 复现「A 在途切 B」竞态 |
| `cover_color_test.dart` | 封面取色数学（均值色 / 高饱和色 / 调色板 / 灰图回退） |
| `spectrum_ring_test.dart` | 环画布尺寸：Stack(loose) 压缩对照实验 + 真实 CoverArt 断言 |
| `local_library_test.dart` | 文件名解析（序号/分隔符/杂注/不误切连字符）+ 递归扫描与跳过目录 |
| `audio_tags_test.dart` | 内嵌元数据：v2.3/v2.4 帧长、>512KB 大封面、USLT 描述、FLAC 块、异常输入 |
| `local_media_test.dart` | 封面/歌词取用顺序：内嵌 → 同名文件 → 目录通用封面 → null |
| `local_playback_test.dart` | 本地歌端到端：封面+内嵌 LRC 落地、无封面清空旧图、切视图索引重定位 |
| `home_smoke_test.dart` | 整棵 HomePage 树构建、开关交互、窄屏抽屉 |

## 排障记录（实测踩过的坑）

- **频谱「完全不存在」（一个像素都没画）**：布局问题，不在数据链路。
  `Stack` 默认 `StackFit.loose`，会把非 positioned 子件**压到 Stack 自身尺寸**（= 封面边长），
  于是 160% 的环画布只剩 100% → `baseR` 反超画布半径 → `ampMax` 转负 →
  painter 里 `if (ampMax <= 0) return` → 整圈不画。
  修法：`OverflowBox` 让画布拿回真实 160% 尺寸（Stack 已设 `clipBehavior: Clip.none`），
  并把 `ringAmpMax()` 抽出为纯函数，画布被压时兜底保留最小幅度而非静默 return。
- **高潮时环是「虚化」而非「发亮」**：`MaskFilter.blur` 加在**唯一**那个 paint 上，
  等于把线条本体整体模糊掉，只剩虚影。CSS `shadowBlur` 的语义是
  「先画清晰图形，再在其**下层**铺一层模糊阴影」，线条本体依旧锐利。
  修法：分两遍绘制——先铺模糊的辉光层，再叠一遍无 blur 的清晰主线。
  相关：`GlassPanel` 的 `ClipRRect` 会把溢出面板的辉光削平，播放器面板需传 `clip: false`。
- **切歌后两首歌一起放**：`loadAndPlay` 之间会交叉。A 还在下载时切到 B，
  B 的清场已经跑完（此时 A 尚未建音源），随后 A 下载完成照样 `play()` → 叠播。
  修法：`audio/load_gate.dart` 代次门闩——每个 `await` 之后自检代号是否仍最新，
  过期的请求把自己刚 loadMem 的 source 销毁（play 后才发现还要先 stop 再 dispose）。
- **频谱是一条死平的环**：Web 的 `getByteFrequencyData` 是 **dB 映射的 0~255 字节值**，
  flutter_soloud 给的是**线性幅度**（音乐常见 0.001~0.3）。照抄 `/255` 等价换算后
  曲线幅度只有 1px，肉眼看就是不动。修法：自适应峰值归一化 + gamma，任何标度都用满量程。
- **封面/背景取色全失败**：netease 图片 CDN 对 dart:io 客户端一律 403（加 UA 也没用，
  走不走代理也没用），只有 `p3.music.126.net` 放行。见 `lib/net_image.dart`。
- **切歌后旧歌还在放 → 连带频谱/发光全失效**：`stop()` 要等原生 `voiceEnded` 回调，
  暂停态下该回调可能不来，`loadAndPlay` 会卡死 → `app.playing` 恒为 false →
  频谱/高潮抖动/发光全不触发。修法：登记全部 voice/source、stop 前先唤醒、
  `stop`/`dispose` 加超时、最后遍历 `SoLoud.activeSounds` 兜底清场。
- **背景色不随封面变**：`extractColorsFromUrl` 自己也走 dart:io 下载封面，
  同样撞 CDN 403 → 取色静默失败。修法：复用 `imageUrlCandidates()` 的候选顺序。
- **多实例叠着跑会让窗口测量失真**：验证时务必先杀掉旧实例再抓图，
  否则 `FindWindowW` 拿到的是别的进程的窗口。
- **本地歌「没有封面、没有歌词」**：三个独立问题叠在一起。
  ① ID3v2.3 的帧长是普通 32 位，早期实现取「syncsafe 与 32 位里较小的那个」，
     330827 被算成 83531 → 逐帧走位全乱 → 永远找不到 APIC。
  ② 固定只读文件头 512KB，而内嵌封面常有 600KB~1.3MB → 标签被截断。
  ③ USLT 的歌词完全没实现；且真实文件的内容描述写的是 `"Lyrics"`（非空），
     跳过描述时要按「寻找终止符」处理，否则歌词会以 `Lyrics` 开头。
- **点本地歌时封面/背景「错位」**：换到没有封面的歌时，
  `_loadCover` 在 `url == null` 直接 return，于是界面继续显示**上一首**的封面
  与主题色。修法：无封面时显式清空 `coverUrl/bgUrl` 并把配色回默认；
  `CoverArt` 也要走完「旧封面掉落 → 回 idle」，否则会卡在 fall 相位、封面留白。
- **切视图后上一首/下一首跳错歌**：`index` 指的是「当前列表」的下标，
  切在线/本地后没重新定位。修法：按当前播放曲目的 `source + id` 在新列表里重新定位。

## 致谢

原版 Web 实现见仓库根目录 `index.html`；音乐 API 可用性结论沉淀自
GDStudio / injahow / NeteaseCloudMusicApi 实测。
