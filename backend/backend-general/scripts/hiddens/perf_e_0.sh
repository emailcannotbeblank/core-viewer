#!/bin/bash
# scripts/scripts/perf_e.sh


# ==============================================================================
# 工具名称: scripts/perf_e.sh
# 功能描述: 基于 uprobe 的 Rust 用户态程序源码行级性能分析工具。
#           通过解析 DWARF 调试信息，自动映射 Rust 函数源码，并利用 perf stat
#           精准统计函数内每一行代码在运行时的执行次数（命中率）。
#
# 核心架构 (两阶段运行机制):
# 由于 Rust 存在复杂的符号修饰（Name Mangling）和命名空间（如 ::），直接预测 
# perf 底层生成的探针事件名极易引发规则冲突或段错误。因此本脚本采用两阶段设计：
#   - 阶段 1 [setup]: 探测与注册。尝试插入探针，并实时捕获 perf 系统真实分配
#                     的“合法事件名”，将其与源码行号严格绑定，生成精准映射字典。
#   - 阶段 2 [stat]:  采样与解析。读取映射字典，将 100% 准确的事件名喂给 perf stat，
#                     从而实现零报错的高精度数据采集，并将结果反向渲染到源码行。
#
# 环境依赖:
#   1. 系统已安装 `perf` 和 `jq` 命令。
#   2. 目标二进制文件包含调试信息 (not stripped, with debug_info)。
#   3. 同级目录下存在正确的 `config.json`。
#
# 配置文件 (config.json) 示例:
# {
#   "binary_path": "./build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker",
#   "project_name": "firecracker-debug",
#   "settings": { "use_sudo": true }
# }
#
# ============================== 用法与示例 ====================================
#
# 【注意】执行 perf 探针操作需要 root 权限。
#
# ➜ 阶段一：初始化探针 (Setup)
# 必须先运行此步！清理旧环境，生成探针字典。
# 命令格式: sudo ./scripts/perf_e.sh setup <目标函数名>
# 使用示例: 
#   sudo ./scripts/perf_e.sh setup main_exec
#   sudo ./scripts/perf_e.sh setup 'firecracker::vmm::main_exec'
#
# ➜ 阶段二：打点统计 (Stat)
# 目标程序运行或压测期间，执行此步抓取行级命中数据。
# 命令格式: sudo ./scripts/perf_e.sh stat <目标函数名> [采样时间(秒)]
# 使用示例: 
#   sudo ./scripts/perf_e.sh stat main_exec      # 默认采集 5 秒
#   sudo ./scripts/perf_e.sh stat main_exec 15   # 持续采集 15 秒
#
# 数据归档:
# 运行结束后，所有生成的源码映射、探针字典以及 perf 原始记录，都会完整保存在
# ./perf_results_<函数名>/ 目录下，脚本不会自动销毁，方便后续追溯与查错。
# ==============================================================================




if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本，perf 需要 root 权限。"
  exit 1
fi

if [ "$#" -lt 2 ]; then
  echo "用法: $0 <setup|stat> <目标函数名> [采样时间(秒)]"
  echo "示例: $0 setup main_exec"
  exit 1
fi

MODE=$1
TARGET_FUNC=$2

# ================= 引入配置文件 =================
CONFIG_FILE="config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ 错误: 找不到配置文件 $CONFIG_FILE"
    exit 1
fi

BIN_PATH=$(jq -r '.binary_path' "$CONFIG_FILE")
if [ ! -f "$BIN_PATH" ]; then
    echo "❌ 错误: 在 config.json 中指定的二进制文件不存在: $BIN_PATH"
    exit 1
fi

# 数据保存目录，按函数名隔离保存，绝不自动删除
OUT_DIR="./perf_results_${TARGET_FUNC}"
mkdir -p "$OUT_DIR"

LINES_FILE="$OUT_DIR/perf_lines.txt"
EVENTS_MAP_FILE="$OUT_DIR/events_map.txt"
STAT_FILE="$OUT_DIR/perf_stat.txt"

