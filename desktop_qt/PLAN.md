# Aurum × Rhine 融合方案

把 `aurum_flutter` 的**播放器视觉**移植进 Rhine（Qt/C++）桌面壳，保留 Rhine 的
3D 唱片架选歌体验。产物是一套 Qt 应用，Flutter 版作为设计参照与设计验证保留。

## 已敲定（用户确认）

| 决策 | 结果 |
| --- | --- |
| 骨架 | **Qt（Rhine）**，Flutter 版仅作设计参照 |
| 代码归属 | 源码搬进本仓库 `desktop_qt/`（不含构建产物） |
| 音频可视化 | **接真 FFT**（`QAudioBufferOutput` 取 PCM，自写 radix-2） |
| 详情页 | 保留 Rhine 的光盘盒；**点开光盘盒后**进入 Aurum 竖屏播放器（无侧边栏版） |

## 现状摸底（已核实）

- Rhine 的界面**不是 QML**：只有一个 283 行的 `Qt/qml/Main.qml` 做根窗口，
  其余全部是 `Qt/src/NativeHud*.cpp` 用 **QPainter** 自绘（`Hud : QQuickPaintedItem`）。
- 输入是单一通道：`Main.qml` 里一个透明 `MouseArea` 把指针转发给 C++（`rhine.pointer`），
  由 `NativeHudInput` / `NativeHudMusic` 做命中测试。
- 播放走 `QMediaPlayer`（`Qt/src/AudioPlayer.cpp`），**没有任何 FFT/频谱代码**。
- Qt 6.8+ 提供 `QAudioBufferOutput`，可挂到 `QMediaPlayer` 上直接拿解码后的 PCM，
  不需要再开一路解码。

## 目标形态

```
┌──────────────────────────────────────────────┐
│  顶部导航（Rhine 原样）                        │
│                                              │
│        3D 唱片架（Rhine 原样，不动）            │
│                                              │
├──────────────────────────────────────────────┤
│  Aurum 风格播放条（替换 Rhine 原 playerBar）    │
└──────────────────────────────────────────────┘
        ↓ 点开光盘盒
┌──────────────────────────────────────────────┐
│ ┌──────────────┐  ┌─────────────────────────┐│
│ │  光盘盒        │  │  Aurum 竖屏播放器        ││
│ │ （Rhine 原样） │  │  封面 / 歌名             ││
│ │  左            │  │  频谱环 / 进度 / 控件    ││
│ └──────────────┘  └─────────────────────────┘│
│                                              │
│  词云：覆盖整个窗口，从唱片架里升起来           │
└──────────────────────────────────────────────┘
```

两条布局约束（用户确认）：

1. **左光盘 + 右播放器**：点开光盘盒后是同屏分栏，不是全屏覆盖；
   左侧继续显示 Rhine 的 CD 盒，右侧是 Aurum 的竖向播放器栏。
2. **词云是整窗图层**：不受分栏限制，从唱片架区域升起，飘过整个窗口。

## 目录结构（新增）

```
desktop_qt/
├── Qt/src/
│   ├── NativeHudPlayer.cpp      ← 改为调用 Aurora 播放条
│   ├── NativeHudDetail.cpp      ← 改为「光盘盒 → Aurum 竖屏页」
│   └── aurum/                   ← 新增：Aurum 视觉层
│       ├── AurumSkin.h/.cpp        设计 token（配色/字号/缓动/玻璃材质）
│       ├── AurumPlayerBar.h/.cpp   底部播放条
│       ├── AurumNowPlaying.h/.cpp  竖屏播放器页
│       ├── AurumSpectrum.h/.cpp    频谱环 painter
│       ├── AurumWordCloud.h/.cpp   词云（重力生命周期）
│       ├── AurumGlow.cpp           发光文字
│       └── AurumVisual.h/.cpp      climax 计算 + 音频帧环形缓冲
└── Qt/src/audio/
    └── FftTap.h/.cpp           QAudioBufferOutput → PCM → 窗函数 → radix-2 FFT
```

## 分阶段

### Phase 1 · 地基（本次完成）
- [x] 建 `dev` 分支
- [x] Rhine 源码搬进 `desktop_qt/`（45MB，含字体/模型/桥接，不含构建产物）
- [x] MinGW 兼容固化（WinRT 段加 `#if !defined(__MINGW32__)`，MSVC 构建行为不变）
- [x] 新目录下 `cmake + ninja` 构建通过，产物可启动
- [ ] 资源准备脚本（`scripts/prepare-dev.py`）：导出 glb、拷字体/光照、装桥接依赖

### Phase 2 · 音频数据通路
- `FftTap`：挂 `QAudioBufferOutput`，环形缓冲保留最近 2048 帧
- 自写 radix-2 FFT + Hann 窗；输出 120 bin 的对数刻度，对齐 Aurum 的
  `binFreqs`（升 0.82 / 降 0.20 的非对称平滑）
- `AurumVisual`：时域 RMS → `loudMax` 峰值保持 → `pos` → `climax`
  （阈值 0.72 smoothstep、`loudMax < 0.26` 门槛，与原版一致）
- 验收：暂停时频谱衰减到 0；高潮段落 climax 持续 > 0.6

### Phase 3 · 播放条
- `AurumPlayerBar`：玻璃底 + 封面圆 + 歌名/歌手 + 进度条 + 播放/上下曲/模式/音量旋钮
- 颜色跟随封面取色（Rhine 已有取色能力，复用 `SceneAppearance`）
- 验收：与 Aurum 底部条视觉一致；拖动进度 1:1 跟手

### Phase 4 · 竖屏播放器（点开光盘盒后）
- `AurumNowPlaying`：大封面（旋转）+ 歌名发光 + 词云 + 频谱环 + 进度 + 控件
- 从光盘盒点击进入 / ESC 或返回键退出，转场沿用 Rhine 的 HUD 过渡节奏
- 验收：词云按歌词时间轴入场；频谱环随音乐脉动；climax 时封面抖动 + 歌名发光

### Phase 5 · 收尾
- 字体/资源随包分发；README 与 CI 更新（Windows 构建走 MSVC Qt 6.8）
- 回归：Rhine 原有选歌、搜索、登录、歌单功能不受影响

## 技术要点与风险

| 点 | 说明 |
| --- | --- |
| 输入路由 | 竖屏页是覆盖层，需要**先于** `rhine.pointer` 吃掉事件；在 `Main.qml` 的 MouseArea 里按 `engine.overlayActive` 分流，或在 Hud 里先做 overlay 命中测试 |
| 性能 | QPainter 每帧画模糊代价高；玻璃底纹缓存为 `QPixmap`，只重绘变化层 |
| 字体 | 继续用 RhineMiSans（`Glyphs.cpp` 的 QRawFont 缓存），词云复用同一字形管线 |
| 回退 | 每个 Phase 独立可运行；Phase 3/4 出问题可先只换底部条，详情页保持原样 |
| 许可 | Rhine 为 MIT，移植需保留 `LICENSE` / `NOTICE` 与原作者署名 |
