#!/usr/bin/env python3
"""验证部署后的 Qt 应用，不读取用户凭据或访问网易云。"""
import json
import plistlib
import re
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
# 根据产物类型选择静态审计规则，允许在构建主机检查另一平台的部署目录。
mac = app.suffix.lower() == ".app"
resources = app / ("Contents/Resources" if mac else "resources")
executable = app / ("Contents/MacOS/RhineMusicDatabase" if mac else "RHINE MUSIC DATABASE.exe")
assert executable.is_file()
for pattern in (
    "diagnose-windows-audio*",
    "windows-audio-snapshot.ps1",
    "AudioRouteProbe*",
    "RhinePlatformRegression*",
):
    assert not list(app.rglob(pattern)), "Local diagnostic or regression tool entered release package"
assert not re.search(
    rb"cc\.[a-z]+\.rhine\.(?:native-panel|music)", executable.read_bytes()
), "Legacy runtime namespace"
for name in [
    "slots.json",
    "scene-fixture.json",
    "room-pmrem.bin",
    "misans-glyphs.json",
    "LICENSE",
    "NOTICE",
]:
    assert (resources / name).is_file(), name
for name in (
    "runtime.js",
    "timeline.js",
    "qt-logic.js",
    "archive-cassette-geometry.json",
    "archive-assembly-geometry.json",
):
    assert not (resources / name).exists(), "Retired script or geometry copy entered package: " + name
fixture = json.loads((resources / "scene-fixture.json").read_text(encoding="utf-8"))
assert (
    len(fixture["frame"]["view"]) == 16 and len(fixture["frame"]["projection"]) == 16 and fixture["rays"]
), "Invalid offline scene fixture"
if mac:
    with (app / "Contents/Info.plist").open("rb") as file:
        identity = plistlib.load(file)
    assert identity["CFBundleIdentifier"] == "rhine.music.database", "Wrong system application identity"
    assert identity["CFBundleExecutable"] == "RhineMusicDatabase"
    libraries = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    assert "QtQuick" in libraries and "QtQml" in libraries
    assert "libswift" not in libraries.lower(), "Swift runtime dependency found"
    assert not any(p.suffix == ".swift" for p in app.rglob("*") if p.is_file())
    assert not any(p.name in {"node_modules", ".git", ".DS_Store"} for p in app.iterdir())
    assert not any(
        "/Users/" in line or "/opt/homebrew/" in line for line in libraries.splitlines()[1:]
    ), "Undeployed Qt dependency"
    load_commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    search_paths = [line.strip() for line in load_commands.splitlines() if line.strip().startswith("path ")]
    assert not any(
        "/Users/" in line or "/opt/homebrew/" in line for line in search_paths
    ), "Local binary search path"
    conf = (resources / "qt.conf").read_text(encoding="utf-8")
    assert "/Users/" not in conf and "/opt/homebrew/" not in conf, "Local QML search path"
    assert not (app / "Contents/PlugIns/sqldrivers").exists(), "Unneeded database plugins"
    assert (
        app / "Contents/PlugIns/multimedia/libffmpegmediaplugin.dylib"
    ).is_file(), "Missing FFmpeg backend"
    for library in ("avcodec", "avformat", "avutil", "swresample", "swscale"):
        assert list((app / "Contents/Frameworks").glob(f"lib{library}.*.dylib")), f"Missing {library} runtime"
    audio_libraries = list((app / "Contents/Frameworks").glob("lib*.dylib"))
    for binary in list((app / "Contents/PlugIns").rglob("*.dylib")) + audio_libraries:
        dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        assert not any(
            "/Users/" in line or "/Applications/Postgres.app/" in line or "/opt/homebrew/" in line
            for line in dependencies.splitlines()
            if line.startswith("\t")
        ), str(binary)
else:
    debug = (app / "Qt6Cored.dll").is_file()
    suffix = "d.dll" if debug else ".dll"
    for name in ("msvcp140", "vcruntime140", "vcruntime140_1"):
        assert (app / (name + suffix)).is_file(), "Missing local MSVC runtime: " + name
    assert not list(app.glob("vc_redist*.exe")), "Portable package must not require a runtime installer"
    assert (app / "Qt6Quick.dll").is_file() or (app / "Qt6Quickd.dll").is_file()
    assert (app / "Qt6Multimedia.dll").is_file() or (
        app / "Qt6Multimediad.dll"
    ).is_file(), "Missing Qt audio runtime"
    assert (app / "multimedia/windowsmediaplugin.dll").is_file() or (
        app / "multimedia/windowsmediaplugind.dll"
    ).is_file(), "Missing Windows native compatibility audio backend"
    assert (app / "multimedia/ffmpegmediaplugin.dll").is_file() or (
        app / "multimedia/ffmpegmediaplugind.dll"
    ).is_file(), "Missing default FFmpeg audio backend"
    for library in ("avcodec", "avformat", "avutil", "swresample", "swscale"):
        assert list(app.glob(library + "-*.dll")), "Missing FFmpeg runtime: " + library
    assert (app / "platforms/qwindows.dll").is_file() or (app / "platforms/qwindowsd.dll").is_file()
    assert (app / "platforms/qoffscreen.dll").is_file() or (
        app / "platforms/qoffscreend.dll"
    ).is_file(), "Missing offscreen test platform plugin"
    assert (resources / "MusicBridge/node.exe").is_file()
    assert (app / "qml").is_dir()
    assert not list(app.rglob("*.swift"))
    assert not (app / "sqldrivers").exists()
result = {"qt_deployed": True, "swift_runtime_required": False, "locked_music_bridge": True}
pathlib.Path("output/qt-package-audit.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result))
