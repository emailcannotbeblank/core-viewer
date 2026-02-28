#!/bin/bash

# =======================================================
# 脚本名称: latency_multi_stack_and.sh
# 功能: 计算时延，要求调用栈必须【同时包含】指定的多个函数 (AND逻辑)
# 模式: 全系统监控 (System-wide)
# =======================================================

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本，perf 需要 root 权限。"
  exit 1
fi

# 【修改点 1】放宽参数校验，允许接收 4 个参数
if [ "$#" -lt 3 ]; then
    echo "用法: $0 <探针1> <探针2> \"函数1 函数2 ...\" [采样时长秒数]"
    echo "示例: $0 'ksm1=follow_page_pte:4' 'ksm2=follow_page_pte:19' \"cmp_and_merge_page\" 5"
    exit 1
fi

DEF_START=$1
DEF_END=$2
FILTER_INPUT=$3
# 【修改点 2】读取第 4 个参数作为休眠时间，如果没传则默认使用 4 秒
SLEEP_TIME=${4:-4}

# -------------------------------------------------------
# 探针名称解析
# -------------------------------------------------------
NAME_START=$(echo "$DEF_START" | cut -d= -f1)
NAME_END=$(echo "$DEF_END" | cut -d= -f1)

# 处理 %return 后缀
if [[ "$DEF_START" == *"%return"* ]]; then EVENT_START="probe:${NAME_START}__return"; else EVENT_START="probe:${NAME_START}"; fi
if [[ "$DEF_END" == *"%return"* ]]; then EVENT_END="probe:${NAME_END}__return"; else EVENT_END="probe:${NAME_END}"; fi

# -------------------------------------------------------
# 清理与添加探针
# -------------------------------------------------------
echo "[1/5] 正在清理旧探针..."
perf probe -q -d "$NAME_START" > /dev/null 2>&1
perf probe -q -d "${NAME_START}__return" > /dev/null 2>&1
perf probe -q -d "$NAME_END" > /dev/null 2>&1
perf probe -q -d "${NAME_END}__return" > /dev/null 2>&1

echo "[2/5] 正在添加新探针..."
perf probe -q -a "$DEF_START" || { echo "❌ 添加探针1失败"; exit 1; }
perf probe -q -a "$DEF_END" || { echo "❌ 添加探针2失败"; exit 1; }

echo "--- 配置确认 ---"
echo "开始: $EVENT_START"
echo "结束: $EVENT_END"
echo "过滤: 调用栈必须同时包含 [ $FILTER_INPUT ]"
echo "时长: $SLEEP_TIME 秒"
echo "----------------"

# -------------------------------------------------------
# 录制
# -------------------------------------------------------
# 【修改点 3】打印日志和执行时使用变量 $SLEEP_TIME
echo "[3/5] 开始录制 (全系统监控, ${SLEEP_TIME}秒)..."
perf record -a -g -e "$EVENT_START,$EVENT_END" -- sleep "$SLEEP_TIME" > /dev/null 2>&1

# -------------------------------------------------------
# 数据解析 (AWK AND 逻辑)
# 下面 AWK 代码不需要改动，保持你原来的原样即可
# -------------------------------------------------------
echo "[4/5] 正在分析数据 (Strict AND Mode)..."

# 使用 perf script 默认输出，交给 awk 处理
# 替换你的 perf script 这一大段 awk 代码
perf script --ns 2>/dev/null | awk -v start_ev="$EVENT_START" \
                       -v end_ev="$EVENT_END" \
                       -v filters="$FILTER_INPUT" '
BEGIN {
    # 【新增逻辑】：判断是否为星号无过滤模式
    if (filters == "*") {
        skip_filter = 1
        n_filters = 0
    } else {
        skip_filter = 0
        n_filters = split(filters, f_arr, " ")
    }
    
    count = 0
    sum = 0
    min = ""
    max = 0
}

# === 匹配事件头 (行首非空格) ===
/^[^\t ]/ {
    # 结算上一个 TID
    if (checking[last_tid]) {
        # 【新增逻辑】：如果 skip_filter 为 1，直接算作集齐
        if (skip_filter == 1) {
            all_found = 1
        } else {
            all_found = 1
            for (i=1; i<=n_filters; i++) {
                if (!has_found[last_tid, i]) {
                    all_found = 0
                    break
                }
            }
        }
        
        if (all_found) {
            valid_ts[last_tid] = pending_ts[last_tid]
        }
        checking[last_tid] = 0
    }

    last_tid = tid = $2
    ts_str = $4
    sub(/:/, "", ts_str)
    
    if ($0 ~ start_ev) {
        pending_ts[tid] = ts_str
        checking[tid] = 1
        if (skip_filter == 0) {
            for (i=1; i<=n_filters; i++) has_found[tid, i] = 0
        }
    } 
    else if ($0 ~ end_ev) {
        checking[tid] = 0
        if (valid_ts[tid] > 0) {
            diff = (ts_str - valid_ts[tid]) * 1000000000
            count++
            sum += diff
            if (min == "" || diff < min) min = diff
            if (diff > max) max = diff
            delete valid_ts[tid]
        }
    }
    else {
        checking[tid] = 0
    }
}

# === 匹配调用栈行 ===
/^[ \t]+/ {
    # 【新增逻辑】：如果不跳过过滤，才去搜索函数名
    if (checking[tid] && skip_filter == 0) {
        for (i=1; i<=n_filters; i++) {
            if (!has_found[tid, i] && index($0, f_arr[i])) {
                has_found[tid, i] = 1
            }
        }
    }
}

END {
    if (checking[last_tid]) {
        if (skip_filter == 1) {
            all_found = 1
        } else {
            all_found = 1
            for (i=1; i<=n_filters; i++) {
                if (!has_found[last_tid, i]) { all_found = 0; break; }
            }
        }
        if (all_found) valid_ts[last_tid] = pending_ts[last_tid]
    }

    if (count > 0) {
        printf "\n=== 最终结果 ===\n"
        if (skip_filter) {
            printf "过滤器: [ 无过滤 (匹配全部) ]\n"
        } else {
            printf "过滤器: [ %s ] (AND Filtered)\n", filters
        }
        printf "样本数: %d\n", count
        printf "平均值: %.2f ns\n", sum / count
        printf "最小值: %.2f ns\n", min
        printf "最大值: %.2f ns\n", max
    } else {
        printf "\n[警告] 未找到匹配样本。\n"
    }
}'

# -------------------------------------------------------
# 清理工作
# -------------------------------------------------------
echo "🧹 正在清理探针和临时文件..."
perf probe -q -d "$NAME_START" > /dev/null 2>&1
perf probe -q -d "${NAME_START}__return" > /dev/null 2>&1
perf probe -q -d "$NAME_END" > /dev/null 2>&1
perf probe -q -d "${NAME_END}__return" > /dev/null 2>&1
# rm -f perf.data

echo "[5/5] ✨ 完成！"