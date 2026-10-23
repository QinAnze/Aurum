# Aurum · 液态玻璃音乐播放器

<div align="center">

<img src="assets/icon.png" alt="Aurum" width="110">

**封面取色的半透明玻璃界面，360° 频谱环、重力词云、跟着音高跳动的字。**

[![Windows](https://github.com/QinAnze/Aurum/actions/workflows/windows.yml/badge.svg)](https://github.com/QinAnze/Aurum/actions/workflows/windows.yml)
![version](https://img.shields.io/badge/version-0.5.1-c9a06a)
![platform](https://img.shields.io/badge/platform-Windows-7fa693)

</div>

## 下载

到 [Releases](https://github.com/QinAnze/Aurum/releases) 取 `Aurum-0.5.1-windows-x64.zip`，
解压双击 `aurum.exe`，目录里已带运行时和插件 DLL，不用安装。

未签名的个人项目，首次运行 Windows 会提示「已保护你的电脑」→ 更多信息 → 仍要运行。

## 两个版本

| 版本 | 位置 | 说明 |
| --- | --- | --- |
| 桌面版 | `aurum_flutter/` | Flutter 3.47 + flutter_soloud，主线 |
| Web 版 | `index.html` | 单文件 HTML/CSS/JS，双击即用 |

两版共享同一套设计语言与动画参数。

## 特性

- **液态玻璃**：半透渐变 + 渐变描边 + 大投影，颜色全程由封面取样驱动
- **360° 频谱环**：120 点闭合贝塞尔曲线绕封面，高潮时发亮而不是发虚
- **重力词云**：按音节节奏从底部升起、悬停、坠落，句末两词放大
- **音高特效**：歌词段在封面中心浮出一个像素音名；纯乐器段把像素音名撒满整屏，
  每个字随机掉落/翻滚/翻面入场，高潮时整体放大发光
- **声像颗粒**：左右声道算立体声宽度，最底层铺一片灰色微粒，宽了往外蹦、窄了往中心收
- **封面直线频谱**：把频谱环拉直放封面内，10Hz–21kHz 对数分频，低频粗且慢、高频细且快
- **高潮驱动**：时域 RMS → 全曲峰值保持 → climax 因子，统一驱动抖动、光晕、放大
- **折叠式特效开关**：顶栏一枚胶囊就能收起/展开词云、频谱、打光、音高、声像五个开关，
  面板底部还能在「仅 GDStudio」（稳）与「混合检索」（快）之间切换检索源
- **本地音乐库**：选目录递归扫描，离线播放，内嵌封面与歌词（ID3v2 / FLAC / M4A）
- **键盘操作**：空格播放暂停，方向键切歌与音量

## 跑起来

```bash
# Web 版：直接双击 index.html，或起个静态服务器
python -m http.server 8123

# 桌面版
cd aurum_flutter
flutter pub get
flutter run -d windows
```

需要 Flutter 3.47+ / Dart 3.13+。构建细节与 Windows 软链坑见
[`aurum_flutter/README.md`](aurum_flutter/README.md)。

## 数据源

在线播放走公共接口，**仓库里不含任何音源**，也不绕过版权限制：

- GDStudio 公共 API（网易优先、酷我兜底）
- 网易直连（搜索 / 封面 / 取流都直接打平台本体，不经镜像）
- injahow meting（302 直链兜底）
- 本地 NCMApi sidecar（`127.0.0.1:4530`，可选，启动时自动探测）

搜索与取流都是**并发竞速**，谁先出结果用谁；需要现问 3~5 秒的源只在快路径全挂时才等。

已知限制：网易图片 CDN 会按客户端指纹拦截（`p1/p2` 对 dart:io 返回 403，
只有 `p3` 放行，桌面版因此自建了多 host 故障转移）；公共接口偶发限流，搜索可能返回空。

## 目录

```
.
├── index.html          # Web 版（单文件）
├── assets/             # Web 版图标与字体
└── aurum_flutter/      # 桌面版
    ├── lib/
    │   ├── api/        搜索 / 封面 / 歌词 / 取色
    │   ├── audio/      soloud 引擎、时长探测、内嵌元数据
    │   ├── effects/    可视化时钟、频谱环、词云、音高散落
    │   ├── local/      本地音乐库
    │   ├── state/      全局状态
    │   └── widgets/    玻璃面板、侧栏、控件
    ├── test/           181 个单测
    └── windows/        Windows runner
```

## 版权

仅供学习交流，音乐版权归原平台所有。

字体：得意黑 Smiley Sans（SIL OFL）、EB Garamond（SIL OFL）、
HYPixel 11px（汉仪，商用需自行确认授权）。
