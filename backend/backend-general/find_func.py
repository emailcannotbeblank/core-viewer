#!/usr/bin/env python3
"""
Resolve a user-entered function name to a perf-safe ELF symbol.

The script uses nm for symbol candidates and addr2line for source locations.
When multiple functions have the same short name, config hints are used to pick
the closest match.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


TEXT_SYMBOL_TYPES = {"t", "T", "w", "W"}


@dataclass
class Symbol:
    raw: str
    demangled: str
    addr: int
    source_path: str = ""
    source_line: str = ""
    addr2line_name: str = ""


def run_cmd(cmd, timeout=120):
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        print(f"[ERROR] command failed: {' '.join(cmd)}: {exc}", file=sys.stderr)
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


def parse_posix_nm_line(line):
    parts = line.rstrip("\n").rsplit(None, 3)
    if len(parts) == 4:
        name, sym_type, value, _size = parts
    elif len(parts) == 3:
        name, sym_type, value = parts
    else:
        return None

    if sym_type not in TEXT_SYMBOL_TYPES:
        return None

    try:
        addr = int(value, 16)
    except ValueError:
        return None

    return name, sym_type, addr


def get_symbols(binary):
    raw = run_cmd(["nm", "-a", "--format=posix", binary])
    demangled = run_cmd(["nm", "-aC", "--format=posix", binary])
    if raw.returncode != 0:
        print(raw.stderr.strip() or raw.stdout.strip(), file=sys.stderr)
        return []
    if demangled.returncode != 0:
        print(demangled.stderr.strip() or demangled.stdout.strip(), file=sys.stderr)
        return []

    symbols = []
    for raw_line, demangled_line in zip(raw.stdout.splitlines(), demangled.stdout.splitlines()):
        raw_parsed = parse_posix_nm_line(raw_line)
        demangled_parsed = parse_posix_nm_line(demangled_line)
        if not raw_parsed or not demangled_parsed:
            continue

        raw_name, _raw_type, raw_addr = raw_parsed
        demangled_name, _demangled_type, demangled_addr = demangled_parsed
        if raw_addr != demangled_addr:
            continue

        symbols.append(Symbol(raw=raw_name, demangled=demangled_name, addr=raw_addr))

    return symbols


def short_name(name):
    if "::" in name:
        return name.rsplit("::", 1)[-1]
    if "." in name:
        return name.rsplit(".", 1)[-1]
    return name


def candidate_name_score(symbol, query):
    if symbol.raw == query:
        return 1000
    if symbol.demangled == query:
        return 950
    if symbol.demangled.endswith(f"::{query}") or symbol.demangled.endswith(f".{query}"):
        return 850
    if short_name(symbol.demangled) == query:
        return 800
    return 0


def resolve_sources(binary, candidates):
    if not candidates:
        return

    addrs = [f"0x{sym.addr:x}" for sym in candidates]
    result = run_cmd(["addr2line", "-e", binary, "-f", "-C", *addrs], timeout=300)
    if result.returncode != 0:
        print(result.stderr.strip() or result.stdout.strip(), file=sys.stderr)
        return

    lines = result.stdout.splitlines()
    for index, symbol in enumerate(candidates):
        func_idx = index * 2
        file_idx = func_idx + 1
        if file_idx >= len(lines):
            break

        symbol.addr2line_name = lines[func_idx].strip()
        location = lines[file_idx].strip()
        if not location or location == "??:0":
            continue

        path, sep, line_no = location.rpartition(":")
        if sep and line_no.isdigit():
            symbol.source_path = path
            symbol.source_line = line_no
        else:
            symbol.source_path = location


def config_resolution_section(config):
    for key in ("symbol_resolution", "go", "rust"):
        value = config.get(key)
        if isinstance(value, dict):
            return value
    return {}


def load_config(config_path):
    if not config_path:
        return {}
    try:
        with open(config_path, "r", encoding="utf-8") as file_obj:
            return json.load(file_obj)
    except Exception as exc:
        print(f"[ERROR] 读取配置失败 {config_path}: {exc}", file=sys.stderr)
        return {}


def hints_for(config, query, explicit_hints):
    if explicit_hints is not None:
        try:
            hints = json.loads(explicit_hints)
        except json.JSONDecodeError as exc:
            raise ValueError(f"路径提示 JSON 解析失败: {exc}") from exc
        if not isinstance(hints, list):
            raise ValueError("路径提示必须是 JSON 数组")
        return [str(item) for item in hints]

    section = config_resolution_section(config)
    func_hints = section.get("func_hints", {})
    default_hints = section.get("default_hints", [])
    if isinstance(func_hints, dict) and isinstance(func_hints.get(query), list):
        return [str(item) for item in func_hints[query]]
    if isinstance(default_hints, list):
        return [str(item) for item in default_hints]
    return []


def hint_components(hint):
    parts = []
    for part in PurePosixPath(hint).parts:
        parts.extend(re.split(r"::|\\.", part))
    return [part for part in parts if part and part not in ("/", ".")]


def relative_source_path(source_path, source_dir):
    if not source_path or not source_dir:
        return ""
    try:
        return str(Path(source_path).resolve().relative_to(Path(source_dir).resolve()))
    except Exception:
        return ""


def hint_score(symbol, hints, source_dir):
    if not hints:
        return 0

    source_rel = relative_source_path(symbol.source_path, source_dir)
    source_base = os.path.basename(symbol.source_path)
    search_text = " ".join(
        item
        for item in (
            symbol.raw,
            symbol.demangled,
            symbol.addr2line_name,
            symbol.source_path,
            source_rel,
            source_base,
        )
        if item
    ).lower()

    best = 0
    for index, hint in enumerate(hints):
        hint_lower = hint.lower()
        score = max(0, 120 - index * 5)

        if hint_lower and hint_lower in search_text:
            score += 300

        components = hint_components(hint)
        matched_components = 0
        for component in components:
            if component.lower() in search_text:
                matched_components += 1

        if components:
            score += matched_components * 50
            if matched_components == len(components):
                score += 200

        if source_base and hint_lower.endswith(source_base.lower()):
            score += 100

        best = max(best, score)

    return best


def describe_symbol(symbol):
    location = symbol.source_path
    if symbol.source_line:
        location = f"{location}:{symbol.source_line}"
    if not location:
        location = "unknown source"
    return f"{symbol.demangled} -> {symbol.raw} [{location}]"


def find_function(binary, query, hints, source_dir=""):
    print(f"[INFO] 扫描符号: {binary}", file=sys.stderr)
    symbols = get_symbols(binary)
    print(f"[INFO] 共找到 {len(symbols)} 个文本符号", file=sys.stderr)

    candidates = [symbol for symbol in symbols if candidate_name_score(symbol, query) > 0]
    print(f"[INFO] 名称匹配 '{query}' 的候选有 {len(candidates)} 个", file=sys.stderr)

    if not candidates:
        return None

    resolve_sources(binary, candidates)

    scored = []
    for symbol in candidates:
        name_score = candidate_name_score(symbol, query)
        score = name_score + hint_score(symbol, hints, source_dir)
        scored.append((score, symbol))

    scored.sort(key=lambda item: item[0], reverse=True)
    best_score = scored[0][0]
    best = [symbol for score, symbol in scored if score == best_score]

    print(f"[INFO] 使用 hints: {json.dumps(hints, ensure_ascii=False)}", file=sys.stderr)
    for score, symbol in scored[:20]:
        print(f"[INFO] score={score} {describe_symbol(symbol)}", file=sys.stderr)

    if len(best) == 1:
        return best[0].raw

    print("[ERROR] 最佳匹配不唯一，请在 config.json 中增加更具体的 func_hints:", file=sys.stderr)
    for symbol in best[:20]:
        print(f"  {describe_symbol(symbol)}", file=sys.stderr)
    if len(best) > 20:
        print(f"  ... 还有 {len(best) - 20} 个同分候选未显示", file=sys.stderr)
    return None


def main():
    parser = argparse.ArgumentParser(description="Resolve a short function name to an ELF symbol")
    parser.add_argument("-c", "--config", help="config.json path")
    parser.add_argument("-b", "--binary", help="binary path")
    parser.add_argument("-f", "--func", required=True, help="user-entered function name")
    parser.add_argument("-l", "--hints", help="JSON array of path/name hints")
    args = parser.parse_args()

    config = load_config(args.config)
    section = config_resolution_section(config)

    binary = args.binary or section.get("binary_path") or config.get("binary_path")
    source_dir = section.get("source_dir") or config.get("source_dir") or ""
    if not binary:
        print(args.func)
        return 0
    if not os.path.isfile(binary):
        print(f"[ERROR] binary_path 不存在: {binary}", file=sys.stderr)
        return 1

    try:
        hints = hints_for(config, args.func, args.hints)
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    resolved = find_function(binary, args.func, hints, source_dir)
    if not resolved:
        return 1

    print(resolved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
