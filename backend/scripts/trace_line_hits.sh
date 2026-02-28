#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本，perf 需要 root 权限。"
  exit 1
fi

if [ "$#" -lt 2 ]; then
  echo "用法: $0 <目标函数名> <调用栈过滤函数名或*> [采样时间(秒)]"
  echo "示例: $0 follow_page ~cmp_and_merge_page 5"
  exit 1
fi

TARGET_FUNC=$1
CALLER_FUNC=$2
SLEEP_TIME=${3:-5}

echo "🔍 目标函数: $TARGET_FUNC"
# 【修改点 1】：增加对 ~ 前缀的识别和日志输出
if [ "$CALLER_FUNC" = "*" ]; then
  echo "🎯 过滤调用: 统计所有来源"
elif [[ "$CALLER_FUNC" == \~* ]]; then
  echo "🎯 过滤调用: 剔除来自 ${CALLER_FUNC#~} 的调用 (反向过滤)"
else
  echo "🎯 过滤调用: 仅统计来自 $CALLER_FUNC 的调用"
fi
echo "⏳ 采样时间: $SLEEP_TIME 秒"
echo "--------------------------------------------------"

echo "[1/6] 正在获取 $TARGET_FUNC 的源码行信息..."
perf probe -L "$TARGET_FUNC" > /tmp/perf_lines.txt
OFFSETS=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+' /tmp/perf_lines.txt | awk '{print $1}')

if [ -z "$OFFSETS" ]; then
  echo "❌ 无法获取 $TARGET_FUNC 的源码行，请检查函数名或 Debug 符号。"
  exit 1
fi

echo "[2/6] 正在清理旧探针并批量添加新探针..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null
rm -f /tmp/valid_probes.txt
touch /tmp/valid_probes.txt

VALID_PROBES=0
for OFFSET in $OFFSETS; do
  PROBE_NAME="${TARGET_FUNC}_line_${OFFSET}"
  
  # 使用 sh -c 包装，彻底隔离段错误信号，防止它污染终端输出
  sh -c "perf probe -q -a '${PROBE_NAME}=${TARGET_FUNC}:${OFFSET}' >/dev/null 2>&1"
  RET=$?
  
  if [ $RET -eq 0 ]; then
    VALID_PROBES=$((VALID_PROBES + 1))
    echo "$OFFSET" >> /tmp/valid_probes.txt
  elif [ $RET -eq 139 ]; then
    # 139 是段错误 (Segfault) 的标准退出码
    echo "⚠️ 警告: perf 解析第 $OFFSET 行时发生段错误崩溃，已自动跳过该行。"
  fi
done

echo "✅ 成功插入了 $VALID_PROBES 个有效探针。"
if [ "$VALID_PROBES" -eq 0 ]; then
  echo "❌ 未能成功插入任何探针，退出。"
  exit 1
fi

echo "[3/6] 开始录制数据 (perf record -g)，请耐心等待 $SLEEP_TIME 秒..."
perf record -g -a -e "probe:${TARGET_FUNC}_line_*" -- sleep "$SLEEP_TIME" > /dev/null 2>&1

echo "[4/6] 正在解析调用栈 (perf script)..."
perf script > /tmp/perf_script.txt

echo "[5/6] 正在分析调用栈并统计命中次数..."
# 【修改点 2】：优化 awk 逻辑，支持正反向过滤
awk -v caller="$CALLER_FUNC" -v target="$TARGET_FUNC" '
function is_valid() {
    if (any_caller) return 1;
    # 如果是 ~ 规则，没找到 has_caller==0 才算合法
    if (is_neg) return (has_caller == 0 ? 1 : 0);
    # 如果是普通规则，找到 has_caller==1 才算合法
    return (has_caller == 1 ? 1 : 0);
}
BEGIN { 
    current_offset = ""; 
    has_caller = 0; 
    any_caller = 0;
    is_neg = 0;
    search_target = caller;

    if (caller == "*") {
        any_caller = 1;
    } else if (substr(caller, 1, 1) == "~") {
        is_neg = 1;
        search_target = substr(caller, 2); # 剔除掉 ~ 符号进行匹配
    }
}

/^[^\t ]/ {
    # 结算上一条记录
    if (current_offset != "" && is_valid()) { counts[current_offset]++; }
    
    # 初始化新记录
    current_offset = ""; has_caller = 0;
    search_str = "probe:" target "_line_"
    idx = index($0, search_str)
    if (idx > 0) {
        str = substr($0, idx + length(search_str))
        match(str, /^[0-9]+/)
        if (RSTART > 0) { current_offset = substr(str, RSTART, RLENGTH) }
    }
}
/^[ \t]/ {
    if (current_offset != "" && !any_caller) {
        if (index($0, search_target) > 0) { has_caller = 1; }
    }
}
END {
    # 结算最后一条记录
    if (current_offset != "" && is_valid()) { counts[current_offset]++; }
    for (o in counts) { print o, counts[o]; }
}' /tmp/perf_script.txt > /tmp/perf_counts.txt

echo ""
echo "🎯 统计结果:"
echo "----------------------------------------------------------------------"
echo "[ 命中次数 ] 行号   源码"
echo "----------------------------------------------------------------------"

while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*) ]]; then
        offset="${BASH_REMATCH[1]}"
        code="${BASH_REMATCH[2]}"
        count=$(awk -v off="$offset" '$1 == off {print $2}' /tmp/perf_counts.txt)
        if [ -z "$count" ]; then count="0"; fi
        
        is_valid=$(grep -xw "$offset" /tmp/valid_probes.txt 2>/dev/null)
        if [ -z "$is_valid" ]; then
            printf "[   N/A    ] %-4s %s\n" "$offset" "$code"
        elif [ "$count" -gt 0 ]; then
            printf "[ %8s ] %-4s %s\n" "$count" "$offset" "$code"
        else
            printf "[        0 ] %-4s %s\n" "$offset" "$code"
        fi
    else
        echo "               $line"
    fi
done < /tmp/perf_lines.txt
echo "----------------------------------------------------------------------"

echo "🧹 正在清理探针和临时文件..."
perf probe -q -d "${TARGET_FUNC}_line_*" 2>/dev/null
rm -f /tmp/perf_lines.txt /tmp/perf_script.txt /tmp/perf_counts.txt /tmp/valid_probes.txt
rm -f perf.data
echo "✨ 完成！"