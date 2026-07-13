cmake_minimum_required(VERSION 3.22)
project(edge_llama C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 编译选项
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -fvisibility=hidden")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -fvisibility=hidden")

# Android 特定优化
if (ANDROID)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8-a+fp16")
    add_definitions(-DANDROID)
endif()

# iOS 特定配置
if (CMAKE_SYSTEM_NAME MATCHES "iOS")
    add_definitions(-DGUILD_USE_METAL)
    add_definitions(-DGGML_METAL)
endif()

# 引入 llama.cpp 源码
# 注意：需要先克隆 llama.cpp 到 third_party 目录
if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp")
    message(STATUS "Found llama.cpp in third_party")
    add_subdirectory(third_party/llama.cpp llama.cpp)
else()
    message(WARNING "llama.cpp not found. Please clone it to third_party/llama.cpp")
    message("  cd third_party && git clone https://github.com/ggerganov/llama.cpp.git")
    
    # MVP 版本：创建模拟库以便编译通过
    add_library(llama STATIC dummy_llama.cpp)
    target_include_directories(llama PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
endif()

# 桥接库
add_library(edge_llama SHARED llama_wrapper.cpp)

target_link_libraries(edge_llama PRIVATE llama)

target_include_directories(edge_llama PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp
)

# 设置输出名称
set_target_properties(edge_llama PROPERTIES
    OUTPUT_NAME "llama"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# 打印配置信息
message(STATUS "")
message(STATUS "=== Edge Llama 配置 ===")
message(STATUS "构建类型：${CMAKE_BUILD_TYPE}")
message(STATUS "目标平台：${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "C++ 编译器：${CMAKE_CXX_COMPILER}")
message(STATUS "========================")
message(STATUS "")
