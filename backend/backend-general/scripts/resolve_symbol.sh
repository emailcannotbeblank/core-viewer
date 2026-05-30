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

if ! command -v nm >/dev/null 2>&1; then
    echo "错误: 未找到 nm 命令" >&2
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

RAW_SYMBOLS="$(mktemp)"
DEMANGLED_SYMBOLS="$(mktemp)"
MATCHES="$(mktemp)"
trap 'rm -f "$RAW_SYMBOLS" "$DEMANGLED_SYMBOLS" "$MATCHES"' EXIT

nm -a --format=posix "$BINARY_PATH" > "$RAW_SYMBOLS"
nm -aC --format=posix "$BINARY_PATH" > "$DEMANGLED_SYMBOLS"

paste "$RAW_SYMBOLS" "$DEMANGLED_SYMBOLS" | awk -F '\t' -v query="$QUERY" '
function parse_demangled(line, fields, n, i, name) {
    n = split(line, fields, /[[:space:]]+/)
    if (n < 4) {
        return ""
    }
    name = fields[1]
    for (i = 2; i <= n - 3; i++) {
        name = name " " fields[i]
    }
    return name
}

function last_component(name, parts, n) {
    n = split(name, parts, "::")
    return parts[n]
}

function emit(raw_name, demangled_name, score) {
    print score "\t" raw_name "\t" demangled_name
}

{
    split($1, raw_fields, /[[:space:]]+/)
    raw_name = raw_fields[1]
    raw_type = raw_fields[2]
    if (raw_name == "" || raw_type !~ /^[tTwW]$/) {
        next
    }

    demangled_name = parse_demangled($2)
    if (demangled_name == "") {
        next
    }

    if (raw_name == query) {
        emit(raw_name, demangled_name, 0)
    } else if (demangled_name == query) {
        emit(raw_name, demangled_name, 1)
    } else if (last_component(demangled_name) == query) {
        emit(raw_name, demangled_name, 2)
    }
}
' > "$MATCHES"

if [ ! -s "$MATCHES" ]; then
    echo "错误: 未在 $BINARY_PATH 中找到函数符号: $QUERY" >&2
    exit 2
fi

BEST_SCORE="$(awk -F '\t' 'NR == 1 || $1 < best { best = $1 } END { print best }' "$MATCHES")"
BEST_MATCHES="$(awk -F '\t' -v score="$BEST_SCORE" '$1 == score' "$MATCHES")"
BEST_COUNT="$(printf "%s\n" "$BEST_MATCHES" | sed '/^[[:space:]]*$/d' | wc -l)"

if [ "$BEST_COUNT" -gt 1 ]; then
    echo "错误: 函数名存在多个匹配，请输入更完整的名称:" >&2
    printf "%s\n" "$BEST_MATCHES" | awk -F '\t' '{ print "  " $3 " -> " $2 }' >&2
    exit 3
fi

printf "%s\n" "$BEST_MATCHES" | awk -F '\t' '{ print $2 }'
