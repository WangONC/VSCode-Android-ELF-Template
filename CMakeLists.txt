cmake_minimum_required(VERSION 3.22.1)

# 设置 Android NDK 路径
set(ANDROID_NDK_HOME "<NDK_PATH>")
# 设置 CMake Toolchain 文件路径
set(CMAKE_TOOLCHAIN_FILE "${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")
# 设置编译器路径
set(CMAKE_C_COMPILER "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang.cmd")
set(CMAKE_CXX_COMPILER "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang++.cmd")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

project(vtouchtest)

include_directories(".")

# 添加头文件路径
include_directories(include)
include_directories(${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/include/c++/v1) # c++标准头文件
include_directories(${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/windows-x86_64/lib/clang/18/include) # clang的头文件
# 架构特定的头文件
if(ANDROID_ABI STREQUAL "arm64-v8a")
    include_directories(${ANDROID_SYSROOT}/usr/include/aarch64-linux-android)
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    include_directories(${ANDROID_SYSROOT}/usr/include/arm-linux-androideabi)
elseif(ANDROID_ABI STREQUAL "x86_64")
    include_directories(${ANDROID_SYSROOT}/usr/include/x86_64-linux-android)
elseif(ANDROID_ABI STREQUAL "x86")
    include_directories(${ANDROID_SYSROOT}/usr/include/i686-linux-android)
elseif(ANDROID_ABI STREQUAL "riscv64")
    include_directories(${ANDROID_SYSROOT}/usr/include/riscv64-linux-android)
endif()
include_directories(${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/include) # 系统头文件

# 收集源文件
file(GLOB_RECURSE SOURCE_FILES "src/*.cpp" "src/*.c")

# 创建可执行文件
add_executable(${CMAKE_PROJECT_NAME} ${SOURCE_FILES})

# 依赖库，按需添加
target_link_libraries(${CMAKE_PROJECT_NAME} "log")
target_link_libraries(${CMAKE_PROJECT_NAME} "z")
target_link_libraries(${CMAKE_PROJECT_NAME} "dl")
target_link_libraries(${CMAKE_PROJECT_NAME} "m")


# 配置文件后缀
if(CMAKE_HOST_WIN32)
    set(SCRIPT_EXT ".ps1")
    set(SCRIPT_CMD powershell)
    set(SCRIPT_ARGS -ExecutionPolicy Bypass -File)
else()
    set(SCRIPT_EXT ".sh") 
    set(SCRIPT_PREFIX "sh")
endif()

# 配置设备序列号（按需配置）
set(DEVICE_SERIAL "") # 设备序列号，默认为空字符串，表示使用默认设备，需要由多个设备时可以设置为特定设备的序列号

# 获取目标文件的路径 - 修复的部分
set(TARGET_NAME ${CMAKE_PROJECT_NAME})  # 确保这是您的实际目标名称

# 仅部署到设备
add_custom_target(deploy
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "$<TARGET_FILE:${TARGET_NAME}>"
            "/data/local/tmp" 
            "${DEVICE_SERIAL}" 
            "-Deploy"
    DEPENDS vtouchtest
    COMMENT "部署到设备(不执行)"
    VERBATIM
)

# 以普通权限执行
add_custom_target(run
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "$<TARGET_FILE:${TARGET_NAME}>"
            "/data/local/tmp" 
            "${DEVICE_SERIAL}" 
            "-Run"
    DEPENDS vtouchtest
    COMMENT "在设备中执行"
    VERBATIM
)

# 以root权限执行
add_custom_target(run_as_root
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "$<TARGET_FILE:${TARGET_NAME}>"
            "/data/local/tmp" 
            "${DEVICE_SERIAL}" 
            "-Run" 
            "-Root"
    DEPENDS vtouchtest
    COMMENT "在设备中以root权限执行"
    VERBATIM
)

# 启动lldb-server
add_custom_target(start_lldb
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "" 
            "/data/local/tmp" 
            "${DEVICE_SERIAL}" 
            "-StartLldb"
    COMMENT "Starting LLDB server on device"
    VERBATIM
)


# root权限启动lldb-server
add_custom_target(start_lldb_root
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "" 
            "/data/local/tmp" 
            "${DEVICE_SERIAL}" 
            "-StartLldb"
            "-Root"
    COMMENT "Starting LLDB server with root privileges"
    VERBATIM
)

# 停止lldb-server
add_custom_target(stop_lldb
    COMMAND ${SCRIPT_CMD} ${SCRIPT_ARGS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/deploy${SCRIPT_EXT}" 
            "" 
            "/data/local/tmp" 
            "${DEVICE_SERIAL}"
            "-StopLldb"
    COMMENT "Stopping LLDB server on device"
    VERBATIM
)
