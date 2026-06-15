"""Quantify how current strategy8 trial hooks map to spatial steps vs inter-oc targets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tail_candidates_json", required=True, help="Tail patch candidates JSON.")
    parser.add_argument("--cases_json", required=True, help="Core 3x3 cases JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_row(case: dict[str, Any], tail_row: dict[str, Any]) -> dict[str, Any]:
    out_w = int(case["out_w"])
    out_h = int(case["out_h"])
    in_d = int(case["in_d"])
    out_d = int(case["out_d"])
    counts = tail_row["counts"]

    interior_count = out_w - 2
    x4_steps_per_row = interior_count // 4
    x2_tail_per_row = 1 if (interior_count % 4) >= 2 else 0
    x1_tail_per_row = interior_count % 2
    interior_rows = max(out_h - 2, 0)

    x4_steps_total = interior_rows * x4_steps_per_row
    x2_tail_total = interior_rows * x2_tail_per_row
    x1_tail_total = interior_rows * x1_tail_per_row

    oc_groups_per_tile = int(counts["oc_groups_per_tile"])
    spatial_tiles = int(counts["spatial_tiles"])
    inter_oc_transitions = int(counts["inter_oc_transitions"])

    return {
        "layer_name": case["layer_name"],
        "shape": f"{out_h}x{out_w}x{in_d}->{out_h}x{out_w}x{out_d}",
        "out_h": out_h,
        "out_w": out_w,
        "in_d": in_d,
        "out_d": out_d,
        "interior_rows": interior_rows,
        "interior_count": interior_count,
        "spatial_tiles": spatial_tiles,
        "oc_groups_per_tile": oc_groups_per_tile,
        "oc_groups_total": int(counts["oc_groups_total"]),
        "inter_oc_transitions": inter_oc_transitions,
        "trial_hook_steps": {
            "x4_steps_per_row": x4_steps_per_row,
            "x2_tail_per_row": x2_tail_per_row,
            "x1_tail_per_row": x1_tail_per_row,
            "x4_steps_total": x4_steps_total,
            "x2_tail_total": x2_tail_total,
            "x1_tail_total": x1_tail_total,
            "all_trial_hooks_total": x4_steps_total + x2_tail_total,
        },
        "ratios": {
            "trial_hooks_vs_inter_oc": (
                (x4_steps_total + x2_tail_total) / inter_oc_transitions
                if inter_oc_transitions
                else None
            ),
            "x2_tail_vs_inter_oc": (
                x2_tail_total / inter_oc_transitions if inter_oc_transitions else None
            ),
            "trial_hooks_vs_oc_groups_total": (
                (x4_steps_total + x2_tail_total) / int(counts["oc_groups_total"])
                if int(counts["oc_groups_total"])
                else None
            ),
        },
        "coverage_note": (
            "当前 trial hook 只包住空间主体 x4/x2 步进，不跨 oc_block；"
            "因此它更像 spatial-step 入口，而不是 inter-oc 尾部交界入口。"
        ),
    }


def build_report(tail_candidates: dict[str, Any], cases: dict[str, Any]) -> dict[str, Any]:
    tail_map = {item["layer_name"]: item for item in tail_candidates["rows"]}
    rows = []
    for case in cases["cases"]:
        layer_name = case["layer_name"]
        if layer_name not in tail_map:
            continue
        rows.append(build_row(case, tail_map[layer_name]))
    return {
        "model": cases["model"],
        "scope": "Coverage mismatch between strategy8 current trial hooks and inter-oc tail-closure target",
        "rows": rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# strategy8 当前 trial hook 覆盖范围量化",
        "",
        "- 目标：区分当前 `tail_closure_trial` hook 实际包住的空间主体步进，与 `inter_oc_tail_closure` 代理想吃掉的 `oc_group` 交界次数。",
        "- 重点：避免把 `spatial x4/x2` 入口误当成 `inter-oc tail closure` 的真实第一刀。",
        "",
        "## 逐层覆盖对比",
        "",
        "| 层名 | 形状 | inter-oc 次数 | x4 hook 次数 | x2 hook 次数 | 全 hook 总数 | 全 hook / inter-oc | x2 / inter-oc |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for row in report["rows"]:
        ratios = row["ratios"]
        trial = row["trial_hook_steps"]
        lines.append(
            "| `{layer}` | `{shape}` | {inter_oc} | {x4_total} | {x2_total} | {all_total} | {all_ratio} | {x2_ratio} |".format(
                layer=row["layer_name"],
                shape=row["shape"],
                inter_oc=row["inter_oc_transitions"],
                x4_total=trial["x4_steps_total"],
                x2_total=trial["x2_tail_total"],
                all_total=trial["all_trial_hooks_total"],
                all_ratio=(
                    f"{ratios['trial_hooks_vs_inter_oc']:.3f}"
                    if ratios["trial_hooks_vs_inter_oc"] is not None
                    else "-"
                ),
                x2_ratio=(
                    f"{ratios['x2_tail_vs_inter_oc']:.3f}"
                    if ratios["x2_tail_vs_inter_oc"] is not None
                    else "-"
                ),
            )
        )

    lines.extend(
        [
            "",
            "## 收敛结论",
            "",
            "- `conv2_3x3_b` 的当前 trial hook 总次数是 `inter-oc` 目标次数的一个空间步进代理，并不与 `oc_group` 交界一一对应。",
            "- 尤其 `x4` hook 命中的是每个 interior row 的主体块步进；它天然不跨 `oc_block`，因此更适合作为 trace/gate 基座，而不是直接承载 `inter_oc_tail_closure` 行为。",
            "- `x2` hook 每个 interior row 只命中一次，比 `x4` 更窄，但它仍然是空间尾块入口，不是 `oc_group -> next oc_group` 的切换点。",
            "- 因此后续若继续做最小行为 patch，应优先把目标表述成 `spatial tail-control` 或 `row-end tail-control`，不要直接宣称已经命中 `inter-oc tail closure`。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(load_json(args.tail_candidates_json), load_json(args.cases_json))

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
