"""比较两份单层/多层策略回放，不要求 baseline 必须是 strategy=0。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lhs_json", required=True)
    parser.add_argument("--rhs_json", required=True)
    parser.add_argument("--out_json", required=True)
    parser.add_argument("--out_md", required=True)
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def extract_strategy(report: dict[str, Any]) -> int:
    if "conv3x3_dispatch_strategy" in report:
        return int(report["conv3x3_dispatch_strategy"])
    results = report.get("results", [])
    if results and "conv3x3_dispatch_strategy" in results[0]:
        return int(results[0]["conv3x3_dispatch_strategy"])
    return 0


def build_report(lhs: dict[str, Any], rhs: dict[str, Any]) -> dict[str, Any]:
    lhs_map = {item["layer_name"]: item for item in lhs["results"]}
    rhs_map = {item["layer_name"]: item for item in rhs["results"]}
    rows = []
    for layer_name in sorted(set(lhs_map) & set(rhs_map)):
        left = lhs_map[layer_name]
        right = rhs_map[layer_name]
        rows.append(
            {
                "layer_name": layer_name,
                "lhs_opt_cycles": int(left["opt_cycles"]),
                "rhs_opt_cycles": int(right["opt_cycles"]),
                "rhs_minus_lhs": int(right["opt_cycles"]) - int(left["opt_cycles"]),
                "rhs_over_lhs": float(right["opt_cycles"]) / float(left["opt_cycles"]),
                "rhs_mismatch_count": int(right["mismatch_count"]),
            }
        )
    return {
        "model": lhs.get("model", rhs.get("model", "unknown")),
        "lhs_strategy": extract_strategy(lhs),
        "rhs_strategy": extract_strategy(rhs),
        "rows": rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 两个策略回放直接对比",
        "",
        f"- lhs strategy：`{report['lhs_strategy']}`",
        f"- rhs strategy：`{report['rhs_strategy']}`",
        "",
        "| 层名 | lhs opt | rhs opt | rhs-lhs | rhs/lhs | rhs mismatch |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in report["rows"]:
        lines.append(
            "| `{layer}` | {lhs:,} | {rhs:,} | {delta:+,} | {ratio:.5f} | {mismatch} |".format(
                layer=item["layer_name"],
                lhs=item["lhs_opt_cycles"],
                rhs=item["rhs_opt_cycles"],
                delta=item["rhs_minus_lhs"],
                ratio=item["rhs_over_lhs"],
                mismatch=item["rhs_mismatch_count"],
            )
        )
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(load_json(args.lhs_json), load_json(args.rhs_json))

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
