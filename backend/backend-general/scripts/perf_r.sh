#!/bin/bash
PERF_PROBE_CMD="perf probe -x '/home/zry/桌面/virt/firecracker/firecracker/build/cargo_target/debug/firecracker' -s '/home/zry/桌面/virt/firecracker/firecracker'"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.json"
PYTHON_FTRACE="$SCRIPT_DIR/process_latency.py"
PYTHON_PERF="$SCRIPT_DIR/process_perf_latency.py"

TRACE_BASE="/sys/kernel/tracing"
[ ! -d "$TRACE_BASE" ] && TRACE_BASE="/sys/kernel/debug/tracing"

if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 sudo 运行此脚本，perf/ftrace 通常需要 root 权限。"
    exit 1
fi

if [ "$#" -lt 3 ]; then
    echo "用法: $0 <setup|record> <起点函数:行偏移> <终点函数:行偏移> [录制秒数] [调用栈过滤]"
    echo "示例:"
    echo "  $0 setup schedule:0 schedule:20"
    echo "  $0 record schedule:0 schedule:20 5"
    echo "  $0 record schedule:0 schedule:20 5 pick_next_task"
    exit 1
fi

MODE="$1"
DEF_START="$2"
DEF_END="$3"

normalize_probe_point() {
    local point="${1#*=}"
    if [[ "$point" == *":%return" ]]; then
        point="${point/:%return/%return}"
    fi
    echo "$point"
}

ACTUAL_START="$(normalize_probe_point "$DEF_START")"
ACTUAL_END="$(normalize_probe_point "$DEF_END")"
START_NAME="start_$(echo "$ACTUAL_START" | sed 's/[^a-zA-Z0-9]/_/g')"
END_NAME="end_$(echo "$ACTUAL_END" | sed 's/[^a-zA-Z0-9]/_/g')"
GROUP_NAME="general_r"
RUN_NAME="$(echo "${ACTUAL_START}_${ACTUAL_END}" | sed 's/[^a-zA-Z0-9]/_/g')"
RESULTS_DIR="$BASE_DIR/results"
OUT_DIR="$RESULTS_DIR/perf_latency_${RUN_NAME}"
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

call_graph_mode() {
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.settings.call_graph // "fp"' "$CONFIG_FILE"
    else
        echo "fp"
    fi
}

find_event_dir() {
    local prefix="$1"
    ls -1 "$TRACE_BASE/events/$GROUP_NAME/" 2>/dev/null | grep "^${prefix}" | head -n 1
}

event_name_for_perf() {
    local event_dir="$1"
    echo "${GROUP_NAME}:${event_dir}"
}

if [ "$MODE" = "setup" ]; then
    echo "[1/2] 清理旧时延探针..."
    run_perf_probe --del "${GROUP_NAME}:*" >/dev/null 2>&1 || true

    echo "[2/2] 添加起点和终点探针..."
    run_perf_probe -a "${GROUP_NAME}:${START_NAME}=${ACTUAL_START}"
    run_perf_probe -a "${GROUP_NAME}:${END_NAME}=${ACTUAL_END}"
    echo "完成: start=$ACTUAL_START end=$ACTUAL_END"
    exit 0
fi

if [ "$MODE" = "record" ]; then
    SLEEP_TIME="${4:-5}"
    CALLSTACK_FILTER="${5:-}"

    EVENT_START_DIR="$(find_event_dir "$START_NAME")"
    EVENT_END_DIR="$(find_event_dir "$END_NAME")"

    if [ -z "$EVENT_START_DIR" ] || [ -z "$EVENT_END_DIR" ]; then
        echo "错误: 找不到探针事件，请先执行 setup。"
        exit 1
    fi

    START_EVENT="$(event_name_for_perf "$EVENT_START_DIR")"
    END_EVENT="$(event_name_for_perf "$EVENT_END_DIR")"

    echo "PERF_PROBE_CMD: $PERF_PROBE_CMD"
    echo "起点事件: $START_EVENT"
    echo "终点事件: $END_EVENT"
    echo "数据目录: $OUT_DIR"

    if [ -z "$CALLSTACK_FILTER" ] || [ "$CALLSTACK_FILTER" = "*" ]; then
        if [ ! -f "$PYTHON_FTRACE" ]; then
            echo "错误: 找不到 $PYTHON_FTRACE"
            exit 1
        fi

        ID_START="$(cat "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/id")"
        ID_END="$(cat "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/id")"
        RAW_LOG="$OUT_DIR/raw_latency_log.txt"

        echo "[1/3] 使用 ftrace raw 录制 ${SLEEP_TIME} 秒..."
        echo mono > "$TRACE_BASE/trace_clock"
        echo raw > "$TRACE_BASE/trace_options"
        echo > "$TRACE_BASE/trace"
        echo 1 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/enable"
        echo 1 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/enable"
        sleep "$SLEEP_TIME"
        echo 0 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/enable"
        echo 0 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/enable"
        cat "$TRACE_BASE/trace" > "$RAW_LOG"

        echo "[2/3] 计算时延分布..."
        python3 "$PYTHON_FTRACE" "$RAW_LOG" "$ID_START" "$ID_END"

        echo "[3/3] 清理探针..."
        echo noraw > "$TRACE_BASE/trace_options"
    else
        if [ ! -f "$PYTHON_PERF" ]; then
            echo "错误: 找不到 $PYTHON_PERF"
            exit 1
        fi

        graph="$(call_graph_mode)"
        RECORD_FILE="$OUT_DIR/perf_record.data"
        SCRIPT_FILE="$OUT_DIR/perf_script.txt"

        echo "[1/3] 调用栈过滤: $CALLSTACK_FILTER"
        echo "[2/3] 使用 perf record -g 记录调用栈，采样 ${SLEEP_TIME} 秒..."
        perf record -o "$RECORD_FILE" -a -g --call-graph "$graph" -e "$START_EVENT" -e "$END_EVENT" -- sleep "$SLEEP_TIME"
        perf script -i "$RECORD_FILE" > "$SCRIPT_FILE"

        echo "[3/3] 根据调用栈过滤并计算时延..."
        python3 "$PYTHON_PERF" "$SCRIPT_FILE" "$START_EVENT" "$END_EVENT" "$CALLSTACK_FILTER"
    fi

    run_perf_probe --del "${GROUP_NAME}:*" >/dev/null 2>&1 || true
    echo "完成。原始数据保存在 $OUT_DIR"
    exit 0
fi

echo "错误: 未知模式 $MODE"
exit 1
