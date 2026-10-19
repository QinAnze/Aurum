# desktop_qt 本地构建

Qt6 / C++20 桌面端。构建产物**自动完成 Qt 运行时部署**，双击 exe 即可运行，
不需要手动设 `PATH` 或另跑 `windeployqt`。

## 依赖

| 项 | 说明 |
| --- | --- |
| Qt | 6.8+，需要 **Shader Tools** 与 **私有头文件**（GuiPrivate / MultimediaPrivate）。官方安装器选 `msvc2022_64` 或 `mingw_64` 均可 |
| CMake | 3.24+ |
| 编译器 | MSVC 2022 或 MinGW-w64（GCC 13） |
| Node | 20+（音乐桥接运行时，构建资源时用） |
| Python | 3.9+（`scripts/export-assets.py` 导出 3D 资源，仅标准库） |

> MinGW 构建时 `Qt/src/PlatformWindows.cpp` 会把 C++/WinRT（任务栏媒体控制）
> 降级为空实现 —— 该能力只有 MSVC + Windows SDK 的 cppwinrt 才提供，
> 面板内播放不受影响。官方发布建议用 MSVC。

## 构建

```bash
cmake -S . -B output/qt-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/path/to/Qt/6.8.x/mingw_64 \
  -DCMAKE_CXX_COMPILER=/path/to/mingw/bin/g++.exe

cmake --build output/qt-build --parallel
```

构建结束后 `output/qt-build/` 里会有：

- `RhineMusicDatabase.exe`
- `Qt6*.dll`（含 **Qt6Multimedia / Qt6Quick**）、`platforms/`、`imageformats/`、`multimedia/`、`qml/`
- `resources/` —— 指向 `output/resources` 的**目录联接**（避免每次构建拷 200MB）

## 资源准备（首次）

`resources/` 里的内容是运行时资源，需先准备一次：

```bash
python scripts/export-assets.py            # 3D 模型 → output/resources/*.bin
cp Assets/fonts/* output/resources/        # 字体
cp Assets/lighting/*.bin output/resources/
cp Assets/room-pmrem.bin output/resources/
# 音乐桥接（网易云 / QQ / 酷狗）
cp -r MusicBridge/* output/resources/MusicBridge/
cp <node>/node.exe output/resources/MusicBridge/
cd output/resources/MusicBridge && npm ci --omit=dev
```

没准备 `output/resources` 时构建不会失败，只是程序启动后找不到字体/模型
（控制台会提示「先跑 export-assets」）。

## 为什么需要自动部署

编译产物本身**不含** Qt 运行时。上游只在 macOS 的打包流程里做了部署，
Windows 下必须 `windeployqt`，否则启动直接报
「找不到 Qt6Multimedia.dll / Qt6Quick.dll」。

现在 `Qt/CMakeLists.txt` 在 POST_BUILD 里：

1. 跑 `windeployqt --release --qmldir Qt/qml`（部署插件与 QML 导入目录）；
2. 按固定清单**补齐**关键 DLL —— QML 全部编进资源后 windeployqt 偶尔会漏扫模块；
3. 用 `scripts/link_resources.cmake` 建 resources 目录联接。

> 目录联接为什么不用 `cmd /c mklink`：经 CMake `VERBATIM` 传参后嵌套引号会被拆坏，
> 报「文件名、目录名或卷标语法不正确」。改用 PowerShell 的
> `New-Item -ItemType Junction`，走 `execute_process` 传参，稳定。
