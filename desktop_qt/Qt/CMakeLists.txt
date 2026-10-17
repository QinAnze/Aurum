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
