#!/usr/bin/env python3
import ast
import pathlib
import re
import sys


RUN_RE = re.compile(r"dm_snapshot_run_cycles=(\d+)")
COUNTERS_RE = re.compile(r"dm_snapshot_counters=(\{.*\})")


def parse_one(path: pathlib.Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    run_match = RUN_RE.search(text)
    counter_match = COUNTERS_RE.search(text)
    if not run_match or not counter_match:
        return None
    counters = ast.literal_eval(counter_match.group(1))
    return {
        "path": str(path),
        "run_cycles": int(run_match.group(1)),
        "counters": counters,
    }


def main(argv):
    if len(argv) < 2:
        print(
            "用法: analyze_rowhandoff_dm_snapshot_window.py /tmp/rowhandoff_dm_snapshot_*.log",
            file=sys.stderr,
        )
        return 1

    rows = []
    for arg in argv[1:]:
        path = pathlib.Path(arg)
        if not path.exists():
            continue
        row = parse_one(path)
        if row is not None:
            rows.append(row)

    if not rows:
        print("没有可用的完整 dm snapshot 日志。", file=sys.stderr)
        return 2

    rows.sort(key=lambda row: row["run_cycles"])
    last_zero = None
    first_one = None
    for row in rows:
        invalidate = int(row["counters"].get("invalidate", 0))
        if invalidate == 0:
            last_zero = row
        elif first_one is None:
            first_one = row

    for row in rows:
        counters = row["counters"]
        print(
            "cycles={run_cycles} invalidate={invalidate} row_out_y_last={row_out_y_last} "
            "produce={produce} right_edge_done={right_edge_done} hit={hit}".format(
                run_cycles=row["run_cycles"],
                invalidate=counters.get("invalidate"),
                row_out_y_last=counters.get("row_out_y_last"),
                produce=counters.get("produce"),
                right_edge_done=counters.get("right_edge_done"),
                hit=counters.get("hit"),
            )
        )

    print("---")
    if last_zero is not None and first_one is not None:
        print(
            "invalidate 首次出现窗口：({left}, {right}]".format(
                left=last_zero["run_cycles"],
                right=first_one["run_cycles"],
            )
        )
    elif first_one is not None:
        print(f"最早完整日志已出现 invalidate：<= {first_one['run_cycles']}")
    else:
        print("当前完整日志中尚未看到 invalidate=1。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
