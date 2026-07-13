#!/bin/bash
# 下载 Qwen2.5-0.5B-Instruct 模型脚本
# 使用方法：./download_model.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/../assets/models"

echo "🚀 LocalChat MVP - 模型下载脚本"
echo "================================"
echo ""

# 创建目录
mkdir -p "$MODEL_DIR"

# 模型配置
MODEL_NAME="qwen2.5-0.5b-q4.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
OUTPUT_PATH="$MODEL_DIR/$MODEL_NAME"

echo "📦 模型信息:"
echo "  名称：Qwen2.5-0.5B-Instruct (Q4_K_M 量化)"
echo "  大小：约 320MB"
echo "  内存占用：约 600MB (含上下文)"
echo "  适用：MVP 版本 (符合 PRD ≤500MB 要求)"
echo ""

# 检查文件是否已存在
if [ -f "$OUTPUT_PATH" ]; then
    FILE_SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
    echo "✅ 模型已存在：$OUTPUT_PATH ($FILE_SIZE)"
    echo ""
    read -p "是否重新下载？(y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "⏭️  跳过下载"
        exit 0
    fi
fi

# 检查 wget 或 curl
if command -v wget &> /dev/null; then
    DOWNLOADER="wget"
    DOWNLOAD_CMD="wget --show-progress -O"
elif command -v curl &> /dev/null; then
    DOWNLOADER="curl"
    DOWNLOAD_CMD="curl -L -o"
else
    echo "❌ 错误：需要安装 wget 或 curl"
    exit 1
fi

echo "⬇️  开始下载..."
echo "  使用工具：$DOWNLOADER"
echo "  下载地址：$MODEL_URL"
echo "  保存路径：$OUTPUT_PATH"
echo ""

# 执行下载
$DOWNLOAD_CMD "$OUTPUT_PATH" "$MODEL_URL"

# 验证下载
if [ -f "$OUTPUT_PATH" ]; then
    FILE_SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
    echo ""
    echo "✅ 下载完成！"
    echo "  文件：$OUTPUT_PATH"
    echo "  大小：$FILE_SIZE"
    echo ""
    echo "📝 下一步:"
    echo "  1. 运行 flutter pub get"
    echo "  2. 编译 llama.cpp 原生库 (可选，参考 docs/项目说明.md)"
    echo "  3. 运行 flutter run 测试应用"
    echo ""
    echo "💡 提示：当前为 Mock 模式，可测试 UI。集成真实模型需编译 llama.cpp。"
else
    echo ""
    echo "❌ 下载失败！"
    echo "  请检查网络连接或手动下载模型到：$OUTPUT_PATH"
    echo "  下载地址：$MODEL_URL"
    exit 1
fi
