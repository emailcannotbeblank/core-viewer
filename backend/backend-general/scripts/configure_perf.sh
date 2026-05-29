#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "错误: 未找到 jq 命令"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 找不到配置文件 $CONFIG_FILE"
    exit 1
fi

shell_quote() {
    local value="$1"
    printf "'%s'" "$(printf "%s" "$value" | sed "s/'/'\\\\''/g")"
}

target_type="$(jq -r '.target_type // empty' "$CONFIG_FILE")"
binary_path="$(jq -r '.binary_path // empty' "$CONFIG_FILE")"
source_dir="$(jq -r '.source_dir // empty' "$CONFIG_FILE")"

if [ -z "$target_type" ]; then
    if [ -n "$binary_path" ]; then
        target_type="user"
    else
        target_type="kernel"
    fi
fi

perf_probe_cmd="perf probe"
if [ "$target_type" = "user" ]; then
    if [ -z "$binary_path" ]; then
        echo "错误: target_type=user 时必须配置 binary_path"
        exit 1
    fi
    if [ ! -f "$binary_path" ]; then
        echo "错误: binary_path 不存在: $binary_path"
        exit 1
    fi

    perf_probe_cmd="perf probe -x $(shell_quote "$binary_path")"
    if [ -n "$source_dir" ]; then
        if [ ! -d "$source_dir" ]; then
            echo "错误: source_dir 不存在: $source_dir"
            exit 1
        fi
        perf_probe_cmd="$perf_probe_cmd -s $(shell_quote "$source_dir")"
    fi
elif [ "$target_type" = "kernel" ]; then
    if [ -n "$source_dir" ] && [ ! -d "$source_dir" ]; then
        echo "错误: source_dir 不存在: $source_dir"
        exit 1
    fi
    if [ -n "$source_dir" ]; then
        perf_probe_cmd="perf probe -s $(shell_quote "$source_dir")"
    fi
else
    echo "错误: target_type 只支持 user 或 kernel"
    exit 1
fi

for script in "$SCRIPT_DIR/perf_l.sh" "$SCRIPT_DIR/perf_e.sh" "$SCRIPT_DIR/perf_r.sh" "$SCRIPT_DIR/perf_c.sh"; do
    if [ ! -f "$script" ]; then
        continue
    fi
    tmp="${script}.tmp"
    awk -v cmd="$perf_probe_cmd" '
        BEGIN { replaced = 0 }
        /^(PERF_CMD|PERF_PROBE_CMD)=/ && replaced == 0 {
            print "PERF_PROBE_CMD=\"" cmd "\""
            replaced = 1
            next
        }
        { print }
    ' "$script" > "$tmp"
    mv "$tmp" "$script"
    chmod +x "$script"
done

echo "已设置 PERF_PROBE_CMD=$perf_probe_cmd"
