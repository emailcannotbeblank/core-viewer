#!/bin/bash
PERF_PROBE_CMD="perf probe -x '/home/zry/桌面/virt/firecracker/firecracker/build/cargo_target/debug/firecracker' -s '/home/zry/桌面/virt/firecracker/firecracker'"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.json"
PYTHON_SCRIPT="$SCRIPT_DIR/process_callstacks.py"
TRACE_BASE="/sys/kernel/tracing"
[ ! -d "$TRACE_BASE" ] && TRACE_BASE="/sys/kernel/debug/tracing"

if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 sudo 运行此脚本，perf probe/record 通常需要 root 权限。"
    exit 1
fi

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <函数名> [采样秒数] [调用栈过滤]"
    echo "示例:"
    echo "  $0 schedule 5"
    echo "  $0 main 5 get_user_pages"
    exit 1
fi

TARGET_FUNC="$1"
SLEEP_TIME="${2:-5}"
CALLSTACK_FILTER="${3:-*}"
SAFE_FUNC="$(echo "$TARGET_FUNC" | sed 's/[^a-zA-Z0-9]/_/g')"
GROUP_NAME="general_c"
EVENT_NAME="call_${SAFE_FUNC}"
RESULTS_DIR="$BASE_DIR/results"
OUT_DIR="$RESULTS_DIR/callstacks_${SAFE_FUNC}"
RECORD_FILE="$OUT_DIR/perf_record.data"
SCRIPT_FILE="$OUT_DIR/perf_script.txt"
mkdir -p "$OUT_DIR"

quote_arg() {
    printf "%q" "$1"
}

run_perf_probe() {
    local cmd="$PERF_PROBE_CMD"
    local arg
    for arg in "$@"; do
        cmd="$cmd $(quote_arg "$arg")"
    done
    eval "$cmd"
}

run_perf_probe_capture() {
    local cmd="$PERF_PROBE_CMD"
    local arg
    for arg in "$@"; do
        cmd="$cmd $(quote_arg "$arg")"
    done
    eval "$cmd" 2>&1
}

call_graph_mode() {
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.settings.call_graph // "fp"' "$CONFIG_FILE"
    else
        echo "fp"
    fi
}

cleanup() {
    run_perf_probe --del "${GROUP_NAME}:*" >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [ ! -f "$PYTHON_SCRIPT" ]; then
    echo "错误: 找不到 $PYTHON_SCRIPT"
    exit 1
fi

echo "[1/4] 清理旧调用栈探针..."
cleanup

echo "[2/4] 给函数 [$TARGET_FUNC] 入口打点..."
probe_def="${GROUP_NAME}:${EVENT_NAME}=${TARGET_FUNC}"
probe_output="$(run_perf_probe_capture -a "$probe_def" || true)"
exact_event="$(printf "%s\n" "$probe_output" | awk -v name="$EVENT_NAME" 'index($0, ":" name " ") > 0 { print $1; exit }')"

if [ -z "$exact_event" ]; then
    exact_event="${GROUP_NAME}:${EVENT_NAME}"
fi

if [ ! -d "$TRACE_BASE/events/$GROUP_NAME/$EVENT_NAME" ]; then
    echo "错误: 添加函数入口探针失败。"
    printf "%s\n" "$probe_output"
    exit 1
fi

graph="$(call_graph_mode)"
echo "事件: $exact_event"
echo "数据目录: $OUT_DIR"
echo "[3/4] 使用 perf record -g 采样 ${SLEEP_TIME} 秒..."
perf record -o "$RECORD_FILE" -a -g --call-graph "$graph" -e "$exact_event" -- sleep "$SLEEP_TIME"
perf script -i "$RECORD_FILE" > "$SCRIPT_FILE"

echo "[4/4] 聚合不同调用栈并按次数排序..."
python3 "$PYTHON_SCRIPT" "$SCRIPT_FILE" "$TARGET_FUNC" "$CALLSTACK_FILTER"
echo "完成。原始数据保存在 $OUT_DIR"
