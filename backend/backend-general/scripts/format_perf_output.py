#!/usr/bin/env python3
import argparse
import re
import sys


STAT_ROW_RE = re.compile(r"(\[\s*(?:\d+|N/A|-)\s*\]\s*\d+\s+)")
BROKEN_STAT_RE = re.compile(r"\[\s*\n\s*([\dN/A-]+)\s*\n\s*\]")
SOURCE_ROW_AFTER_CODE_RE = re.compile(r"([;{}*/>])([ \t]{2,}\d+[ \t]+)")


def normalize_newlines(text: str, mode: str = "auto") -> str:
    if not text:
        return text

    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\t", "    ")

    if mode in ("auto", "stat", "path"):
        text = BROKEN_STAT_RE.sub(r"[\1]", text)
        text = STAT_ROW_RE.sub(lambda m: ("\n" if m.start() > 0 and text[m.start() - 1] != "\n" else "") + m.group(1), text)

    if mode in ("auto", "source", "stat", "path"):
        text = SOURCE_ROW_AFTER_CODE_RE.sub(r"\1\n\2", text)

    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize perf/ftrace output before sending it to the frontend.")
    parser.add_argument("--mode", choices=["auto", "source", "stat", "path", "log"], default="auto")
    parser.add_argument("file", nargs="?")
    args = parser.parse_args()

    if args.file:
        with open(args.file, "r", errors="replace") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    sys.stdout.write(normalize_newlines(text, args.mode))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
