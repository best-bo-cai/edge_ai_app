cmake_minimum_required(VERSION 3.22)
project(edge_llama C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 编译选项（架构相关优化交给 llama.cpp/ggml 自身的 arm64 配置，避免全局 -march 冲突）
# 注意：不能用 -fvisibility=hidden，会隐藏 edge_llama_* 导出符号
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3")

if(ANDROID)
    add_definitions(-DANDROID)
endif()

# 是否使用 dummy 桩：
# 1. 非 arm64 的 Android ABI（llama.cpp 依赖 64 位原子操作，armeabi-v7a 无法编译；
#    模拟器 x86_64 等也无本地推理意义）
# 2. third_party/llama.cpp 未克隆（工程可编译，推理不可用）
# 桩库直接产出 libllama.so：edge_llama_load_model 恒返回 NULL，App 侧自动降级 Mock。
# 注意：桩分支不能编译 llama_wrapper.cpp——它引用真实 llama.cpp 的 API 符号。
set(USE_DUMMY OFF)
if(ANDROID AND NOT ANDROID_ABI STREQUAL "arm64-v8a")
    set(USE_DUMMY ON)
    message(STATUS "ABI ${ANDROID_ABI} unsupported by llama.cpp, using dummy stub")
elseif(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/CMakeLists.txt")
    set(USE_DUMMY ON)
    message(WARNING "llama.cpp not found. Please clone it to native/third_party:")
    message("  cd native/third_party && git clone --depth 1 https://github.com/ggerganov/llama.cpp.git")
    message("  (国内网络可用镜像: git clone --depth 1 https://gh-proxy.com/https://github.com/ggerganov/llama.cpp.git)")
endif()

# 桥接库（输出 libedgellama.so，由 Dart 侧 DynamicLibrary.open 加载）
if(USE_DUMMY)
    add_library(edge_llama SHARED dummy_llama.cpp)
    target_include_directories(edge_llama PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
else()
    # 引入 llama.cpp 源码（Git 浅克隆至 native/third_party/llama.cpp）
    # 经 Gradle externalNativeBuild 集成时无需手动跑 scripts/build_android.sh
    # 作为子目录引入时 LLAMA_STANDALONE=OFF：tools/tests/examples 自动关闭
    message(STATUS "Found llama.cpp in third_party")
    add_subdirectory(third_party/llama.cpp llama.cpp)

    add_library(edge_llama SHARED llama_wrapper.cpp)
    target_link_libraries(edge_llama PRIVATE llama log)
    target_include_directories(edge_llama PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/include
    )
endif()

# 桥接库输出 libedgellama.so：不能叫 libllama.so——llama.cpp 以共享库
# 方式构建时会产出同名 libllama.so，两者互相覆盖导致 edge_llama_* 符号丢失
set_target_properties(edge_llama PROPERTIES
    OUTPUT_NAME "edgellama"
)

if(USE_DUMMY)
    set(LLAMA_MODE_DESC "dummy 桩（Mock 模式）")
else()
    set(LLAMA_MODE_DESC "真实推理")
endif()

message(STATUS "")
message(STATUS "=== Edge Llama 配置 ===")
message(STATUS "构建类型：${CMAKE_BUILD_TYPE}")
message(STATUS "目标平台：${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "llama.cpp：${LLAMA_MODE_DESC}")
message(STATUS "========================")
message(STATUS "")
