#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${RESOLVE_SYMBOL_CONFIG:-$BASE_DIR/config.json}"

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <简单函数名>" >&2
    echo "示例: $0 main_exec" >&2
    exit 1
fi

QUERY="$1"

if ! command -v jq >/dev/null 2>&1; then
    echo "错误: 未找到 jq 命令" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 找不到配置文件 $CONFIG_FILE" >&2
    exit 1
fi

BINARY_PATH="$(jq -r '.binary_path // empty' "$CONFIG_FILE")"
if [ -z "$BINARY_PATH" ]; then
    # Kernel targets do not have a user-space ELF binary for nm. Preserve the
    # original function name so existing kernel workflows keep working.
    printf "%s\n" "$QUERY"
    exit 0
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "错误: binary_path 不存在: $BINARY_PATH" >&2
    exit 1
fi

FIND_FUNC_SCRIPT="$(jq -r '.symbol_resolution.find_func_script // .go.find_func_script // .rust.find_func_script // "find_func.py"' "$CONFIG_FILE")"
if [[ "$FIND_FUNC_SCRIPT" != /* ]]; then
    FIND_FUNC_SCRIPT="$BASE_DIR/$FIND_FUNC_SCRIPT"
fi

if [ ! -f "$FIND_FUNC_SCRIPT" ]; then
    echo "错误: 找不到函数符号解析脚本: $FIND_FUNC_SCRIPT" >&2
    exit 1
fi

python3 "$FIND_FUNC_SCRIPT" -c "$CONFIG_FILE" -f "$QUERY"
