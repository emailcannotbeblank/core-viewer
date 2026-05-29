#!/usr/bin/env python3
import re
import sys
from collections import defaultdict


def ns_from_perf_timestamp(value: str) -> int:
    return int(float(value) * 1_000_000_000)


def parse_filters(raw: str) -> list[str]:
    if not raw or raw == "*":
        return []
    return [item.strip() for item in re.split(r"[,;]", raw) if item.strip()]


def stack_matches(stack: list[str], filters: list[str]) -> bool:
    if not filters:
        return True
    text = "\n".join(stack)
    return any(item in text for item in filters)


def flush_event(event, stacks, starts, latencies, start_event, end_event, filters):
    if event is None:
        return

    name, pid, ts = event
    if start_event in name:
        if stack_matches(stacks, filters):
            starts[pid] = ts
    elif end_event in name and pid in starts:
        diff = ts - starts.pop(pid)
        if diff >= 0:
            latencies.append(diff)


def print_stats(latencies: list[int], matched_pids: int):
    if not latencies:
        print("\n[警告] 未找到匹配调用栈过滤条件的 start/end 事件对。")
        return 1

    latencies.sort()
    count = len(latencies)
    avg = sum(latencies) / count

    def percentile(p: float) -> int:
        idx = int(count * p)
        if idx >= count:
            idx = count - 1
        return latencies[idx]

    print("\n=== 最终结果 (perf record 调用栈过滤 | ns) ===")
    print(f"参与配对的进程数: {matched_pids} 个")
    print(f"有效样本总数: {count} 次\n")
    print("--- 统计摘要 ---")
    print(f"平均值 (Avg): {avg:.2f} ns")
    print(f"最小值 (Min): {latencies[0]:.2f} ns")
    print(f"最大值 (Max): {latencies[-1]:.2f} ns\n")
    print("--- 分位数分布 (Percentiles) ---")
    print(f"P50 (中位数): {percentile(0.50):.2f} ns")
    print(f"P90 (90分位): {percentile(0.90):.2f} ns")
    print(f"P95 (95分位): {percentile(0.95):.2f} ns")
    print(f"P99 (99分位): {percentile(0.99):.2f} ns")
    return 0


def main() -> int:
    if len(sys.argv) < 5:
        print("用法: process_perf_latency.py <perf_script> <start_event> <end_event> <callstack_filter>")
        return 1

    script_file = sys.argv[1]
    start_event = sys.argv[2]
    end_event = sys.argv[3]
    filters = parse_filters(sys.argv[4])

    header_re = re.compile(r"^\s*(\S+)\s+(\d+)\s+\[[^\]]+\]\s+([0-9.]+):\s+([^:]+(?::[^:]+)*):")
    starts: dict[str, int] = {}
    seen_pids = set()
    latencies: list[int] = []
    current_event = None
    current_stack: list[str] = []

    with open(script_file, "r", errors="replace") as f:
        for line in f:
            match = header_re.match(line)
            if match:
                flush_event(current_event, current_stack, starts, latencies, start_event, end_event, filters)
                pid = match.group(2)
                ts = ns_from_perf_timestamp(match.group(3))
                name = match.group(4)
                current_event = (name, pid, ts)
                current_stack = []
                seen_pids.add(pid)
            elif current_event is not None:
                current_stack.append(line.rstrip("\n"))

    flush_event(current_event, current_stack, starts, latencies, start_event, end_event, filters)
    return print_stats(latencies, len(seen_pids))


if __name__ == "__main__":
    raise SystemExit(main())
