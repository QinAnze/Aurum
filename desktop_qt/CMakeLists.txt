cmake_minimum_required(VERSION 3.24)
project(
    RhineMusicDatabase
    VERSION 0.4.0
    LANGUAGES CXX)
set(RHINE_APPLICATION_ID "rhine.music.database")
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(
    Qt6 6.8 REQUIRED
    COMPONENTS Core
               Gui
               Qml
               Quick
               Network
               Concurrent
               ShaderTools
               Multimedia)
if(NOT TARGET Qt6::GuiPrivate)
    find_package(Qt6GuiPrivate REQUIRED)
endif()
if(NOT TARGET Qt6::MultimediaPrivate)
    find_package(Qt6MultimediaPrivate REQUIRED)
endif()
qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 NEW)
# 自维护源码和锁定的二维码库构成独立应用目标。
set(RHINE_APP_SOURCES
    Qt/src/AudioPlayer.cpp
    Qt/src/AudioPlayer.h
    Qt/src/AppStorage.cpp
    Qt/src/AppStorage.h
    Qt/src/DiscGeometry.cpp
    Qt/src/DiscGeometry.h
    Qt/src/FrameProfiler.cpp
    Qt/src/FrameProfiler.h
    Qt/src/NativeCards.cpp
    Qt/src/NativeCards.h
    Qt/src/NativePicking.cpp
    Qt/src/NativePicking.h
    Qt/src/UiMotion.cpp
    Qt/src/UiMotion.h
    Qt/tests/UiChecks.cpp
    Qt/tests/NativeHostChecks.cpp
    Qt/tests/NativeMusicChecks.cpp
    Qt/src/Icon.cpp
    Qt/src/main.cpp
    Qt/src/Host.cpp
    Qt/src/Host.h
    Qt/src/MusicApi.cpp
    Qt/src/MusicApi.h
    Qt/src/LyricsController.cpp
    Qt/src/LyricsController.h
    Qt/src/MusicPlayer.cpp
    Qt/src/MusicPlayer.h
    Qt/src/MusicData.cpp
    Qt/src/MusicData.h
    Qt/src/MusicLibrary.cpp
    Qt/src/MusicLibrary.h
    Qt/src/NativeHud.h
    Qt/src/NativeHud.cpp
    Qt/src/NativeHudController.cpp
    Qt/src/NativeHudMusic.cpp
    Qt/src/NativeHudInput.cpp
    Qt/src/NativeHudDetail.cpp
    Qt/src/NativeHudPlayer.cpp
    Qt/src/NativeHudLibrary.cpp
    Qt/src/NativeHudModal.cpp
    Qt/src/NativeHudBoot.cpp
    Qt/src/SceneTypes.h
    Qt/src/SceneAppearance.h
    Qt/src/SceneAppearance.cpp
    Qt/src/NativeApplication.h
    Qt/src/NativeApplication.cpp
    Qt/src/NativeScene.h
    Qt/src/NativeScene.cpp
    Qt/src/NativeSceneUpdate.cpp
    Qt/src/NativeSceneCamera.cpp
    Qt/src/NativeSceneFrame.cpp
    Qt/src/NativeSceneInput.cpp
    Qt/src/NativeViewer.h
    Qt/src/NativeViewer.cpp
    Qt/src/SceneMath.h
    Qt/src/SceneMath.cpp
    Qt/src/SceneDrag.h
    Qt/src/SceneDrag.cpp
    Qt/src/SceneMotion.h
    Qt/src/SceneMotion.cpp
    Qt/src/BootTimeline.cpp
    Qt/src/MusicDirectory.cpp
    Qt/src/MusicAccount.cpp
    Qt/src/MusicMutation.cpp
    Qt/src/MusicDiscover.cpp
    Qt/src/MusicDiscover.h
    Qt/src/Platform.cpp
    Qt/src/Engine.cpp
    Qt/src/Engine.h
    Qt/src/Hud.cpp
    Qt/src/Hud.h
    Qt/src/RhiScene.cpp
    Qt/src/RhiScene.h
    Qt/src/Glyphs.cpp
    Qt/src/Glyphs.h
    vendor/qrcodegen/qrcodegen.cpp)
