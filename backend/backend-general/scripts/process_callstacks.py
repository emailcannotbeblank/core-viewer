#!/usr/bin/env python3
import re
import sys
from collections import Counter


HEADER_RE = re.compile(r"^\s*\S+\s+\d+\s+\[[^\]]+\]\s+[0-9.]+:\s+([^:]+(?::[^:]+)*):")


def parse_filters(raw: str) -> list[str]:
    if not raw or raw == "*":
        return []
    return [item.strip() for item in re.split(r"[,;]", raw) if item.strip()]


def stack_matches(stack: tuple[str, ...], filters: list[str]) -> bool:
    if not filters:
        return True
    text = "\n".join(stack)
    return any(item in text for item in filters)


def normalize_stack_line(line: str) -> str:
    line = line.strip()
    line = re.sub(r"^(?:0x)?[0-9a-fA-F]{6,}\s+", "", line)
    line = re.sub(r"^\[unknown\]\s+", "", line)
    return line


def flush(stack: list[str], counter: Counter, filters: list[str]) -> None:
    normalized = tuple(item for item in (normalize_stack_line(x) for x in stack) if item)
    if normalized and stack_matches(normalized, filters):
        counter[normalized] += 1


def main() -> int:
    if len(sys.argv) < 4:
        print("用法: process_callstacks.py <perf_script.txt> <目标函数> <调用栈过滤|*>")
        return 1

    script_file = sys.argv[1]
    target_func = sys.argv[2]
    filters = parse_filters(sys.argv[3])

    counter: Counter[tuple[str, ...]] = Counter()
    current_stack: list[str] = []
    in_event = False
    total_events = 0

    with open(script_file, "r", errors="replace") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if HEADER_RE.match(line):
                if in_event:
                    flush(current_stack, counter, filters)
                current_stack = []
                in_event = True
                total_events += 1
                continue

            if not in_event:
                continue

            if not line.strip():
                flush(current_stack, counter, filters)
                current_stack = []
                in_event = False
                continue

            current_stack.append(line)

    if in_event:
        flush(current_stack, counter, filters)

    print("=== 调用栈聚合结果 ===")
    print(f"目标函数: {target_func}")
    print(f"原始样本数: {total_events}")
    print(f"匹配样本数: {sum(counter.values())}")
    print(f"不同调用栈数量: {len(counter)}")
    if filters:
        print(f"调用栈过滤: {', '.join(filters)}")
    print("")

    if not counter:
        print("[警告] 未找到有效调用栈样本。")
        return 0

    for idx, (stack, count) in enumerate(counter.most_common(), 1):
        print(f"--- 调用栈 #{idx} ---")
        print(f"🔥 命中次数: {count}")
        for frame in stack:
            print(f"  {frame}")
        print("")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
