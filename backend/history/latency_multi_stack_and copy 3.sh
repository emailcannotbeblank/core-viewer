#!/bin/bash

# =======================================================
# 脚本名称: latency_percentiles.sh
# 功能: 计算时延并展示 P50, P90, P95, P99 分位数分布
# =======================================================

# 添加非调用栈前留念

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本，perf 需要 root 权限。"
  exit 1
fi

if [ "$#" -lt 3 ]; then
    echo "用法: $0 <探针1> <探针2> \"函数1 函数2 ...\" [采样时长秒数]"
    echo "示例: $0 'ksm1=follow_page_pte:4' 'ksm2=follow_page_pte:19' \"cmp_and_merge_page\" 5"
    exit 1
fi

DEF_START=$1
DEF_END=$2
FILTER_INPUT=$3
SLEEP_TIME=${4:-4}

# -------------------------------------------------------
# 探针名称解析
# -------------------------------------------------------
NAME_START=$(echo "$DEF_START" | cut -d= -f1)
NAME_END=$(echo "$DEF_END" | cut -d= -f1)

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
echo "[3/5] 开始录制 (全系统监控, ${SLEEP_TIME}秒)..."
perf record -a -g -e "$EVENT_START,$EVENT_END" -- sleep "$SLEEP_TIME" > /dev/null 2>&1

# -------------------------------------------------------
# 数据解析 (AWK 数组排序与分位数计算)
# -------------------------------------------------------
echo "[4/5] 正在分析数据并计算分位数..."

perf script --ns 2>/dev/null | awk -v start_ev="$EVENT_START" \
                       -v end_ev="$EVENT_END" \
                       -v filters="$FILTER_INPUT" '
BEGIN {
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

/^[^\t ]/ {
    if (checking[last_tid]) {
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
        
        # 计算时延
        if (valid_ts[tid] > 0) {
            diff = (ts_str - valid_ts[tid]) * 1000000000
            
            # 【核心修改点】：不再固定丢弃，收集所有大于 0 的有效数据存入数组
            if (diff > 0) {
                count++
                latencies[count] = diff
                sum += diff
                if (min == "" || diff < min) min = diff
                if (diff > max) max = diff
            }
            delete valid_ts[tid]
        }
    }
    else {
        checking[tid] = 0
    }
}

/^[ \t]+/ {
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
        # 使用 GNU AWK 内置的 asort 函数对数组进行升序排序
        asort(latencies)
        
        # 计算各分位数的索引值 (四舍五入或向上取整)
        p50_idx = int(count * 0.50) == 0 ? 1 : int(count * 0.50)
        p90_idx = int(count * 0.90) == 0 ? 1 : int(count * 0.90)
        p95_idx = int(count * 0.95) == 0 ? 1 : int(count * 0.95)
        p99_idx = int(count * 0.99) == 0 ? 1 : int(count * 0.99)

        printf "\n=== 最终结果 (分布统计) ===\n"
        if (skip_filter) {
            printf "过滤器: [ 无过滤 (匹配全部) ]\n"
        } else {
            printf "过滤器: [ %s ] (AND Filtered)\n", filters
        }
        printf "有效样本总数: %d\n\n", count
        
        printf "--- 统计摘要 ---\n"
        printf "平均值 (Avg): %10.2f ns\n", sum / count
        printf "最小值 (Min): %10.2f ns\n", min
        printf "最大值 (Max): %10.2f ns\n\n", max

        printf "--- 分位数分布 (Percentiles) ---\n"
        printf "P50 (中位数): %10.2f ns  <-- 真实的日常性能\n", latencies[p50_idx]
        printf "P90 (90分位): %10.2f ns\n", latencies[p90_idx]
        printf "P95 (95分位): %10.2f ns  <-- 关注长尾/毛刺现象\n", latencies[p95_idx]
        printf "P99 (99分位): %10.2f ns\n", latencies[p99_idx]
        
    } else {
        printf "\n[警告] 未找到匹配样本。\n"
    }
}'

# -------------------------------------------------------
# 清理工作
# -------------------------------------------------------
echo -e "\n🧹 正在清理探针和临时文件..."
perf probe -q -d "$NAME_START" > /dev/null 2>&1
perf probe -q -d "${NAME_START}__return" > /dev/null 2>&1
perf probe -q -d "$NAME_END" > /dev/null 2>&1
perf probe -q -d "${NAME_END}__return" > /dev/null 2>&1
rm -f perf.data

echo "[5/5] ✨ 完成！"