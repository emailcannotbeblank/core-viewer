#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本，perf 需要 root 权限。"
  exit 1
fi

# 参数检查
if [ "$#" -lt 2 ]; then
  echo "用法: $0 <目标函数名> <调用栈过滤函数名> [采样时间(秒)]"
  echo "示例: $0 follow_page_mask follow_page 5"
  exit 1
fi

TARGET_FUNC=$1
CALLER_FUNC=$2
SLEEP_TIME=${3:-5} # 默认采样 5 秒

echo "🔍 目标函数: $TARGET_FUNC"
echo "🎯 过滤调用: 仅统计来自 $CALLER_FUNC 的调用"
echo "⏳ 采样时间: $SLEEP_TIME 秒"
echo "--------------------------------------------------"

# ==========================================
# 1. 获取目标函数的代码行和相对偏移量
# ==========================================
echo "[1/6] 正在获取 $TARGET_FUNC 的源码行信息..."
perf probe -L "$TARGET_FUNC" > /tmp/perf_lines.txt

# 提取代码左侧的数字（偏移量行号）
OFFSETS=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+' /tmp/perf_lines.txt | awk '{print $1}')

if [ -z "$OFFSETS" ]; then
  echo "❌ 无法获取 $TARGET_FUNC 的源码行，请检查函数名或 Debug 符号。"
  exit 1
fi

# ==========================================
# 2. 批量插入探针
# ==========================================
echo "[2/6] 正在清理旧探针并批量添加新探针..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null

VALID_PROBES=()
for OFFSET in $OFFSETS; do
  PROBE_NAME="${TARGET_FUNC}_line_${OFFSET}"
  # 尝试添加探针，屏蔽标准错误以忽略那些不能打断点的行（如变量声明行）
  if perf probe -q -a "${PROBE_NAME}=${TARGET_FUNC}:${OFFSET}" 2>/dev/null; then
    VALID_PROBES+=("$OFFSET")
  fi
done

echo "✅ 成功插入了 ${#VALID_PROBES[@]} 个有效探针。"

if [ ${#VALID_PROBES[@]} -eq 0 ]; then
  echo "❌ 未能成功插入任何探针，退出。"
  exit 1
fi

# ==========================================
# 3. 录制带有调用栈的数据
# ==========================================
echo "[3/6] 开始录制数据 (perf record -g)，请耐心等待 $SLEEP_TIME 秒..."
# 仅抓取我们刚刚设置的这些探针事件
perf record -g -a -e "probe:${TARGET_FUNC}_line_*" -- sleep "$SLEEP_TIME" > /dev/null 2>&1

# ==========================================
# 4. 解析数据并过滤调用栈
# ==========================================
echo "[4/6] 正在解析调用栈 (perf script)..."
perf script > /tmp/perf_script.txt

echo "[5/6] 正在通过 awk 过滤包含 '$CALLER_FUNC' 的记录并统计..."
awk -v caller="$CALLER_FUNC" -v target="$TARGET_FUNC" '
BEGIN { current_offset = ""; has_caller = 0; }

# 匹配事件头部，例如：kworker/u16:1 1234 [001] 100.00: probe:follow_page_mask_line_12:
/^[^\t ]/ {
    # 如果上一个事件处理完毕，且调用栈中包含目标函数，则计数 +1
    if (current_offset != "" && has_caller) {
        counts[current_offset]++;
    }
    
    # 重置状态
    current_offset = "";
    has_caller = 0;

    # 提取当前事件的偏移量行号
    search_str = "probe:" target "_line_"
    idx = index($0, search_str)
    if (idx > 0) {
        str = substr($0, idx + length(search_str))
        match(str, /^[0-9]+/)
        if (RSTART > 0) {
            current_offset = substr(str, RSTART, RLENGTH)
        }
    }
}

# 匹配调用栈（以空格或 Tab 开头的行）
/^[ \t]/ {
    if (current_offset != "" && index($0, caller) > 0) {
        has_caller = 1; # 发现目标调用函数！
    }
}

END {
    # 处理文件末尾的最后一个事件
    if (current_offset != "" && has_caller) {
        counts[current_offset]++;
    }
    # 输出统计结果到临时文件
    for (o in counts) {
        print o, counts[o];
    }
}' /tmp/perf_script.txt > /tmp/perf_counts.txt

# ==========================================
# 6. 格式化输出结果
# ==========================================
echo ""
echo "🎯 统计结果 (目标: $TARGET_FUNC, 仅限来自 $CALLER_FUNC 的调用):"
echo "----------------------------------------------------------------------"
echo "[ 命中次数 ] 行号   源码"
echo "----------------------------------------------------------------------"

# 逐行读取最初的 perf probe -L 输出，将统计次数拼接到前面
while IFS= read -r line; do
    # 如果这一行以数字（偏移量）开头
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*) ]]; then
        offset="${BASH_REMATCH[1]}"
        code="${BASH_REMATCH[2]}"
        
        # 查找该偏移量对应的命中次数
        count=$(awk -v off="$offset" '$1 == off {print $2}' /tmp/perf_counts.txt)
        if [ -z "$count" ]; then
            count="0"
        fi
        
        # 打印高亮次数 (绿色表示有命中)
        if [ "$count" -gt 0 ]; then
             printf "\e[32m[ %8s ]\e[0m %-4s %s\n" "$count" "$offset" "$code"
        else
             printf "[ %8s ] %-4s %s\n" "-" "$offset" "$code"
        fi
    else
        # 打印函数头尾的非代码行
        echo "               $line"
    fi
done < /tmp/perf_lines.txt

echo "----------------------------------------------------------------------"

# ==========================================
# 清理工作
# ==========================================
echo "🧹 正在清理探针和临时文件..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null
rm -f /tmp/perf_lines.txt /tmp/perf_script.txt /tmp/perf_counts.txt perf.data
echo "✨ 完成！"