list(TRANSFORM RHINE_APP_SOURCES PREPEND "${CMAKE_CURRENT_SOURCE_DIR}/")
if(APPLE)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
endif()
# 原生业务和场景由应用与独立回归共用，测试不需要复制整套源码目标。
set(RHINE_CORE_SOURCES ${RHINE_APP_SOURCES})
list(FILTER RHINE_CORE_SOURCES EXCLUDE REGEX
     "/(main|Engine|Icon|RhiScene|Hud|FrameProfiler)\\.(cpp|h)$|/tests/")
list(REMOVE_ITEM RHINE_APP_SOURCES ${RHINE_CORE_SOURCES})
add_library(RhineCore STATIC ${RHINE_CORE_SOURCES})
target_include_directories(
    RhineCore
    PUBLIC Qt/src
    PRIVATE vendor/qrcodegen)
target_compile_definitions(RhineCore PUBLIC RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}")
target_link_libraries(
    RhineCore
    PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::Concurrent Qt6::Multimedia
    PRIVATE Qt6::MultimediaPrivate)
add_subdirectory(Qt)
target_link_libraries(RhineMusicDatabase PRIVATE RhineCore)
set_source_files_properties(Qt/qml/Main.qml TARGET_DIRECTORY RhineMusicDatabase PROPERTIES QT_RESOURCE_ALIAS
                                                                                           Main.qml)
target_include_directories(RhineMusicDatabase PRIVATE vendor/qrcodegen Qt/src)
qt_add_resources(
    RhineMusicDatabase
    "rhine_animation"
    PREFIX
    "/animation"
    BASE
    "Assets/animation"
    FILES
    Assets/animation/boot-tracks.json)
qt_add_resources(
    RhineMusicDatabase
    "rhine_icons"
    PREFIX
    "/icons"
    BASE
    "Assets/icons"
    FILES
    Assets/icons/icon-16.png
    Assets/icons/icon-32.png
    Assets/icons/icon-64.png
    Assets/icons/icon-128.png
    Assets/icons/icon-256.png
    Assets/icons/icon-512.png
    Assets/icons/icon-1024.png)
# 着色器按原通道顺序打包，所有后端使用同一份公式。
qt_add_shaders(
    RhineMusicDatabase
    "rhine_shaders"
    PREFIX
    "/shaders"
    BASE
    "Qt/shaders"
    GLSL
    "150,300es"
    HLSL
    50
    MSL
    12
    FILES
    Qt/shaders/geometry.vert
    Qt/shaders/shadow.vert
    Qt/shaders/shadow.frag
    Qt/shaders/surface.frag
    Qt/shaders/normal.frag
    Qt/shaders/quad.vert
    Qt/shaders/aoFragment.frag
    Qt/shaders/blurAO.frag
    Qt/shaders/combineAO.frag
    Qt/shaders/bokehFragment.frag
    Qt/shaders/finalFragment.frag)
target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}"
                                                      $<$<CONFIG:Debug>:QT_QML_DEBUG>)
target_link_libraries(
    RhineMusicDatabase
    PRIVATE Qt6::Core
            Qt6::Gui
            Qt6::GuiPrivate
            Qt6::Qml
            Qt6::Quick
            Qt6::Network
            Qt6::Concurrent
            Qt6::Multimedia)
