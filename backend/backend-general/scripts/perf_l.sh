#!/bin/bash
PERF_PROBE_CMD="perf probe -x '/home/zry/桌面/e2b/ip/iproute2/ip/ip' -s '/home/zry/桌面/e2b/ip/iproute2'"

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "用法: $0 <函数名>"
    echo "示例:"
    echo "  $0 schedule"
    echo "  $0 main_exec"
    exit 1
fi

FUNC_NAME="$1"

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

echo "PERF_PROBE_CMD: $PERF_PROBE_CMD"
echo "正在查看函数 [$FUNC_NAME] 的源码行..."
run_perf_probe -L "$FUNC_NAME"
