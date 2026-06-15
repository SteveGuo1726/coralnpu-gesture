"""量化 strategy8 official trial ELF 在 .text / 热点函数上的机器码差异。"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


SECTION_RE = re.compile(
    r"\[\s*\d+\]\s+(?P<name>\S+)\s+\S+\s+"
    r"(?P<addr>[0-9a-fA-F]+)\s+(?P<offset>[0-9a-fA-F]+)\s+(?P<size>[0-9a-fA-F]+)"
)
SYMBOL_RE = re.compile(
    r"^(?P<addr>[0-9a-fA-F]+)\s+\w+\s+F\s+\S+\s+"
    r"(?P<size>[0-9a-fA-F]+)\s+(?P<name>\S+)$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base_elf", required=True, help="Baseline ELF path.")
    parser.add_argument("--trial_elf", required=True, help="Trial ELF path.")
    parser.add_argument(
        "--symbol_query",
        action="append",
        default=[],
        help="要比较的热点函数名片段，可重复传入。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON 路径。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown 路径。")
    return parser.parse_args()


def run_text(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True, encoding="utf-8")


def load_bytes(path: Path) -> bytes:
    return path.read_bytes()


def find_section(path: Path, section_name: str) -> dict[str, Any]:
    output = run_text(["readelf", "-S", str(path)])
    for line in output.splitlines():
        match = SECTION_RE.search(line)
        if not match:
            continue
        if match.group("name") != section_name:
            continue
        return {
            "name": section_name,
            "addr": int(match.group("addr"), 16),
            "offset": int(match.group("offset"), 16),
            "size": int(match.group("size"), 16),
        }
    raise ValueError(f"未在 {path} 中找到段 {section_name}")


def list_symbols(path: Path) -> list[dict[str, Any]]:
    output = run_text(["objdump", "-t", str(path)])
    rows: list[dict[str, Any]] = []
    for line in output.splitlines():
        match = SYMBOL_RE.match(line.strip())
        if not match:
            continue
        rows.append(
            {
                "addr": int(match.group("addr"), 16),
                "size": int(match.group("size"), 16),
                "name": match.group("name"),
            }
        )
    return rows


def find_symbol(symbols: list[dict[str, Any]], query: str) -> dict[str, Any]:
    matches = [item for item in symbols if query in item["name"]]
    if not matches:
        raise ValueError(f"未找到符号片段: {query}")
    if len(matches) > 1:
        exact = [item for item in matches if item["name"] == query]
        if len(exact) == 1:
            return exact[0]
    return matches[0]


def diff_offsets(base: bytes, trial: bytes, limit: int = 32) -> tuple[int, list[int]]:
    count = 0
    first_offsets: list[int] = []
    min_len = min(len(base), len(trial))
    for index in range(min_len):
        if base[index] != trial[index]:
            count += 1
            if len(first_offsets) < limit:
                first_offsets.append(index)
    tail = abs(len(base) - len(trial))
    if tail:
        count += tail
        start = min_len
        for index in range(start, start + min(tail, max(limit - len(first_offsets), 0))):
            first_offsets.append(index)
    return count, first_offsets


def build_symbol_row(
    query: str,
    base_symbol: dict[str, Any],
    trial_symbol: dict[str, Any],
    text_base: dict[str, Any],
    text_trial: dict[str, Any],
    text_base_bytes: bytes,
    text_trial_bytes: bytes,
) -> dict[str, Any]:
    base_rel = base_symbol["addr"] - text_base["addr"]
    trial_rel = trial_symbol["addr"] - text_trial["addr"]
    base_chunk = text_base_bytes[base_rel : base_rel + base_symbol["size"]]
    trial_chunk = text_trial_bytes[trial_rel : trial_rel + trial_symbol["size"]]
    diff_count, first_offsets = diff_offsets(base_chunk, trial_chunk)
    return {
        "query": query,
        "base_symbol_name": base_symbol["name"],
        "trial_symbol_name": trial_symbol["name"],
        "base_addr": base_symbol["addr"],
        "trial_addr": trial_symbol["addr"],
        "base_size": base_symbol["size"],
        "trial_size": trial_symbol["size"],
        "diff_byte_count": diff_count,
        "first_diff_relative_offsets": first_offsets,
    }


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    base_path = Path(args.base_elf).resolve()
    trial_path = Path(args.trial_elf).resolve()
    base_bytes = load_bytes(base_path)
    trial_bytes = load_bytes(trial_path)
    file_diff_count, file_first_offsets = diff_offsets(base_bytes, trial_bytes)

    text_base = find_section(base_path, ".text")
    text_trial = find_section(trial_path, ".text")
    text_base_bytes = base_bytes[text_base["offset"] : text_base["offset"] + text_base["size"]]
    text_trial_bytes = trial_bytes[text_trial["offset"] : text_trial["offset"] + text_trial["size"]]
    text_diff_count, text_first_offsets = diff_offsets(text_base_bytes, text_trial_bytes)

    base_symbols = list_symbols(base_path)
    trial_symbols = list_symbols(trial_path)
    symbol_rows = []
    for query in args.symbol_query:
        symbol_rows.append(
            build_symbol_row(
                query=query,
                base_symbol=find_symbol(base_symbols, query),
                trial_symbol=find_symbol(trial_symbols, query),
                text_base=text_base,
                text_trial=text_trial,
                text_base_bytes=text_base_bytes,
                text_trial_bytes=text_trial_bytes,
            )
        )

    return {
        "scope": "Strategy8 official trial ELF text diff",
        "base_elf": str(base_path),
        "trial_elf": str(trial_path),
        "file": {
            "base_size": len(base_bytes),
            "trial_size": len(trial_bytes),
            "size_delta": len(trial_bytes) - len(base_bytes),
            "diff_byte_count": file_diff_count,
            "first_diff_offsets": file_first_offsets,
        },
        "text_section": {
            "base_addr": text_base["addr"],
            "trial_addr": text_trial["addr"],
            "base_offset": text_base["offset"],
            "trial_offset": text_trial["offset"],
            "base_size": text_base["size"],
            "trial_size": text_trial["size"],
            "diff_byte_count": text_diff_count,
            "first_diff_offsets": text_first_offsets,
        },
        "symbols": symbol_rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    file_row = report["file"]
    text_row = report["text_section"]
    lines = [
        "# strategy8 official trial ELF 机器码差异量化",
        "",
        f"- baseline ELF：`{report['base_elf']}`",
        f"- trial ELF：`{report['trial_elf']}`",
        "",
        "## 整体文件",
        "",
        f"- baseline 大小：`{file_row['base_size']}`",
        f"- trial 大小：`{file_row['trial_size']}`",
        f"- 大小差值：`{file_row['size_delta']:+}`",
        f"- 全文件 diff 字节数：`{file_row['diff_byte_count']}`",
        f"- 首批 diff 偏移：`{file_row['first_diff_offsets']}`",
        "",
        "## .text 段",
        "",
        f"- baseline `.text` addr：`0x{text_row['base_addr']:x}`",
        f"- baseline `.text` offset：`0x{text_row['base_offset']:x}`",
        f"- baseline `.text` size：`0x{text_row['base_size']:x}`",
        f"- trial `.text` addr：`0x{text_row['trial_addr']:x}`",
        f"- trial `.text` offset：`0x{text_row['trial_offset']:x}`",
        f"- trial `.text` size：`0x{text_row['trial_size']:x}`",
        f"- `.text` diff 字节数：`{text_row['diff_byte_count']}`",
        f"- `.text` 首批 diff 偏移：`{text_row['first_diff_offsets']}`",
        "",
        "## 热点函数",
        "",
        "| 查询片段 | baseline addr | trial addr | baseline size | trial size | diff 字节数 | 首批相对偏移 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in report["symbols"]:
        lines.append(
            "| `{query}` | `0x{base_addr:x}` | `0x{trial_addr:x}` | `0x{base_size:x}` | `0x{trial_size:x}` | {diff} | `{offsets}` |".format(
                query=row["query"],
                base_addr=row["base_addr"],
                trial_addr=row["trial_addr"],
                base_size=row["base_size"],
                trial_size=row["trial_size"],
                diff=row["diff_byte_count"],
                offsets=row["first_diff_relative_offsets"],
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(args)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
