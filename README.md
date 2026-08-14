# Aurum · 液态玻璃音乐播放器

<div align="center">

<img src="assets/icon.png" alt="Aurum" width="120">

> 一个单文件、零依赖、液态玻璃风格的音乐播放器。

</div>

## 特性

- 🎵 **单文件应用**：整个播放器就是一个 `index.html`，无构建、无打包
- 🪟 **液态玻璃 UI**：backdrop-filter 毛玻璃、封面取色动态渐变
- 🎤 **实时频谱**：Web Audio AnalyserNode，白闭合曲线环绕封面
- ✨ **词云特效**：魔法书式重力动画，按音节节奏入场
- 🎛️ **三种播放模式**：列表循环 / 单曲循环 / 随机
- 🔊 **音量旋钮**：SVG 270° 弧旋钮
- 📱 **响应式**：桌面 / 移动自适应

## 技术栈

- 纯 HTML + CSS + JavaScript（零运行时依赖）
- Web Audio API（频谱 + 响度检测）
- Canvas 2D（词云 / 频谱绘制）
- 得意黑字体（SmileySans-Oblique）
- 网易云音乐公共 API（GDStudio + injahow 双源）

## 本地预览

```bash
# 方式 1：直接打开
start index.html

# 方式 2：起个本地服务器
python -m http.server 8123
# 然后访问 http://localhost:8123
```

> 用本地服务器可避免部分浏览器的 `file://` 跨域限制（封面图 / 字体加载）。

## 部署到 Vercel

本项目**无需构建命令**，直接把根目录部署上去即可。

### 一键部署

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https://github.com/YOUR_USERNAME/aurum)

### 手动部署（Web）

1. 把项目推到 GitHub / GitLab / Bitbucket
2. 打开 [vercel.com/new](https://vercel.com/new)，导入仓库
3. **框架预设**：选 **"Other"**（不是 Next.js / Vite 等）
4. **构建命令**：留空
5. **输出目录**：留空（默认根目录）
6. 点 **Deploy**，等十几秒就上线

### 手动部署（CLI）

```bash
# 1. 全局安装 Vercel CLI
npm i -g vercel

# 2. 在项目根目录执行
cd Music-2
vercel

# 3. 按提示走（第一次会要求登录/注册）
#    - Scope: 选你的账号
#    - Link to existing project? → No
#    - Project name: aurum（或你喜欢的名字）
#    - Directory: .（当前目录）
#    - Build Settings: 选 "Other"，Build Command 留空，Output Directory 留空

# 4. 部署完成，拿到预览 URL
vercel --prod   # 推到生产环境
```

> ✅ **会推送到 Vercel 的内容**：`index.html`、`assets/`、`README.md`、`.gitignore`
> 
> ❌ **不会推送**：`aurum-tauri/`（桌面壳）、`dist-release/`（exe 产物），已被 `.gitignore` 排除。

## 桌面版（可选）

项目附带 Tauri v2 桌面壳（`aurum-tauri/`），可打包为 Windows exe：

```bash
cd aurum-tauri/src-tauri
cargo tauri build
# 产物在 target/release/aurum.exe + bundle/msi/
```

需要 Rust 工具链 + Tauri CLI，详见 [Tauri 官方文档](https://v2.tauri.app/start/)。

**桌面版特点**：
- 透明无框窗口 + 自定义标题栏（带最小化/最大化/关闭按钮）
- 毛玻璃背景效果
- 程序图标采用 `assets/icon.png`

## 版权

仅供学习交流，音乐版权归原平台所有。
