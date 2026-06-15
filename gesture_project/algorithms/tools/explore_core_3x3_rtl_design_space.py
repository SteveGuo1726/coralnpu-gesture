"""Explore RTL-like dataflow design points for verified core 3x3 layers."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


DEFAULT_ROW_TILES = (1, 2, 4, 8)
DEFAULT_COL_TILES = (1, 2, 4, 8)
DEFAULT_OC_TILES = (8, 16, 32, 64)
DEFAULT_BUDGETS = (8 * 1024, 16 * 1024, 32 * 1024, 64 * 1024)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--npusim", required=True, help="Input NPUSim JSON.")
    parser.add_argument("--out_json", required=True, help="Output design-space JSON.")
    parser.add_argument("--out_md", required=True, help="Output Markdown report.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ceil_div(lhs: int, rhs: int) -> int:
    return (lhs + rhs - 1) // rhs


def shape_text(item: dict[str, Any]) -> str:
    return (
        f"{item['input_shape'][1]}x{item['input_shape'][2]}x{item['input_shape'][3]} -> "
        f"{item['filter_hw']}x{item['filter_hw']} -> "
        f"{item['output_shape'][1]}x{item['output_shape'][2]}x{item['output_shape'][3]}"
    )


def candidate_oc_tiles(output_depth: int) -> list[int]:
    return [tile for tile in DEFAULT_OC_TILES if tile <= output_depth]


def build_candidate(item: dict[str, Any], row_tile: int, col_tile: int, oc_tile: int) -> dict[str, Any]:
    input_height = int(item["input_shape"][1])
    input_width = int(item["input_shape"][2])
    input_depth = int(item["input_shape"][3])
    output_height = int(item["output_shape"][1])
    output_width = int(item["output_shape"][2])
    output_depth = int(item["output_shape"][3])
    filter_hw = int(item["filter_hw"])
    pad = int(item["pad"])

    padded_input_width = input_width + 2 * pad
    input_points_naive = row_tile * col_tile * filter_hw * filter_hw
    input_points_unique = (row_tile + filter_hw - 1) * (col_tile + filter_hw - 1)
    spatial_saving_ratio = 1.0 - (input_points_unique / input_points_naive)

    line_buffer_bytes = (row_tile + filter_hw - 1) * padded_input_width * input_depth
    window_bytes = input_points_unique * input_depth
    weight_bytes = oc_tile * filter_hw * filter_hw * input_depth
    acc_bytes = row_tile * col_tile * oc_tile * 4
    output_bytes = row_tile * col_tile * oc_tile
    total_local_bytes = line_buffer_bytes + window_bytes + weight_bytes + acc_bytes + output_bytes

    tiles_y = ceil_div(output_height, row_tile)
    tiles_x = ceil_div(output_width, col_tile)
    tiles_oc = ceil_div(output_depth, oc_tile)
    total_tiles = tiles_y * tiles_x * tiles_oc

    full_map_acc_bytes = output_height * output_width * output_depth * 4
    full_map_acc_roundtrip_bytes = full_map_acc_bytes * 2

    return {
        "layer_name": item["layer_name"],
        "shape": shape_text(item),
        "row_tile": row_tile,
        "col_tile": col_tile,
        "oc_tile": oc_tile,
        "throughput_proxy": row_tile * col_tile * oc_tile,
        "input_points_naive": input_points_naive,
        "input_points_unique": input_points_unique,
        "spatial_saving_ratio": spatial_saving_ratio,
        "line_buffer_bytes": line_buffer_bytes,
        "window_bytes": window_bytes,
        "weight_bytes": weight_bytes,
        "acc_bytes": acc_bytes,
        "output_bytes": output_bytes,
        "total_local_bytes": total_local_bytes,
        "tiles_y": tiles_y,
        "tiles_x": tiles_x,
        "tiles_oc": tiles_oc,
        "total_tiles": total_tiles,
        "acc_scratch_reduction_vs_full_map": (
            full_map_acc_bytes / acc_bytes if acc_bytes else 0.0
        ),
        "acc_roundtrip_eliminated_bytes": full_map_acc_roundtrip_bytes,
        "full_map_acc_roundtrip_bytes": full_map_acc_roundtrip_bytes,
        "opt_cycles": int(item["opt_cycles"]),
        "opt_cycles_per_mac": float(item["opt_cycles_per_mac"]),
        "estimated_macs": int(item["estimated_macs"]),
        "is_48x48_focus": output_height == 48 and output_width == 48,
    }


def select_best_within_budget(candidates: list[dict[str, Any]], budget: int) -> dict[str, Any] | None:
    feasible = [item for item in candidates if item["total_local_bytes"] <= budget]
    if not feasible:
        return None
    feasible.sort(
        key=lambda item: (
            item["throughput_proxy"],
            item["spatial_saving_ratio"],
            -item["total_tiles"],
            -item["acc_scratch_reduction_vs_full_map"],
            -item["total_local_bytes"],
        ),
        reverse=True,
    )
    return feasible[0]


def explore_item(item: dict[str, Any]) -> dict[str, Any]:
    output_height = int(item["output_shape"][1])
    output_width = int(item["output_shape"][2])
    output_depth = int(item["output_shape"][3])

    candidates = []
    for row_tile in DEFAULT_ROW_TILES:
        if row_tile > output_height:
            continue
        for col_tile in DEFAULT_COL_TILES:
            if col_tile > output_width:
                continue
            for oc_tile in candidate_oc_tiles(output_depth):
                candidates.append(build_candidate(item, row_tile, col_tile, oc_tile))

    candidates.sort(
        key=lambda entry: (
            entry["total_local_bytes"],
            -entry["throughput_proxy"],
            -entry["spatial_saving_ratio"],
        )
    )

    best_by_budget = []
    for budget in DEFAULT_BUDGETS:
        best = select_best_within_budget(candidates, budget)
        if best is None:
            continue
        best_by_budget.append({"budget_bytes": budget, "candidate": best})

    top_dense = sorted(
        candidates,
        key=lambda entry: (
            entry["throughput_proxy"],
            entry["spatial_saving_ratio"],
            -entry["total_local_bytes"],
        ),
        reverse=True,
    )[:5]

    return {
        "layer_name": item["layer_name"],
        "shape": shape_text(item),
        "is_48x48_focus": output_height == 48 and output_width == 48,
        "candidate_count": len(candidates),
        "best_by_budget": best_by_budget,
        "top_dense_candidates": top_dense,
        "lightest_candidates": candidates[:5],
    }


def build_summary(results: list[dict[str, Any]]) -> dict[str, Any]:
    focus = [item for item in results if item["is_48x48_focus"]]
    focus_budget_summary = []
    for budget in DEFAULT_BUDGETS:
        focus_choices = []
        for item in focus:
            match = next(
                (entry for entry in item["best_by_budget"] if entry["budget_bytes"] == budget),
                None,
            )
            if match:
                focus_choices.append(
                    {
                        "layer_name": item["layer_name"],
                        "candidate": match["candidate"],
                    }
                )
        if focus_choices:
            focus_budget_summary.append({"budget_bytes": budget, "choices": focus_choices})
    return {"focus_48x48_by_budget": focus_budget_summary}


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# static_cnn_i96 core 3x3 RTL-like 设计空间探索",
        "",
        "- 目标：在不修改当前 `conv.cc` baseline 的前提下，为 `48x48` 主体层筛选更贴近 RTL 的 `row_tile / col_tile / oc_tile` 候选。",
        "- 输入：`gesture_project/reports/static_cnn_i96_core_3x3_npusim.json`",
        "- 预算口径：局部 scratch 预算固定观察 `8KB / 16KB / 32KB / 64KB`。",
        "",
        "## 48x48 主体层预算建议",
        "",
        "| 预算 | 层名 | row_tile | col_tile | oc_tile | 局部 scratch | 吞吐代理 | 空间取数节省 | full-map acc 缩减 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for budget_entry in report["summary"]["focus_48x48_by_budget"]:
        budget_text = f"{budget_entry['budget_bytes'] // 1024}KB"
        for choice in budget_entry["choices"]:
            candidate = choice["candidate"]
            lines.append(
                "| {budget} | `{layer}` | {row_tile} | {col_tile} | {oc_tile} | {local:,} B | {tp} | {saving:.1%} | {acc_red:.1f}x |".format(
                    budget=budget_text,
                    layer=choice["layer_name"],
                    row_tile=candidate["row_tile"],
                    col_tile=candidate["col_tile"],
                    oc_tile=candidate["oc_tile"],
                    local=candidate["total_local_bytes"],
                    tp=candidate["throughput_proxy"],
                    saving=candidate["spatial_saving_ratio"],
                    acc_red=candidate["acc_scratch_reduction_vs_full_map"],
                )
            )

    lines.extend(
        [
            "",
            "## 各层最值得看的高密度候选",
            "",
            "| 层名 | 形状 | row_tile | col_tile | oc_tile | 局部 scratch | tiles 总数 | 吞吐代理 | 空间取数节省 |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for item in report["results"]:
        top = item["top_dense_candidates"][0]
        lines.append(
            "| `{layer}` | `{shape}` | {row_tile} | {col_tile} | {oc_tile} | {local:,} B | {tiles} | {tp} | {saving:.1%} |".format(
                layer=item["layer_name"],
                shape=item["shape"],
                row_tile=top["row_tile"],
                col_tile=top["col_tile"],
                oc_tile=top["oc_tile"],
                local=top["total_local_bytes"],
                tiles=top["total_tiles"],
                tp=top["throughput_proxy"],
                saving=top["spatial_saving_ratio"],
            )
        )

    lines.extend(
        [
            "",
            "## 工程解读",
            "",
            "- `8KB` 预算下，`48x48` 两层已经可以容纳 `1x4` 或 `1x8` 级别的行驻留 + 多像素并行候选，说明最小 RTL 试做不需要等到很大的 scratch 才能起步。",
            "- `16KB` 到 `32KB` 区间开始容纳更像正式微结构的 `2x8`、`4x8` 候选，局部吞吐代理提升明显，适合做下一阶段主配置。",
            "- `conv2_3x3_b` 因为 `input_depth=32`，weight/line buffer 压力高于 `conv2_3x3_a`，所以更适合作为 48x48 主体层里的硬约束样例。",
            "- 这些候选并不直接等价于周期结果，但它们已经把“该优先做多大的 row tile、几像素并行、多少 OC tile”从定性问题变成了可比选项。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    source = load_json(args.npusim)
    results = [explore_item(item) for item in source["results"]]
    results.sort(key=lambda item: (not item["is_48x48_focus"], item["layer_name"]))

    report = {
        "model": source["model"],
        "scope": "RTL-like design space exploration for verified core 3x3 layers",
        "budgets_bytes": list(DEFAULT_BUDGETS),
        "results": results,
        "summary": build_summary(results),
    }

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
