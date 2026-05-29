# 此脚本用于快速查询函数的 DWARF 信息，利用缓存机制避免重复解析同一版本的二进制文件。

#!/bin/bash

CONFIG_FILE="config.json"
CACHE_DIR="./.perf_cache"  # 缓存目录

# 检查依赖和配置... (省略了之前的 jq 和存在性检查，保持不变)
BIN_PATH=$(jq -r '.binary_path' "$CONFIG_FILE")
USE_SUDO=$(jq -r '.settings.use_sudo' "$CONFIG_FILE")
FUNC_NAME=$1

if [ -z "$FUNC_NAME" ]; then
    echo "用法: $0 <函数名>"
    exit 1
fi

# 1. 提取二进制文件的 SHA1 (用来做版本控制，二进制变了缓存自动失效)
# 利用 file 命令截取 BuildID
BUILD_ID=$(file "$BIN_PATH" | grep -o 'BuildID\[sha1\]=[a-f0-9]*' | cut -d'=' -f2)
if [ -z "$BUILD_ID" ]; then
    # 如果没抓到 BuildID，用文件的修改时间戳兜底
    BUILD_ID=$(stat -c %Y "$BIN_PATH")
fi

# 2. 构造缓存文件路径
mkdir -p "$CACHE_DIR"
CACHE_FILE="${CACHE_DIR}/${FUNC_NAME}_${BUILD_ID}.txt"

# 3. 检查缓存命中
if [ -f "$CACHE_FILE" ]; then
    echo "⚡ 命中缓存: 极速读取 [$FUNC_NAME]"
    cat "$CACHE_FILE"
    exit 0
fi

echo "🐌 首次读取或二进制已更新，正在解析 DWARF 信息 (可能需要几十秒)..."

# 4. 执行 perf probe 并将结果同时输出到终端和缓存文件
if [ "$USE_SUDO" = "true" ]; then
    sudo perf probe -x "$BIN_PATH" -L "$FUNC_NAME" | tee "$CACHE_FILE"
else
    perf probe -x "$BIN_PATH" -L "$FUNC_NAME" | tee "$CACHE_FILE"
fi