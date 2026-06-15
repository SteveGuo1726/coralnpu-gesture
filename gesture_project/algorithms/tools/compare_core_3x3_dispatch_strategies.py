"""比较官方 worktree 3x3 dispatch 实验策略的真实回放结果。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline_json", required=True, help="baseline/auto 回放 JSON。")
    parser.add_argument("--candidate_json", required=True, help="候选策略回放 JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
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


def build_report(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    baseline_map = {item["layer_name"]: item for item in baseline["results"]}
    candidate_map = {item["layer_name"]: item for item in candidate["results"]}
    baseline_strategy = extract_strategy(baseline)
    candidate_strategy = extract_strategy(candidate)

    layer_names = sorted(set(baseline_map) & set(candidate_map))
    rows = []
    for layer_name in layer_names:
        base = baseline_map[layer_name]
        cand = candidate_map[layer_name]
        rows.append(
            {
                "layer_name": layer_name,
                "baseline_strategy": baseline_strategy,
                "candidate_strategy": candidate_strategy,
                "baseline_opt_cycles": int(base["opt_cycles"]),
                "candidate_opt_cycles": int(cand["opt_cycles"]),
                "opt_cycle_delta": int(cand["opt_cycles"]) - int(base["opt_cycles"]),
                "opt_cycle_ratio": float(cand["opt_cycles"]) / float(base["opt_cycles"]),
                "baseline_ref_cycles": int(base["ref_cycles"]),
                "candidate_ref_cycles": int(cand["ref_cycles"]),
                "ref_cycle_delta": int(cand["ref_cycles"]) - int(base["ref_cycles"]),
                "mismatch_count": int(cand["mismatch_count"]),
            }
        )

    return {
        "model": baseline.get("model", candidate.get("model", "unknown")),
        "scope": "Official worktree 3x3 dispatch strategy replay comparison",
        "baseline_json": baseline,
        "candidate_json": candidate,
        "rows": rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    baseline_strategy = report["rows"][0]["baseline_strategy"] if report["rows"] else 0
    candidate_strategy = report["rows"][0]["candidate_strategy"] if report["rows"] else 0
    lines = [
        "# 官方 worktree 3x3 dispatch 策略对比",
        "",
        f"- baseline strategy：`{baseline_strategy}`",
        f"- candidate strategy：`{candidate_strategy}`",
        "",
        "| 层名 | baseline opt | candidate opt | opt 差值 | opt 比例 | mismatch |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["rows"]:
        lines.append(
            "| `{layer}` | {base_opt:,} | {cand_opt:,} | {delta:+,} | {ratio:.5f} | {mismatch} |".format(
                layer=item["layer_name"],
                base_opt=item["baseline_opt_cycles"],
                cand_opt=item["candidate_opt_cycles"],
                delta=item["opt_cycle_delta"],
                ratio=item["opt_cycle_ratio"],
                mismatch=item["mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            "- `opt_cycle_delta < 0` 代表候选策略真实更快。",
            "- `mismatch_count = 0` 仅说明数值正确，不代表该策略值得进入默认路径。",
            "- 若候选策略在 48x48 / 24x24 主体层显著变慢，则后续应回到核内数据流与驻留优化，而不是继续折腾分派切换。",
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
