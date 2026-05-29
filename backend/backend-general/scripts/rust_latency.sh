#!/bin/bash
# rust_latency.sh
# sudo ./rust_latency.sh record 'main_exec:0' 'main_exec:34' 5
# sudo ./scripts/rust_latency.sh record 'main_exec:0' 'main_exec:34' 5


MODE=$1
DEF_START=$2
DEF_END=$3

# 获取当前 bash 脚本所在的目录，以便找到同目录下的 python 脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/process_latency.py"
CONFIG_FILE="$SCRIPT_DIR/../config.json"

# 自动适配内核 tracing 路径
TRACE_BASE="/sys/kernel/tracing"
[ ! -d "$TRACE_BASE" ] && TRACE_BASE="/sys/kernel/debug/tracing"

if [ -z "$MODE" ]; then
    echo "用法: $0 <setup|record> <起点探针> <终点探针> [录制时长秒数]"
    echo "示例: $0 record 'main_exec:0' 'main_exec:34' 5"
    exit 1
fi

# ================= 引入 Rust 配置文件 =================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ 找不到配置文件 $CONFIG_FILE"
    exit 1
fi
BIN_PATH=$(jq -r '.binary_path' "$CONFIG_FILE")
SOURCE_DIR=$(jq -r '.source_dir' "$CONFIG_FILE")

ACTUAL_START="${DEF_START#*=}"
ACTUAL_END="${DEF_END#*=}"

# 清洗 Rust 带有符号的名字，作为底层 ftrace 的事件目录名
START_NAME="start_$(echo "$ACTUAL_START" | sed 's/[^a-zA-Z0-9]/_/g')"
END_NAME="end_$(echo "$ACTUAL_END" | sed 's/[^a-zA-Z0-9]/_/g')"
GROUP_NAME="rust_lat"

# ================= 第一部分：准备阶段 =================
if [ "$MODE" == "setup" ]; then
    echo "[1/2] 正在清理旧探针..."
    perf probe -q -x "$BIN_PATH" --del "${GROUP_NAME}:*" > /dev/null 2>&1

    echo "[2/2] 正在添加新探针..."
    perf probe -q -x "$BIN_PATH" -s "$SOURCE_DIR" -a "${GROUP_NAME}:${START_NAME}=${ACTUAL_START}" || { echo "❌ 添加起点探针失败 ($ACTUAL_START)"; exit 1; }
    perf probe -q -x "$BIN_PATH" -s "$SOURCE_DIR" -a "${GROUP_NAME}:${END_NAME}=${ACTUAL_END}" || { echo "❌ 添加终点探针失败 ($ACTUAL_END)"; exit 1; }
    echo "--- 准备阶段完成，探针已就绪 ---"
    exit 0

# ================= 第二部分：录制分析阶段 =================
elif [ "$MODE" == "record" ]; then
    LAST_ARG="${!#}"
    if [[ "$LAST_ARG" =~ ^[0-9]+$ ]] && [ "$LAST_ARG" != "$DEF_END" ]; then
        SLEEP_TIME=$LAST_ARG
    else
        SLEEP_TIME=${4:-5} 
    fi

    # 兼容 Rust 内联可能导致的 _1, _2 后缀，寻找真实的事件目录
    EVENT_START_DIR=$(ls -1 "$TRACE_BASE/events/$GROUP_NAME/" 2>/dev/null | grep "^${START_NAME}" | head -n 1)
    EVENT_END_DIR=$(ls -1 "$TRACE_BASE/events/$GROUP_NAME/" 2>/dev/null | grep "^${END_NAME}" | head -n 1)

    if [ -z "$EVENT_START_DIR" ] || [ ! -f "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/id" ]; then
        echo "❌ 找不到探针事件，请先执行 setup 模式！"
        exit 1
    fi

    ID_START=$(cat "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/id")
    ID_END=$(cat "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/id")

    if [ ! -f "$PYTHON_SCRIPT" ]; then
        echo "❌ 找不到配套的 Python 处理脚本: $PYTHON_SCRIPT"
        exit 1
    fi

    echo "[1/3] 配置 ftrace 并开始录制 (${SLEEP_TIME}秒)..."
    
    echo mono > "$TRACE_BASE/trace_clock"
    echo raw > "$TRACE_BASE/trace_options"
    echo > "$TRACE_BASE/trace"

    echo 1 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/enable"
    echo 1 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/enable"

    sleep "$SLEEP_TIME"

    echo 0 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_START_DIR/enable"
    echo 0 > "$TRACE_BASE/events/$GROUP_NAME/$EVENT_END_DIR/enable"

    # 将 raw log 保存，去掉了后续的自动删除命令
    RAW_LOG="/tmp/raw_latency_log_$$.txt"
    cat "$TRACE_BASE/trace" > "$RAW_LOG"

    echo "[2/3] 正在调用 $PYTHON_SCRIPT 使用多进程分析海量数据..."
    cat "$TRACE_BASE/trace" > my_latency_log.txt

    # 调用独立的 Python 脚本
    python3 "$PYTHON_SCRIPT" "$RAW_LOG" "$ID_START" "$ID_END"

    echo -e "\n[3/3] 🧹 正在清理探针与环境..."
    echo noraw > "$TRACE_BASE/trace_options"
    
    # 清理探针
    perf probe -q -x "$BIN_PATH" --del "${GROUP_NAME}:*" > /dev/null 2>&1
    
    echo "📁 [保留中间结果] ftrace 原始总文件保存在: $RAW_LOG"
    echo "✨ 完成！"
    exit 0
else
    echo "错误：未知模式 $MODE"
    exit 1
fi