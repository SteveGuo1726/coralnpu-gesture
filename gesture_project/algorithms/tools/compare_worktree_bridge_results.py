"""比较项目 baseline、官方 worktree 回放结果与 row_resident 收益代理。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline_json", required=True, help="项目 baseline NPUSim JSON。")
    parser.add_argument("--impact_json", required=True, help="握手级部署收益 JSON。")
    parser.add_argument(
        "--worktree_jsons",
        nargs="+",
        required=True,
        help="一个或多个官方 worktree 回放 JSON。",
    )
    parser.add_argument("--out_json", required=True, help="输出对比 JSON。")
    parser.add_argument("--out_md", required=True, help="输出对比 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(
    baseline: dict[str, Any],
    impact: dict[str, Any],
    worktree_reports: list[dict[str, Any]],
) -> dict[str, Any]:
    baseline_map = {item["layer_name"]: item for item in baseline["results"]}
    impact_map = {item["layer_name"]: item for item in impact["layers"]}

    merged_layers = []
    for worktree in worktree_reports:
        if len(worktree["results"]) != 1:
            raise ValueError("Each worktree JSON should contain exactly one layer replay result")
        item = worktree["results"][0]
        layer_name = item["layer_name"]
        base = baseline_map[layer_name]
        imp = impact_map[layer_name]
        opt_delta = int(item["opt_cycles"]) - int(base["opt_cycles"])
        ref_delta = int(item["ref_cycles"]) - int(base["ref_cycles"])
        merged_layers.append(
            {
                "layer_name": layer_name,
                "shape": imp["shape"],
                "baseline_opt_cycles": int(base["opt_cycles"]),
                "worktree_opt_cycles": int(item["opt_cycles"]),
                "opt_delta_vs_baseline": opt_delta,
                "baseline_ref_cycles": int(base["ref_cycles"]),
                "worktree_ref_cycles": int(item["ref_cycles"]),
                "ref_delta_vs_baseline": ref_delta,
                "mismatch_count": int(item["mismatch_count"]),
                "mapped_row_resident_opt_cycles": int(imp["deployment_proxy"]["mapped_row_resident_opt_cycles"]),
                "mapped_row_resident_delta_vs_baseline": int(
                    imp["deployment_proxy"]["mapped_row_resident_cycle_delta_vs_baseline_opt"]
                ),
            }
        )

    merged_layers.sort(key=lambda item: item["layer_name"])
    return {
        "model": baseline["model"],
        "scope": "Baseline vs official worktree replay vs row_resident deployment proxy",
        "layers": merged_layers,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 核心 3x3 官方 worktree 回放对比",
        "",
        "- 目标：确认 `gesture_project` 的 baseline 周期口径、官方 `coralnpu-3x3-conv` worktree 回放结果，以及 row_resident 收益代理三者之间已经真正打通。",
        "",
        "| 层名 | baseline opt | worktree opt | opt 差值 | mismatch | 映射后 row_resident opt | row_resident 预测节省 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["layers"]:
        lines.append(
            "| `{layer}` | {baseline_opt:,} | {worktree_opt:,} | {opt_delta:+,} | {mismatch} | {mapped_opt:,} | {mapped_delta:+,} |".format(
                layer=item["layer_name"],
                baseline_opt=item["baseline_opt_cycles"],
                worktree_opt=item["worktree_opt_cycles"],
                opt_delta=item["opt_delta_vs_baseline"],
                mismatch=item["mismatch_count"],
                mapped_opt=item["mapped_row_resident_opt_cycles"],
                mapped_delta=item["mapped_row_resident_delta_vs_baseline"],
            )
        )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            "- worktree 回放与项目 baseline 的周期差值若维持在极小范围内，说明当前正式核心层 cases 配置和官方入口已经稳定打通。",
            "- 在此基础上，row_resident 的收益代理才有资格继续作为后续最小 patch 的优先判断依据。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    baseline = load_json(args.baseline_json)
    impact = load_json(args.impact_json)
    worktree_reports = [load_json(path) for path in args.worktree_jsons]
    report = build_report(baseline, impact, worktree_reports)

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
