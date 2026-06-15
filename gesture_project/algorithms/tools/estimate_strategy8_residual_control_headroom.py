"""Estimate residual control-only headroom on top of official strategy-8 best replay."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official_best_json", required=True, help="Official best strategy-8 replay JSON.")
    parser.add_argument("--pipeline_overlap_json", required=True, help="Pipeline-overlap proxy JSON.")
    parser.add_argument("--output_tail_json", required=True, help="Output-tail effect JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON.")
    parser.add_argument("--out_md", required=True, help="Output Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(
    official_best: dict[str, Any],
    pipeline_overlap: dict[str, Any],
    output_tail: dict[str, Any],
) -> dict[str, Any]:
    official_map = {item["layer_name"]: item for item in official_best["results"]}
    overlap_map = {item["layer_name"]: item for item in pipeline_overlap["layers"]}
    tail_map = {item["layer_name"]: item for item in output_tail["rows"]}

    rows = []
    total_official_opt = 0
    total_tail_est = 0
    total_dual_est = 0

    for layer_name in sorted(official_map):
        official_opt = int(official_map[layer_name]["opt_cycles"])
        overlap_row = overlap_map[layer_name]["strategies"]["row_resident"]
        tail_row = tail_map[layer_name]

        tail_ratio = float(tail_row["tail_hidden_cycle_ratio"])
        dual_ratio = float(overlap_row["overlap_models"]["dual_port_full_pipeline"]["cycle_ratio_vs_serial"])
        full_ratio = float(overlap_row["overlap_models"]["full_pipeline"]["cycle_ratio_vs_serial"])

        est_tail_opt = int(round(official_opt * tail_ratio))
        est_dual_opt = int(round(official_opt * dual_ratio))
        est_full_opt = int(round(official_opt * full_ratio))

        rows.append(
            {
                "layer_name": layer_name,
                "shape": overlap_map[layer_name]["shape"],
                "official_best_opt_cycles": official_opt,
                "tail_hidden_ratio": tail_ratio,
                "full_pipeline_ratio": full_ratio,
                "dual_port_full_pipeline_ratio": dual_ratio,
                "est_tail_hidden_opt_cycles": est_tail_opt,
                "est_tail_hidden_delta": est_tail_opt - official_opt,
                "est_full_pipeline_opt_cycles": est_full_opt,
                "est_full_pipeline_delta": est_full_opt - official_opt,
                "est_dual_port_full_pipeline_opt_cycles": est_dual_opt,
                "est_dual_port_full_pipeline_delta": est_dual_opt - official_opt,
            }
        )

        total_official_opt += official_opt
        total_tail_est += est_tail_opt
        total_dual_est += est_dual_opt

    return {
        "model": official_best.get("model", "unknown"),
        "scope": "Residual control-only headroom on top of official strategy-8 best replay",
        "rows": rows,
        "totals": {
            "official_best_opt_cycles": total_official_opt,
            "est_tail_hidden_opt_cycles": total_tail_est,
            "est_tail_hidden_delta": total_tail_est - total_official_opt,
            "est_dual_port_full_pipeline_opt_cycles": total_dual_est,
            "est_dual_port_full_pipeline_delta": total_dual_est - total_official_opt,
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# strategy-8 当前最优主线的剩余控制空间估算",
        "",
        "- 口径修正：这里不再拿旧 baseline 讨论，而是直接从当前 official `strategy=8` 最优回放出发。",
        "- 目标：估算在保持当前主体区 software 主线不动的前提下，控制尾部和阶段重叠还可能留下多少空间。",
        "",
        "| 层名 | official best opt | tail_hidden 估算 | tail delta | full_pipeline 估算 | full delta | dual_port_full 估算 | dual delta |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for row in report["rows"]:
        lines.append(
            "| `{layer}` | {official:,} | {tail_opt:,} | {tail_delta:+,} | {full_opt:,} | {full_delta:+,} | {dual_opt:,} | {dual_delta:+,} |".format(
                layer=row["layer_name"],
                official=row["official_best_opt_cycles"],
                tail_opt=row["est_tail_hidden_opt_cycles"],
                tail_delta=row["est_tail_hidden_delta"],
                full_opt=row["est_full_pipeline_opt_cycles"],
                full_delta=row["est_full_pipeline_delta"],
                dual_opt=row["est_dual_port_full_pipeline_opt_cycles"],
                dual_delta=row["est_dual_port_full_pipeline_delta"],
            )
        )

    totals = report["totals"]
    lines.extend(
        [
            "",
            "## 总量",
            "",
            f"- 当前 official 最优总 `opt_cycles`：`{totals['official_best_opt_cycles']:,}`",
            f"- 若只吃输出尾部隐藏，估算可到：`{totals['est_tail_hidden_opt_cycles']:,}`，残余空间 ` {totals['est_tail_hidden_delta']:+,} `",
            f"- 若吃到 dual_port_full_pipeline，估算可到：`{totals['est_dual_port_full_pipeline_opt_cycles']:,}`，残余空间 ` {totals['est_dual_port_full_pipeline_delta']:+,} `",
            "",
            "## 解读",
            "",
            "- 这里的 delta 都是相对当前 official 最优主线的剩余空间，而不是相对旧 baseline 的总收益。",
            "- 如果这些数字远小于前面 `strategy=8` 主体区已经吃到的收益，就说明接下来更适合把控制尾部当成小 patch 方向，而不是重新动主体计算骨架。",
            "- `48x48` 两层若仍显示更大的剩余空间，就说明后续继续围绕 `S5/S6`、输出驻留写回尾部和 `oc_group` 收口推进是合理的。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        official_best=load_json(args.official_best_json),
        pipeline_overlap=load_json(args.pipeline_overlap_json),
        output_tail=load_json(args.output_tail_json),
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
