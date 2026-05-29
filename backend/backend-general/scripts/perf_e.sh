#!/bin/bash
PERF_PROBE_CMD="perf probe -x '/home/zry/桌面/e2b/ip/iproute2/ip/ip' -s '/home/zry/桌面/e2b/ip/iproute2'"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.json"

if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 sudo 运行此脚本，perf probe/stat/record 通常需要 root 权限。"
    exit 1
fi

if [ "$#" -lt 2 ]; then
    echo "用法: $0 <setup|stat> <函数名> [采样秒数] [调用栈过滤]"
    echo "示例:"
    echo "  $0 setup schedule"
    echo "  $0 stat schedule 5"
    echo "  $0 stat schedule 5 pick_next_task"
    exit 1
fi

MODE="$1"
TARGET_FUNC="$2"
SAFE_FUNC="$(echo "$TARGET_FUNC" | sed 's/[^a-zA-Z0-9]/_/g')"
GROUP_NAME="general_e"
RESULTS_DIR="$BASE_DIR/results"
OUT_DIR="$RESULTS_DIR/perf_results_${SAFE_FUNC}"
LINES_FILE="$OUT_DIR/perf_lines.txt"
EVENTS_MAP_FILE="$OUT_DIR/events_map.txt"
STAT_FILE="$OUT_DIR/perf_stat.txt"
RECORD_FILE="$OUT_DIR/perf_record.data"
SCRIPT_FILE="$OUT_DIR/perf_script.txt"
STACK_COUNT_FILE="$OUT_DIR/perf_stack_counts.txt"

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

parse_stack_counts() {
    local filter="$1"
    local filter_file="$OUT_DIR/callstack_filter.txt"
    printf "%s\n" "$filter" | tr ',;' '\n' | sed '/^[[:space:]]*$/d' > "$filter_file"

    awk -v map_file="$EVENTS_MAP_FILE" -v filter_file="$filter_file" '
        BEGIN {
            while ((getline < map_file) > 0) {
                offset[$2] = $1
                events[$2] = 1
            }
            while ((getline < filter_file) > 0) {
                filters[++filter_count] = $0
            }
        }
        function flush_event(    i, matched) {
            if (current_event == "") {
                return
            }
            matched = (filter_count == 0)
            for (i = 1; i <= filter_count; i++) {
                if (index(stack_text, filters[i]) > 0) {
                    matched = 1
                }
            }
            if (matched) {
                counts[current_event]++
            }
        }
        {
            found = ""
            for (event in events) {
                if (index($0, event) > 0) {
                    found = event
                    break
                }
            }
            if (found != "") {
                flush_event()
                current_event = found
                stack_text = ""
                next
            }
            if (current_event != "") {
                stack_text = stack_text "\n" $0
            }
        }
        END {
            flush_event()
            for (event in events) {
                print offset[event], event, counts[event] + 0
            }
        }
    ' "$SCRIPT_FILE" > "$STACK_COUNT_FILE"
}

render_results() {
    local count_source="$1"

    echo ""
    echo "统计结果:"
    echo "----------------------------------------------------------------------"
    echo "[ 命中次数 ] 行号 源码"
    echo "----------------------------------------------------------------------"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*) ]]; then
            offset="${BASH_REMATCH[1]}"
            code="${BASH_REMATCH[2]}"
            exact_event="$(awk -v off="$offset" '$1 == off {print $2; exit}' "$EVENTS_MAP_FILE")"

            if [ -z "$exact_event" ]; then
                printf "[   N/A    ] %-4s %s\n" "$offset" "$code"
                continue
            fi

            if [ "$count_source" = "stat" ]; then
                count="$(awk -F',' -v target="$exact_event" '{
                    event_clean=$3
                    sub(/:[a-zA-Z]+$/, "", event_clean)
                    if (event_clean == target) { print $1; exit }
                }' "$STAT_FILE")"
            else
                count="$(awk -v off="$offset" '$1 == off {print $3; exit}' "$STACK_COUNT_FILE")"
            fi

            if [ -z "${count:-}" ] || [[ "$count" == *"<"* ]]; then
                count="0"
            fi
            printf "[ %8s ] %-4s %s\n" "$count" "$offset" "$code"
        else
            echo "               $line"
        fi
    done < "$LINES_FILE"

    echo "----------------------------------------------------------------------"
}

