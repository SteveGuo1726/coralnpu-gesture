"""Isolate output-tail hiding effect for core 3x3 row-resident templates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--row_templates_json", required=True, help="Input row-template analysis JSON.")
    parser.add_argument("--baseline_json", required=True, help="Official baseline replay JSON.")
    parser.add_argument("--official_best_json", required=True, help="Official best replay JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(
    row_templates: dict[str, Any],
    baseline: dict[str, Any],
    official_best: dict[str, Any],
) -> dict[str, Any]:
    baseline_map = {item["layer_name"]: item for item in baseline["results"]}
    official_map = {item["layer_name"]: item for item in official_best["results"]}

    rows = []
    for layer in row_templates["layers"]:
        row = layer["strategies"]["row_resident"]
        counts = row["counts"]
        avg = row["average_state_cycles"]
        sim_total = int(row["simulation_summary"]["total_cycles"])
        baseline_opt = int(baseline_map[layer["layer_name"]]["opt_cycles"])
        official_opt = int(official_map[layer["layer_name"]]["opt_cycles"])

        oc_groups_total = int(counts["oc_groups_total"])
        branch_total = int(round(float(avg["branch"]) * oc_groups_total))
        writeback_total = int(round(float(avg["writeback"]) * oc_groups_total))
        output_tail_total = branch_total + writeback_total

        tail_hidden_total = sim_total - output_tail_total
        tail_hidden_mapped_opt = int(round(baseline_opt * (tail_hidden_total / sim_total)))

        official_saving = baseline_opt - official_opt
        tail_only_proxy_saving = baseline_opt - tail_hidden_mapped_opt

        rows.append(
            {
                "layer_name": layer["layer_name"],
                "shape": layer["shape"],
                "baseline_opt_cycles": baseline_opt,
                "official_best_opt_cycles": official_opt,
                "row_resident_sim_cycles": sim_total,
                "oc_groups_total": oc_groups_total,
                "writeback_total_cycles": writeback_total,
                "branch_total_cycles": branch_total,
                "output_tail_total_cycles": output_tail_total,
                "tail_hidden_sim_cycles": tail_hidden_total,
                "tail_hidden_cycle_ratio": tail_hidden_total / sim_total,
                "tail_hidden_mapped_opt_cycles": tail_hidden_mapped_opt,
                "tail_only_proxy_saving": tail_only_proxy_saving,
                "official_best_saving": official_saving,
                "official_vs_tail_proxy_ratio": (
                    official_saving / tail_only_proxy_saving if tail_only_proxy_saving > 0 else None
                ),
            }
        )

    return {
        "model": row_templates["model"],
        "scope": "Isolated output-tail hiding effect on row-resident control template",
        "rows": rows,
        "totals": {
            "tail_only_proxy_saving": sum(item["tail_only_proxy_saving"] for item in rows),
            "official_best_saving": sum(item["official_best_saving"] for item in rows),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# core 3x3 输出尾部隐藏影响分析",
        "",
        "- 口径：只讨论 `row_resident` 控制模板里 `writeback + branch` 这部分尾部能否被隐藏。",
        "- 目的：把“输出尾部收益”从更大的计算主体收益里单独剥出来，避免高估它能解释的 official 提升。",
        "",
        "| 层名 | row_resident 周期 | writeback | branch | 尾部合计 | 隐藏尾部后周期 | baseline 映射 opt | 尾部代理节省 | official 节省 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["rows"]:
        lines.append(
            "| `{layer}` | {sim:,} | {write:,} | {branch:,} | {tail:,} | {tail_hidden:,} | {mapped:,} | {proxy_save:,} | {official_save:,} |".format(
                layer=item["layer_name"],
                sim=item["row_resident_sim_cycles"],
                write=item["writeback_total_cycles"],
                branch=item["branch_total_cycles"],
                tail=item["output_tail_total_cycles"],
                tail_hidden=item["tail_hidden_sim_cycles"],
                mapped=item["tail_hidden_mapped_opt_cycles"],
                proxy_save=item["tail_only_proxy_saving"],
                official_save=item["official_best_saving"],
            )
        )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            f"- 尾部代理总节省：`{report['totals']['tail_only_proxy_saving']:,}`",
            f"- official 最优总节省：`{report['totals']['official_best_saving']:,}`",
            "- 这说明 `writeback + branch` 尾部隐藏本身只是一个较窄的控制收益项，远不足以解释 official `strategy=8` 最优路径的大部分收益。",
            "- 因此后面如果回 official worktree 找最小 patch，应把它定位成“补控制尾部”的小方向，而不是期待它单独重现主体区的大幅加速。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        row_templates=load_json(args.row_templates_json),
        baseline=load_json(args.baseline_json),
        official_best=load_json(args.official_best_json),
    )

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
