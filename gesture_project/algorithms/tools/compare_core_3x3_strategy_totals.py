"""比较两份四层核心 3x3 官方 worktree 回放总量。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline_json", required=True)
    parser.add_argument("--candidate_json", required=True)
    parser.add_argument("--out_json", required=True)
    parser.add_argument("--out_md", required=True)
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    base_map = {item["layer_name"]: item for item in baseline["results"]}
    cand_map = {item["layer_name"]: item for item in candidate["results"]}
    rows = []
    for layer_name in sorted(base_map):
        base = base_map[layer_name]
        cand = cand_map[layer_name]
        rows.append(
            {
                "layer_name": layer_name,
                "baseline_opt_cycles": int(base["opt_cycles"]),
                "candidate_opt_cycles": int(cand["opt_cycles"]),
                "opt_cycle_delta": int(cand["opt_cycles"]) - int(base["opt_cycles"]),
                "opt_cycle_ratio": float(cand["opt_cycles"]) / float(base["opt_cycles"]),
                "mismatch_count": int(cand["mismatch_count"]),
            }
        )

    baseline_total = int(baseline["totals"]["opt_cycles"])
    candidate_total = int(candidate["totals"]["opt_cycles"])
    return {
        "model": baseline.get("model", "unknown"),
        "scope": "Core 3x3 official worktree full replay total comparison",
        "rows": rows,
        "totals": {
            "baseline_opt_cycles": baseline_total,
            "candidate_opt_cycles": candidate_total,
            "opt_cycle_delta": candidate_total - baseline_total,
            "opt_cycle_ratio": candidate_total / baseline_total,
            "total_mismatch_count": int(candidate["totals"]["total_mismatch_count"]),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 核心 3x3 四层总量对比",
        "",
        "| 层名 | baseline opt | candidate opt | opt 差值 | opt 比例 | mismatch |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in report["rows"]:
        lines.append(
            "| `{layer}` | {base:,} | {cand:,} | {delta:+,} | {ratio:.5f} | {mismatch} |".format(
                layer=item["layer_name"],
                base=item["baseline_opt_cycles"],
                cand=item["candidate_opt_cycles"],
                delta=item["opt_cycle_delta"],
                ratio=item["opt_cycle_ratio"],
                mismatch=item["mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## 总量",
            "",
            f"- baseline opt_cycles：`{report['totals']['baseline_opt_cycles']:,}`",
            f"- candidate opt_cycles：`{report['totals']['candidate_opt_cycles']:,}`",
            f"- 总差值：`{report['totals']['opt_cycle_delta']:+,}`",
            f"- 总比例：`{report['totals']['opt_cycle_ratio']:.5f}`",
            f"- total_mismatch_count：`{report['totals']['total_mismatch_count']}`",
        ]
    )
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(load_json(args.baseline_json), load_json(args.candidate_json))

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
