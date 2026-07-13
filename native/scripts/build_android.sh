#!/bin/bash
# native/scripts/build_android.sh
# Android 原生库编译脚本

set -e

echo "🔨 开始编译 Android 原生库..."

# 检查环境变量
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -n "$ANDROID_SDK_ROOT" ]; then
        export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/26.1.10909125"
    else
        echo "❌ 错误：请设置 ANDROID_NDK_HOME 或 ANDROID_SDK_ROOT 环境变量"
        exit 1
    fi
fi

echo "✅ NDK 路径：$ANDROID_NDK_HOME"

# 创建构建目录
BUILD_DIR="$(dirname "$0")/../build/android"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# CMake 配置
cmake ../.. \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-26 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_METAL=OFF \
    -DLLAMA_VULKAN=OFF \
    -DLLAMA_BLAS=OFF

# 编译
echo "🚀 开始编译..."
ninja

# 输出结果
echo ""
echo "✅ Android arm64-v8a 编译完成!"
echo "📦 输出文件：$BUILD_DIR/libllama.so"
echo ""
echo "下一步："
echo "  将 libllama.so 复制到 android/app/src/main/jniLibs/arm64-v8a/"
