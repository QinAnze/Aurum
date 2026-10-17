# Aurum · 液态玻璃音乐播放器

<div align="center">

<img src="assets/icon.png" alt="Aurum" width="120">

> 封面取色的液态玻璃面板、360° 频谱环、重力词云 —— 同一套视觉语言的两种实现。

[![Windows](https://github.com/QinAnze/Aurum/actions/workflows/windows.yml/badge.svg)](https://github.com/QinAnze/Aurum/actions/workflows/windows.yml)
![version](https://img.shields.io/badge/version-0.1.0-c9a06a)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-7fa693)

</div>

## 两个版本

| 版本 | 目录 | 技术栈 | 适合 |
| --- | --- | --- | --- |
| **Web 版** | 根目录 `index.html` | 纯 HTML / CSS / JS，零运行时依赖 | 双击即用、可整目录丢到 Vercel |
| **桌面版** | `aurum_flutter/` | Flutter 3.47 · Dart 3.13 · flutter_soloud | 本地音乐库、离线播放、持续 60fps 特效 |

两版共享同一套设计语言与动画参数（`index.html` 是原生实现，Flutter 版是逐项对齐的移植）。

## 下载（桌面版 0.1.0）

到 [Releases](https://github.com/QinAnze/Aurum/releases) 下载 `Aurum-0.1.0-windows-x64.zip`，
解压后双击 `aurum.exe` 即可 —— 目录内已含 Flutter 运行时与全部插件 DLL，无需安装。

> 未签名的个人项目，Windows 首次运行可能提示「已保护你的电脑」，
> 点「更多信息 → 仍要运行」。

## 特性

**共有**

- 🪟 **液态玻璃 UI**：半透渐变 + 渐变描边 + 大投影，封面取色驱动动态背景
- 🎤 **360° 频谱环**：120 点闭合贝塞尔曲线环绕封面，高潮时发亮而非发虚
- ✨ **重力词云**：按音节节奏从底部升起、悬停、坠落，句末两词放大
- 🌊 **高潮驱动**：时域 RMS → 全曲峰值保持 → climax 因子，驱动封面抖动、歌名光晕与跷跷板摆动
- 🎛️ **超频总开关**：一键关掉词云 / 频谱 / 抖动，回到极简白环
- 🔊 **音量旋钮**：SVG 270° 弧，拖拽 / 滚轮 / 方向键
- 🔁 **三种播放模式**：列表循环 / 单曲循环 / 随机

**桌面版额外**

- 📁 **本地音乐库**：选文件夹递归扫描，完全离线播放
- 🖼️ **内嵌元数据**：从音频里直接读封面与歌词（ID3v2 APIC/USLT/SYLT、FLAC PICTURE/Vorbis、M4A covr/©lyr）
- 🗂️ **在线 / 本地双视图**：互不干扰，切视图不影响正在播放的歌
- ⌨️ **键盘操作**：空格播放暂停、方向键切歌 / 调音量

## 快速开始

### Web 版

```bash
start index.html          # Windows：直接双击也行
# 或起个本地服务器，避开 file:// 的跨域限制
python -m http.server 8123
```

部署到 Vercel：框架预设选 **Other**，构建命令与输出目录都留空，直接部署根目录。

### 桌面版

```bash
cd aurum_flutter
flutter pub get
flutter run -d windows
```

依赖 Flutter 3.47+ / Dart 3.13+。完整构建说明、Windows 软链问题的两种解法、
以及 `flutter build windows --release` 的产物位置，见 [`aurum_flutter/README.md`](aurum_flutter/README.md)。

## 目录结构

```
.
├── index.html                # Web 版：单文件应用
├── assets/                   # Web 版图标与字体
└── aurum_flutter/            # 桌面版（Flutter）
    ├── lib/
    │   ├── api/              搜索 / 封面 / 歌词 / 取色 / 播放地址候选链
    │   ├── audio/            flutter_soloud 引擎、时长探测、内嵌元数据、切歌门闩
    │   ├── effects/          可视化主时钟、频谱环、词云
    │   ├── lyrics/           LRC 解析 + CJK 分词
    │   ├── local/            本地音乐库（选目录 / 扫描 / 同名歌词）
    │   ├── state/            全局状态（播放、列表、主题色、本地库）
    │   ├── theme/            设计 token 与取色数学
    │   ├── ui/ home_page     整页组装
    │   └── widgets/          玻璃面板、封面、侧栏、控件、旋钮……
    ├── test/                 89 个单测
    └── windows/              Windows runner
```

## 数据源与已知限制

在线播放走公共接口，**没有内置任何音源**，也不绕过任何版权限制：

- GDStudio 公共 API（网易优先、酷我兜底）
- injahow meting（302 直链兜底）
- 本地 NCMApi sidecar（`127.0.0.1:4530`，启动自动探测，可选）

已知限制（原因与修法都写在 `aurum_flutter/README.md` 的「排障记录」里）：

1. **netease 图片 CDN 会按客户端指纹拦截**：`p1/p2.music.126.net` 对 dart:io 一律 403，只有 `p3` 放行 —— 桌面版因此自建了多 host 故障转移的图片加载器。
2. **公共接口偶发限流 / 不可达**：搜索可能返回空列表，属上游问题。
3. 音源可用性随平台策略变化，随时可能失效。

## 测试

```bash
cd aurum_flutter
flutter test          # 89 项：分词 / 歌词 / 时长探测 / 频谱标度 / 切歌并发 / 取色 / 本地库 / 内嵌标签
```

## CI / 发布

[`.github/workflows/windows.yml`](.github/workflows/windows.yml)：

| 触发 | 动作 |
| --- | --- |
| push `main` / PR / 手动 | `pub get` → `analyze` → `test` → `build windows --release` → 打包 zip 上传为 artifact（保留 30 天） |
| 打 `v*` 标签 | 在上一行基础上，把同一个 zip 挂到 GitHub Release |

版本号只在 `aurum_flutter/pubspec.yaml` 里改（`version: 0.1.0+1`），Flutter 会把它写进
exe 的文件属性（FileVersion / ProductVersion），CI 也从这里读出来给压缩包命名。

发版流程：

```bash
# 1) 改 aurum_flutter/pubspec.yaml 的 version
# 2) 提交
git add -A && git commit -m "chore: 发布 0.1.0"
# 3) 打标签并推送（标签由仓库维护者自行打）
git tag v0.1.0 && git push origin main --tags
```

构建产物名：`Aurum-<version>-windows-x64.zip`（解压即用，含 `aurum.exe` + 运行时 DLL + `data/`）。

**正式包一律由 GitHub Actions 产出**，本地只做开发调试：

```bash
cd aurum_flutter
flutter build windows --release   # 本地验证用，不作为发布包
```

打标签后会自动创建 Release，下载地址形如
`https://github.com/QinAnze/Aurum/releases/download/v0.1.0/Aurum-0.1.0-windows-x64.zip`。

## 版权

仅供学习交流，音乐版权归原平台所有。字体为「得意黑 Smiley Sans」（SIL OFL）。
