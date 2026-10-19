# 在构建目录里建一个指向 output/resources 的「目录联接」（Windows junction）。
#
# 为什么不直接 copy：resources 含 Node 桥接依赖，200MB+，每次构建都拷不划算。
# 为什么不在 add_custom_command 里直接写 cmd /c mklink：VERBATIM 之后嵌套引号
# 会被拆坏，报「文件名、目录名或卷标语法不正确」。交给 CMake 脚本传参最稳。
#
# 用法：cmake -DSRC=<源目录> -DDEST=<联接路径> -P link_resources.cmake

if(NOT DEFINED SRC OR NOT DEFINED DEST)
    message(FATAL_ERROR "需要 -DSRC=<resources 源目录> -DDEST=<联接路径>")
endif()

# 源资源还没准备（没跑 export-assets）就安静跳过，不阻断构建
if(NOT EXISTS "${SRC}/slots.json")
    message(STATUS "跳过 resources 联接：${SRC}/slots.json 不存在")
    return()
endif()

# 已经建好就什么都不做（可重复构建）
if(EXISTS "${DEST}/slots.json")
    return()
endif()

# 用 PowerShell 的 New-Item -ItemType Junction：
# `cmd /c mklink /J` 通过 CMake 传参时引号容易被拆坏，报「语法不正确」。
execute_process(
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass -Command
            "New-Item -ItemType Junction -Path '${DEST}' -Target '${SRC}' -ErrorAction Stop | Out-Null"
    RESULT_VARIABLE result
    OUTPUT_QUIET
    ERROR_QUIET)

if(result EQUAL 0)
    message(STATUS "已建立 resources 目录联接：${DEST} -> ${SRC}")
else()
    message(WARNING "resources 目录联接创建失败（result=${result}）。"
                    "可手动执行（PowerShell）："
                    "New-Item -ItemType Junction -Path '${DEST}' -Target '${SRC}'")
endif()