# 平台分支只处理原生能力、部署身份及链接依赖。
if(APPLE)
    target_sources(RhineCore PRIVATE Qt/src/Platform.mm)
    target_link_libraries(RhineCore PRIVATE "-framework Security" "-framework AppKit"
                                            "-framework MediaPlayer")
    target_compile_options(RhineCore PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    set_target_properties(
        RhineMusicDatabase
        PROPERTIES MACOSX_BUNDLE_GUI_IDENTIFIER ${RHINE_APPLICATION_ID}
                   MACOSX_BUNDLE_BUNDLE_NAME "RHINE MUSIC DATABASE"
                   MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Qt/Info.plist.in")
elseif(WIN32)
    configure_file(Qt/WindowsIcon.rc.in "${CMAKE_CURRENT_BINARY_DIR}/WindowsIcon.rc" @ONLY)
    target_sources(RhineMusicDatabase PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/WindowsIcon.rc")
    target_sources(RhineCore PRIVATE Qt/src/PlatformWindows.cpp)
    target_link_libraries(RhineCore PRIVATE crypt32 shell32 user32 windowsapp runtimeobject
                                            Qt6::MultimediaPrivate)
    target_compile_options(RhineMusicDatabase PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
    target_compile_options(RhineCore PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
else()
    message(FATAL_ERROR "Supported desktop platforms are macOS and Windows")
endif()
# Qt Creator 的普通构建也交付完整应用，不能依赖运行目录里的 output/resources。
option(RHINE_PACKAGE_APP "Package resources and Qt libraries after a macOS CMake build" ON)
if(APPLE AND RHINE_PACKAGE_APP)
    find_program(RHINE_NPM_EXECUTABLE NAMES npm REQUIRED)
    get_filename_component(RHINE_QT_KIT "${Qt6_DIR}/../../.." ABSOLUTE)
    # 脚本、字体和场景数据改变时重新链接，确保 POST_BUILD 重新生成部署资源。
    file(
        GLOB_RECURSE
        RHINE_RESOURCE_INPUTS
        CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/Resources/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/client/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/Assets/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/*")
    list(
        APPEND RHINE_RESOURCE_INPUTS "${CMAKE_CURRENT_SOURCE_DIR}/package.json"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/worker.cjs" "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/qq.cjs"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/package-lock.json")
    set_property(
        TARGET RhineMusicDatabase
        APPEND
        PROPERTY LINK_DEPENDS ${RHINE_RESOURCE_INPUTS})
    add_custom_command(
        TARGET RhineMusicDatabase
        POST_BUILD
        COMMAND "${RHINE_NPM_EXECUTABLE}" run package:cmake -- "$<TARGET_BUNDLE_DIR:RhineMusicDatabase>"
                "${RHINE_QT_KIT}" "$<CONFIG>"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Packaging standalone music panel resources and Qt runtime"
        VERBATIM)
endif()
qt_finalize_executable(RhineMusicDatabase)
enable_testing()
qt_add_executable(RhineSceneMotionRegression Qt/tests/SceneMotionChecks.cpp Qt/src/SceneMotion.cpp
                  Qt/src/BootTimeline.cpp Qt/src/SceneMath.cpp Qt/src/SceneDrag.cpp)
target_include_directories(RhineSceneMotionRegression PRIVATE Qt/src)
target_compile_definitions(RhineSceneMotionRegression PRIVATE RHINE_SCENE_MOTION_TEST_MAIN)
target_link_libraries(RhineSceneMotionRegression PRIVATE Qt6::Core)
qt_add_resources(
    RhineSceneMotionRegression
    "scene_motion_tracks"
    PREFIX
    "/animation"
    BASE
    "Assets/animation"
    FILES
    Assets/animation/boot-tracks.json)
if(MSVC)
    target_compile_options(RhineSceneMotionRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_scene_motion_regression
         COMMAND RhineSceneMotionRegression "${CMAKE_CURRENT_SOURCE_DIR}/Qt/tests/fixtures/scene-motion.qz")
qt_add_executable(RhineUiMotionRegression Qt/tests/UiMotionRegression.cpp Qt/src/UiMotion.cpp)
target_include_directories(RhineUiMotionRegression PRIVATE Qt/src)
target_link_libraries(RhineUiMotionRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineUiMotionRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_ui_motion_regression COMMAND RhineUiMotionRegression
                                              "${CMAKE_CURRENT_SOURCE_DIR}/Qt/tests/fixtures/ui-motion.qz")
qt_add_executable(RhinePlatformRegression Qt/tests/PlatformRegression.cpp Qt/src/AppStorage.cpp
                  Qt/src/AudioPlayer.cpp)
target_include_directories(RhinePlatformRegression PRIVATE Qt/src)
target_link_libraries(RhinePlatformRegression PRIVATE Qt6::Core Qt6::Gui Qt6::Multimedia
                                                      Qt6::MultimediaPrivate)
if(WIN32)
    target_sources(RhinePlatformRegression PRIVATE Qt/src/PlatformWindows.cpp)
    target_link_libraries(
        RhinePlatformRegression
        PRIVATE Qt6::Qml
                Qt6::Network
                crypt32
                shell32
                user32
                windowsapp
                runtimeobject)
    target_compile_definitions(RhinePlatformRegression PRIVATE RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}")
    target_compile_options(RhinePlatformRegression PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
endif()
add_test(NAME qt_platform_regression COMMAND RhinePlatformRegression
                                             "${CMAKE_CURRENT_BINARY_DIR}/platform-regression")
set_tests_properties(qt_platform_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
add_test(NAME qt_offline COMMAND RhineMusicDatabase --self-test)
set_tests_properties(
    qt_offline
    PROPERTIES ENVIRONMENT
               "QT_QPA_PLATFORM=offscreen;RHINE_RESOURCES=${CMAKE_CURRENT_SOURCE_DIR}/output/resources")

qt_add_executable(RhineNativeSceneRegression Qt/tests/NativeSceneChecks.cpp)
target_compile_definitions(RhineNativeSceneRegression PRIVATE RHINE_SCENE_REGRESSION_TEST_MAIN)
target_link_libraries(RhineNativeSceneRegression PRIVATE RhineCore)
qt_add_resources(
    RhineNativeSceneRegression
    "native_scene_tracks"
    PREFIX
    "/animation"
    BASE
    "Assets/animation"
    FILES
    Assets/animation/boot-tracks.json)
if(MSVC)
    target_compile_options(RhineNativeSceneRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_native_scene_regression
         COMMAND RhineNativeSceneRegression "${CMAKE_CURRENT_SOURCE_DIR}/output/resources"
                 "${CMAKE_CURRENT_SOURCE_DIR}/Qt/tests/fixtures/scene-frame.qz")

qt_add_executable(RhineNativeHudRegression Qt/tests/NativeHudChecks.cpp)
target_compile_definitions(RhineNativeHudRegression PRIVATE RHINE_HUD_REGRESSION_TEST_MAIN)
target_link_libraries(RhineNativeHudRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhineNativeHudRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_native_hud_regression
         COMMAND RhineNativeHudRegression "${CMAKE_CURRENT_SOURCE_DIR}/output/resources"
                 "${CMAKE_CURRENT_SOURCE_DIR}/Qt/tests/fixtures/hud-panels.qz")
set_tests_properties(qt_native_hud_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# ---- Aurum 视觉数据通路：离线自检（不依赖声卡与 QML）----
qt_add_executable(RhineAurumVisualRegression Qt/tests/AurumVisualChecks.cpp Qt/src/aurum/FftTap.cpp
                  Qt/src/aurum/AurumVisual.cpp)
target_include_directories(RhineAurumVisualRegression PRIVATE Qt/src Qt/src/aurum)
target_link_libraries(RhineAurumVisualRegression PRIVATE Qt6::Core Qt6::Multimedia)
if(MSVC)
    target_compile_options(RhineAurumVisualRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_aurum_visual_regression COMMAND RhineAurumVisualRegression)
