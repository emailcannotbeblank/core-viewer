#!/bin/bash

# 配置文件路径
CONFIG_FILE="config.json"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "错误: 未找到 'jq' 命令。请先安装它 (例如: sudo apt install jq)。"
    exit 1
fi

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 找不到配置文件 $CONFIG_FILE"
    exit 1
fi

# 从 JSON 中提取二进制路径
# -r 表示输出原始字符串（去掉引号）
BIN_PATH=$(jq -r '.binary_path' "$CONFIG_FILE")
USE_SUDO=$(jq -r '.settings.use_sudo' "$CONFIG_FILE")

# 检查是否提供了函数名参数
FUNC_NAME=$1
if [ -z "$FUNC_NAME" ]; then
    echo "用法: $0 <函数名>"
    echo "示例: $0 main_exec"
    exit 1
fi

# 检查二进制文件是否存在
if [ ! -f "$BIN_PATH" ]; then
    echo "错误: 在路径 $BIN_PATH 找不到二进制文件，请检查 config.json"
    exit 1
fi

echo "正在从 $BIN_PATH 读取函数 [$FUNC_NAME] 的源码..."

# 执行 perf probe
if [ "$USE_SUDO" = "true" ]; then
    sudo perf probe -x "$BIN_PATH" -L "$FUNC_NAME"
else
    perf probe -x "$BIN_PATH" -L "$FUNC_NAME"
fi