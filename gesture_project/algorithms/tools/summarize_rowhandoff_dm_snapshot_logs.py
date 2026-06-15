#!/usr/bin/env python3
import ast
import glob
import pathlib
import re
import sys


LINE_PATTERNS = {
    "run_cycles": re.compile(r"dm_snapshot_run_cycles=(\d+)"),
    "cycles": re.compile(r"dm_snapshot_cycles=(\d+)"),
    "counters": re.compile(r"dm_snapshot_counters=(\{.*\})"),
}


def parse_log(path: pathlib.Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    result = {
        "path": str(path),
        "run_cycles": None,
        "cycles": None,
        "counters": None,
        "complete": False,
    }
    for key, pattern in LINE_PATTERNS.items():
        match = pattern.search(text)
        if match:
            value = match.group(1)
            if key == "counters":
                result[key] = ast.literal_eval(value)
            else:
                result[key] = int(value)
    result["complete"] = (
        result["run_cycles"] is not None
        and result["cycles"] is not None
        and result["counters"] is not None
    )
    return result


def main(argv):
    if len(argv) < 2:
        print("用法: summarize_rowhandoff_dm_snapshot_logs.py /tmp/rowhandoff_dm_snapshot_*.log", file=sys.stderr)
        return 1

    if any(ch in argv[1] for ch in "*?[]"):
        paths = [pathlib.Path(p) for p in sorted(glob.glob(argv[1]))]
    else:
        paths = [pathlib.Path(p) for p in argv[1:]]
    rows = [parse_log(path) for path in paths if path.exists()]
    for row in rows:
        print(f"path={row['path']}")
        print(f"complete={int(row['complete'])}")
        print(f"run_cycles={row['run_cycles']}")
        print(f"cycles={row['cycles']}")
        print(f"counters={row['counters']}")
        print("---")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
