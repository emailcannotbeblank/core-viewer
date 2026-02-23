#!/bin/bash

# ==============================================================================
# perf 函数级行覆盖率统计脚本 (带有调用栈过滤功能)
# ==============================================================================

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
# 2. 批量插入探针 (区分能否打上探针)
# ==========================================
echo "[2/6] 正在清理旧探针并批量添加新探针..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null

# 清空并准备记录成功打上探针的行号文件
rm -f /tmp/valid_probes.txt
touch /tmp/valid_probes.txt

VALID_PROBES=0
for OFFSET in $OFFSETS; do
  PROBE_NAME="${TARGET_FUNC}_line_${OFFSET}"
  # 尝试添加探针，屏蔽标准错误以忽略那些不能打断点的行（如括号、变量声明）
  if perf probe -q -a "${PROBE_NAME}=${TARGET_FUNC}:${OFFSET}" 2>/dev/null; then
    VALID_PROBES=$((VALID_PROBES + 1))
    echo "$OFFSET" >> /tmp/valid_probes.txt
  fi
done

echo "✅ 成功插入了 $VALID_PROBES 个有效探针。"

if [ "$VALID_PROBES" -eq 0 ]; then
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
# 4. 解析数据并提取调用栈
# ==========================================
echo "[4/6] 正在解析调用栈 (perf script)..."
perf script > /tmp/perf_script.txt

# ==========================================
# 5. 过滤目标调用栈并统计次数
# ==========================================
echo "[5/6] 正在通过 awk 过滤包含 '$CALLER_FUNC' 的记录并统计..."
awk -v caller="$CALLER_FUNC" -v target="$TARGET_FUNC" '
BEGIN { current_offset = ""; has_caller = 0; }

# 匹配事件头部，例如：kworker/u16:1 1234 [001] 100.00: probe:follow_page_mask_line_12:
/^[^\t ]/ {
    # 如果上一个事件处理完毕，且调用栈中包含过滤函数，则计数 +1
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
        
        # 检查这行是否成功打上了探针 (-xw 确保精准匹配数字)
        is_valid=$(grep -xw "$offset" /tmp/valid_probes.txt 2>/dev/null)
        
        if [ -z "$is_valid" ]; then
            # 没打上探针的行（如变量声明），显示灰色的 N/A
            printf "\e[90m[ %8s ] %-4s %s\e[0m\n" "N/A" "$offset" "$code"
        elif [ "$count" -gt 0 ]; then
            # 打上了且有命中，显示绿色的具体次数
            printf "\e[32m[ %8s ]\e[0m %-4s %s\n" "$count" "$offset" "$code"
        else
            # 打上了但没被执行到，显示默认颜色的 0
            printf "[ %8s ] %-4s %s\n" "0" "$offset" "$code"
        fi
    else
        # 打印函数头尾的非代码行 (如静态函数声明和闭合的大括号)
        echo "               $line"
    fi
done < /tmp/perf_lines.txt

echo "----------------------------------------------------------------------"

# ==========================================
# 清理工作
# ==========================================
echo "🧹 正在清理探针和临时文件..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null
rm -f /tmp/perf_lines.txt /tmp/perf_script.txt /tmp/perf_counts.txt /tmp/valid_probes.txt perf.data
echo "✨ 完成！"