if [ "$MODE" = "setup" ]; then
    echo "[1/3] 清理旧探针..."
    run_perf_probe --del "${GROUP_NAME}:*" >/dev/null 2>&1 || true
    rm -f "$EVENTS_MAP_FILE"

    echo "[2/3] 读取 [$TARGET_FUNC] 的源码行..."
    run_perf_probe -L "$TARGET_FUNC" > "$LINES_FILE"
    OFFSETS="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+' "$LINES_FILE" | awk '{print $1}')"

    if [ -z "$OFFSETS" ]; then
        echo "错误: 无法获取源码行。请确认函数名、调试符号和源码路径。"
        exit 1
    fi

    echo "[3/3] 给函数内每一行打 probe..."
    touch "$EVENTS_MAP_FILE"
    VALID_PROBES=0

    for offset in $OFFSETS; do
        probe_name="line_${SAFE_FUNC}_${offset}"
        probe_def="${GROUP_NAME}:${probe_name}=${TARGET_FUNC}:${offset}"
        output="$(run_perf_probe_capture -a "$probe_def" || true)"
        exact_event="$(printf "%s\n" "$output" | awk -v name="$probe_name" '
            index($0, ":" name " ") > 0 { print $1; exit }
        ')"
        if [ -z "$exact_event" ]; then
            exact_event="${GROUP_NAME}:${probe_name}"
            if ! [ -d "/sys/kernel/tracing/events/$GROUP_NAME/$probe_name" ] && ! [ -d "/sys/kernel/debug/tracing/events/$GROUP_NAME/$probe_name" ]; then
                echo "警告: 第 $offset 行打点失败"
                printf "%s\n" "$output"
                continue
            fi
        fi
        echo "$offset $exact_event" >> "$EVENTS_MAP_FILE"
        VALID_PROBES=$((VALID_PROBES + 1))
    done

    echo "完成: 成功插入 $VALID_PROBES 个探针，映射保存到 $EVENTS_MAP_FILE"
    if [ "$VALID_PROBES" -eq 0 ]; then
        exit 1
    fi
    exit 0
fi

if [ "$MODE" = "stat" ]; then
    SLEEP_TIME="${3:-5}"
    CALLSTACK_FILTER="${4:-}"

    if [ ! -s "$EVENTS_MAP_FILE" ]; then
        echo "错误: 找不到事件映射，请先运行 setup。"
        exit 1
    fi

    EVENT_ARGS=()
    while read -r _offset exact_event; do
        [ -n "$exact_event" ] && EVENT_ARGS+=("-e" "$exact_event")
    done < "$EVENTS_MAP_FILE"

    if [ "${#EVENT_ARGS[@]}" -eq 0 ]; then
        echo "错误: 没有可统计的事件。"
        exit 1
    fi

    echo "PERF_PROBE_CMD: $PERF_PROBE_CMD"
    echo "目标函数: $TARGET_FUNC"
    echo "数据目录: $OUT_DIR"

    if [ -z "$CALLSTACK_FILTER" ] || [ "$CALLSTACK_FILTER" = "*" ]; then
        echo "[1/3] 使用 perf stat 统计每行执行次数，采样 ${SLEEP_TIME} 秒..."
        perf stat -x ',' -a "${EVENT_ARGS[@]}" -- sleep "$SLEEP_TIME" 2> "$STAT_FILE"
        echo "[2/3] 解析 perf stat 结果..."
        render_results stat
    else
        graph="$(call_graph_mode)"
        echo "[1/3] 调用栈过滤: $CALLSTACK_FILTER"
        echo "[2/3] 使用 perf record -g 记录调用栈并统计事件，采样 ${SLEEP_TIME} 秒..."
        perf record -o "$RECORD_FILE" -a -g --call-graph "$graph" "${EVENT_ARGS[@]}" -- sleep "$SLEEP_TIME"
        perf script -i "$RECORD_FILE" > "$SCRIPT_FILE"
        parse_stack_counts "$CALLSTACK_FILTER"
        render_results stack
    fi

    echo "[3/3] 完成。原始数据保存在 $OUT_DIR"
    exit 0
fi

echo "错误: 未知模式 $MODE"
exit 1
