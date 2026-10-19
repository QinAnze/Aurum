# 将应用的 QML 扫描限定在 Qt 源码目录，避免遍历部署包和 Node 依赖。 资源、平台依赖和打包钩子由根目录配置完成后再统一结束目标初始化。
qt_add_executable(RhineMusicDatabase WIN32 MACOSX_BUNDLE MANUAL_FINALIZATION ${RHINE_APP_SOURCES})
set_target_properties(RhineMusicDatabase PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set_source_files_properties(qml/Main.qml PROPERTIES QT_RESOURCE_ALIAS Main.qml)
qt_add_qml_module(
    RhineMusicDatabase
    URI
    RhineMusic
    VERSION
    1.0
    OUTPUT_DIRECTORY
    "${CMAKE_BINARY_DIR}/RhineMusic"
    QML_FILES
    qml/Main.qml)

# ---------------------------------------------------------------------------
# Windows 构建后自动部署：双击 exe 就能跑，不需要设置 PATH。
#
# 编译产物本身不含 Qt 运行时 —— Qt6Multimedia / Qt6Quick 等 DLL、platforms 插件、
# QML 导入目录都在 Qt 安装里。上游只在 macOS 的打包流程里做了部署，
# Windows 下必须手动 windeployqt，否则启动就报「找不到 Qt6Multimedia.dll」。
#
# 注意：QML 全部编进资源后 windeployqt 可能扫不全模块，
# 因此再按清单补齐关键 DLL，缺一个都会启动失败。
# ---------------------------------------------------------------------------
if(WIN32)
    get_target_property(_rhine_qmake Qt6::qmake IMPORTED_LOCATION)
    get_filename_component(_rhine_qt_bin "${_rhine_qmake}" DIRECTORY)
    find_program(RHINE_WINDEPLOYQT NAMES windeployqt HINTS "${_rhine_qt_bin}")

    if(RHINE_WINDEPLOYQT)
        add_custom_command(
            TARGET RhineMusicDatabase
            POST_BUILD
            COMMAND "${RHINE_WINDEPLOYQT}" --release --no-translations --compiler-runtime
                    --qmldir "${CMAKE_CURRENT_SOURCE_DIR}/qml" "$<TARGET_FILE:RhineMusicDatabase>"
            COMMENT "windeployqt：部署 Qt 运行时与插件"
            VERBATIM)
        message(STATUS "Windows 部署：使用 ${RHINE_WINDEPLOYQT}")
    else()
        message(WARNING "未找到 windeployqt，产物无法独立运行；请把 Qt 的 bin 加入 PATH")
    endif()

    # windeployqt 只带当前应用类型对应的平台插件（Windows 下是 qwindows），
    # 而 ctest 的离线自检跑在 QT_QPA_PLATFORM=offscreen 上，缺它就整体失败。
    # 这里按 Debug/Release 补齐 offscreen 插件，与 npm 打包脚本的做法一致。
    if(EXISTS "${_rhine_qt_bin}/../plugins/platforms/qoffscreen.dll")
        add_custom_command(
            TARGET RhineMusicDatabase
            POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E make_directory
                    "$<TARGET_FILE_DIR:RhineMusicDatabase>/platforms"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "${_rhine_qt_bin}/../plugins/platforms/qoffscreen.dll"
                    "$<TARGET_FILE_DIR:RhineMusicDatabase>/platforms"
            COMMENT "部署 offscreen 平台插件（ctest 离线自检需要）"
            VERBATIM)
    endif()
    if(EXISTS "${_rhine_qt_bin}/../plugins/platforms/qoffscreend.dll")
        add_custom_command(
            TARGET RhineMusicDatabase
            POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E make_directory
                    "$<TARGET_FILE_DIR:RhineMusicDatabase>/platforms"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "${_rhine_qt_bin}/../plugins/platforms/qoffscreend.dll"
                    "$<TARGET_FILE_DIR:RhineMusicDatabase>/platforms"
            COMMENT "部署 offscreen 平台插件（Debug，ctest 离线自检需要）"
            VERBATIM)
    endif()

    foreach(_rhine_dll Qt6Core Qt6Gui Qt6Qml Qt6QmlMeta Qt6QmlModels Qt6QmlWorkerScript
                      Qt6Quick Qt6Quick3DUtils Qt6Network Qt6Multimedia Qt6Svg Qt6OpenGL)
        if(EXISTS "${_rhine_qt_bin}/${_rhine_dll}.dll")
            add_custom_command(
                TARGET RhineMusicDatabase
                POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_rhine_qt_bin}/${_rhine_dll}.dll"
                        "$<TARGET_FILE_DIR:RhineMusicDatabase>"
                COMMENT "补齐 ${_rhine_dll}.dll"
                VERBATIM)
        endif()
    endforeach()

    # 资源（字体/模型/光照/Node 桥接）用目录联接指向 output/resources：
    # 直接拷 200MB+，每次构建都拷不划算。具体逻辑在 scripts/link_resources.cmake，
    # 走 CMake 脚本传参可以避开 shell 引号被拆坏的问题。
    if(EXISTS "${CMAKE_SOURCE_DIR}/output/resources/slots.json")
        add_custom_command(
            TARGET RhineMusicDatabase
            POST_BUILD
            COMMAND
                ${CMAKE_COMMAND} "-DSRC=${CMAKE_SOURCE_DIR}/output/resources"
                "-DDEST=$<TARGET_FILE_DIR:RhineMusicDatabase>/resources" -P
                "${CMAKE_SOURCE_DIR}/scripts/link_resources.cmake"
            COMMENT "链接 resources 目录"
            VERBATIM)
    else()
        message(STATUS "提示：output/resources 不存在，先跑 scripts/export-assets.py 并拷贝字体等资源")
    endif()
endif()
