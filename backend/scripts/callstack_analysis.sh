#!/bin/bash

# =======================================================
# 脚本名称: callstack_analysis.sh
# 功能: 抓取指定函数的调用栈，过滤，分类聚合，统计每种路径的频次
# =======================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本"
  exit 1
fi

if [ "$#" -lt 2 ]; then
    echo "用法: $0 <函数名> <过滤调用栈> [采样时长秒数]"
    exit 1
fi

FUNC_NAME=$1
FILTER_INPUT=$2
SLEEP_TIME=${3:-5}

# 提取探针名 (防备用户带了 offset，虽然一般只传函数名)
NAME_START=$(echo "$FUNC_NAME" | cut -d: -f1)

echo "[1/4] 正在清理旧探针..."
perf probe -q -d "$NAME_START" > /dev/null 2>&1

echo "[2/4] 正在添加新探针..."
perf probe -q -a "$FUNC_NAME" || { echo "❌ 添加探针失败"; exit 1; }

echo "--- 配置确认 ---"
echo "目标函数: $FUNC_NAME"
echo "过滤规则: $FILTER_INPUT"
echo "采样时长: $SLEEP_TIME 秒"
echo "----------------"

echo "[3/4] 🚀 开始录制调用栈 (全系统监控)..."
perf record -a -g -e "probe:${NAME_START}" -- sleep "$SLEEP_TIME" > /dev/null 2>&1

echo "[4/4] 📊 正在清洗并聚合调用栈数据..."

# 使用内嵌 Python 脚本对 perf script 的输出进行精准的多行聚合和频次统计
perf script 2>/dev/null | python3 -c '
import sys
import collections

filter_str = sys.argv[1]
stacks = collections.defaultdict(int)
current_stack = []

# 逐行读取 perf script 输出
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    
    # 行首非空格，代表一个新的事件开始
    if not line.startswith(" ") and not line.startswith("\t"):
        if current_stack:
            stack_str = "\n".join(current_stack)
            if filter_str == "*" or filter_str in stack_str:
                stacks[stack_str] += 1
        current_stack = []
    else:
        # 行首有空格，代表是调用栈的一层
        current_stack.append(line)

# 处理文件末尾最后一个栈
if current_stack:
    stack_str = "\n".join(current_stack)
    if filter_str == "*" or filter_str in stack_str:
        stacks[stack_str] += 1

if not stacks:
    print("\n[警告] 未找到符合条件的调用栈记录。")
    sys.exit(0)

print(f"\n=== 调用栈聚合结果 (共发掘出 {len(stacks)} 种独立调用路径) ===")
# 按命中频次降序输出
for stack, count in sorted(stacks.items(), key=lambda x: x[1], reverse=True):
    print("==================================================")
    print(f"🔥 命中次数: {count}")
    print(f"调用栈:\n{stack}")
' "$FILTER_INPUT"

echo -e "\n🧹 正在清理探针和临时文件..."
perf probe -q -d "$NAME_START" > /dev/null 2>&1
rm -f perf.data

echo "✨ 完成！"