# ================= 第一部分：准备阶段 =================
if [ "$MODE" == "setup" ]; then
    
    # 0. 精准清理上次遗留的探针 (读取我们自己记录的准确名字)
    if [ -f "$EVENTS_MAP_FILE" ]; then
        echo "[0/3] 正在清理上次为该函数生成的历史探针..."
        while read -r offset exact_event_name; do
            perf probe -q -x "$BIN_PATH" -d "$exact_event_name" 2>/dev/null
        done < "$EVENTS_MAP_FILE"
        rm -f "$EVENTS_MAP_FILE"
    fi

    echo "[1/3] 正在读取 [$TARGET_FUNC] 的源码行..."
    perf probe -x "$BIN_PATH" -L "$TARGET_FUNC" > "$LINES_FILE"
    OFFSETS=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+' "$LINES_FILE" | awk '{print $1}')

    if [ -z "$OFFSETS" ]; then
      echo "❌ 无法获取源码行，函数名未找到或没有 Debug 符号。"
      exit 1
    fi

    echo "[2/3] 正在打入探针，并获取系统真实分配的事件名..."
    touch "$EVENTS_MAP_FILE"
    VALID_PROBES=0

    for OFFSET in $OFFSETS; do
      # 核心改变：执行探测并捕获输出！我们不再自己编造事件名。
      # perf 的标准成功输出包含两行，如：
      # Added new event:
      #   probe_firecracker:main_exec_L2   (on main_exec:2 in ...)
      
      PROBE_OUT=$(perf probe -x "$BIN_PATH" -a "${TARGET_FUNC}:${OFFSET}" 2>&1)
      RET=$?
      
      if [ $RET -eq 0 ]; then
          # 提取 perf 真正生成的那个精确事件名 (例如 probe_firecracker:main_exec_L2)
          EXACT_EVENT=$(echo "$PROBE_OUT" | grep -A 1 "Added new event:" | tail -n 1 | awk '{print $1}')
          
          if [ -n "$EXACT_EVENT" ]; then
              VALID_PROBES=$((VALID_PROBES + 1))
              # 将行号和真实的事件名严格绑定，存入字典文件
              echo "$OFFSET $EXACT_EVENT" >> "$EVENTS_MAP_FILE"
          fi
      elif echo "$PROBE_OUT" | grep -q "Segmentation fault"; then
          echo "⚠️ 警告: perf 解析第 $OFFSET 行时崩溃，已跳过。"
      fi
    done

    echo "[3/3] ✅ 成功插入了 $VALID_PROBES 个有效探针。事件映射表已保存。"
    if [ "$VALID_PROBES" -eq 0 ]; then
      echo "❌ 未能成功插入任何探针，退出。"
      exit 1
    fi
    exit 0

# ================= 第二部分：监控分析阶段 =================
elif [ "$MODE" == "stat" ]; then
    SLEEP_TIME=${3:-5}

    if [ ! -f "$EVENTS_MAP_FILE" ] || [ ! -s "$EVENTS_MAP_FILE" ]; then
        echo "❌ 错误: 找不到探针映射文件，请先运行 setup 模式。"
        exit 1
    fi

    # 1. 组装所有真实的事件名
    # awk 提取第二列 (事件名)，paste 拼接成逗号分隔符用于 perf stat 的 -e 参数
    EVENT_LIST=$(awk '{print $2}' "$EVENTS_MAP_FILE" | paste -s -d, -)

    echo "🔍 目标函数: $TARGET_FUNC"
    echo "📂 数据保存: $OUT_DIR"
    echo "--------------------------------------------------"

    echo "[1/3] 开始采集，使用系统准确事件名。请等待 $SLEEP_TIME 秒..."
    # 喂给 perf stat 的绝对是它自己生成的合规名字
    perf stat -x ',' -a -e "$EVENT_LIST" -- sleep "$SLEEP_TIME" 2> "$STAT_FILE"

    echo "[2/3] 正在解析统计结果..."
    
    echo ""
    echo "🎯 统计结果:"
    echo "----------------------------------------------------------------------"
    echo "[ 命中次数 ] 行号   源码"
    echo "----------------------------------------------------------------------"

    # 遍历源码行文件
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*) ]]; then
            offset="${BASH_REMATCH[1]}"
            code="${BASH_REMATCH[2]}"
            
            # 从映射表中查出这一行对应的真实事件名
            exact_event=$(awk -v off="$offset" '$1 == off {print $2}' "$EVENTS_MAP_FILE")
            
            if [ -n "$exact_event" ]; then
                # 在 perf stat 的 CSV 输出中精准查找这个事件名的命中次数
                # 为了防止名称包含特殊字符引发正则错误，在 awk 中用完全字符串匹配
                count=$(awk -F',' -v target="$exact_event" '{
                    # 清理可能带有的后缀，如 :u
                    event_clean=$3; sub(/:[a-zA-Z]+$/, "", event_clean);
                    if (event_clean == target) { print $1; exit; }
                }' "$STAT_FILE")
                
                # 处理计数为空或显示 <not counted> 的情况
                if [ -z "$count" ] || [[ "$count" == *"<"* ]]; then count="0"; fi
                
                if [ "$count" -gt 0 ]; then
                    printf "[ %8s ] %-4s %s\n" "$count" "$offset" "$code"
                else
                    printf "[        0 ] %-4s %s\n" "$offset" "$code"
                fi
            else
                # 这一行没有成功打入探针
                printf "[   N/A    ] %-4s %s\n" "$offset" "$code"
            fi
        else
            echo "               $line"
        fi
    done < "$LINES_FILE"
    echo "----------------------------------------------------------------------"

    echo "[3/3] 保留现场。测试数据已完整记录在 $OUT_DIR 目录中。"
    exit 0

else
    echo "❌ 错误：未知模式 $MODE"
    echo "用法: $0 <setup|stat> <目标函数名> [采样时间(秒)]"
    exit 1
fi