#!/bin/bash
# native/scripts/build_ios.sh
# iOS 原生库编译脚本

set -e

echo "🔨 开始编译 iOS 原生库..."

# 创建构建目录
BUILD_DIR="$(dirname "$0")/../build/ios"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# CMake 配置（iOS）
cmake ../.. \
    -G "Xcode" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_METAL=ON \
    -DLLAMA_VULKAN=OFF \
    -DLLAMA_BLAS=OFF

# Xcode 构建
echo "🚀 开始编译..."
xcodebuild -project llama.xcodeproj \
    -target edge_llama \
    -configuration Release \
    -sdk iphoneos \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build

# 输出结果
echo ""
echo "✅ iOS 编译完成!"
echo "📦 输出文件：$BUILD_DIR/Release-iphoneos/libllama.a"
echo ""
echo "下一步："
echo "  将 libllama.a 集成到 iOS 工程中"
