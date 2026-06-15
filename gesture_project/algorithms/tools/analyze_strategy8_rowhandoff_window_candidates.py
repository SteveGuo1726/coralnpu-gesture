"""汇总 strategy8 rowhandoff row-window 家族结果，并量化下一批候选方向。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base_json", required=True, help="原始 mode=1 trial 回放 JSON。")
    parser.add_argument("--base_emptyhooks_json", required=True, help="原始 mode=1 emptyhooks 回放 JSON。")
    parser.add_argument("--backhalf_json", required=True, help="mode1_backhalf 回放 JSON。")
    parser.add_argument("--backhalf_vs_empty_json", required=True, help="mode1_backhalf 对 emptyhooks 对比 JSON。")
    parser.add_argument("--backthird_json", required=True, help="mode1_backthird 回放 JSON。")
    parser.add_argument("--backthird_vs_empty_json", required=True, help="mode1_backthird 对 emptyhooks 对比 JSON。")
    parser.add_argument("--window32_40_json", required=True, help="mode1_window32_40 回放 JSON。")
    parser.add_argument("--window32_40_empty_json", required=True, help="mode1_window32_40 emptyhooks 回放 JSON。")
    parser.add_argument("--window40_46_json", required=True, help="mode1_window40_46 回放 JSON。")
    parser.add_argument("--window40_46_empty_json", required=True, help="mode1_window40_46 emptyhooks 回放 JSON。")
    parser.add_argument("--currentbest_json", required=True, help="同批次 current best rerun JSON。")
    parser.add_argument("--tile_schedule_json", required=True, help="conv2_3x3_b tile schedule JSON。")
    parser.add_argument("--controller_json", required=True, help="conv2_3x3_b controller row resident JSON。")
    parser.add_argument("--tail_micro_json", required=True, help="最小控制 patch 候选 JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON 路径。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown 路径。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def find_result(report: dict[str, Any], layer_name: str) -> dict[str, Any]:
    for row in report["results"]:
        if row["layer_name"] == layer_name:
            return row
    raise KeyError(f"Missing layer {layer_name}")


def find_compare_row(report: dict[str, Any], layer_name: str) -> dict[str, Any]:
    for row in report["rows"]:
        if row["layer_name"] == layer_name:
            return row
    raise KeyError(f"Missing compare row {layer_name}")


def build_variant_summary(
    *,
    name: str,
    row_window: str,
    trial_report: dict[str, Any],
    emptyhooks_report: dict[str, Any],
    currentbest_report: dict[str, Any],
    target_layer: str,
) -> dict[str, Any]:
    trial_row = find_result(trial_report, target_layer)
    empty_row = find_result(emptyhooks_report, target_layer)
    currentbest_row = find_result(currentbest_report, target_layer)
    trial_opt = int(trial_row["opt_cycles"])
    empty_opt = int(empty_row["opt_cycles"])
    currentbest_opt = int(currentbest_row["opt_cycles"])
    return {
        "name": name,
        "row_window": row_window,
        "trial_opt_cycles": trial_opt,
        "emptyhooks_opt_cycles": empty_opt,
        "currentbest_opt_cycles": currentbest_opt,
        "delta_vs_emptyhooks": trial_opt - empty_opt,
        "delta_vs_currentbest": trial_opt - currentbest_opt,
        "kept_ratio_vs_mode1": 0.0,  # filled later
    }


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    target_layer = "conv2_3x3_b"
    base_report = load_json(args.base_json)
    base_emptyhooks = load_json(args.base_emptyhooks_json)
    backhalf_report = load_json(args.backhalf_json)
    backhalf_vs_empty = load_json(args.backhalf_vs_empty_json)
    backthird_report = load_json(args.backthird_json)
    backthird_vs_empty = load_json(args.backthird_vs_empty_json)
    window32_40_report = load_json(args.window32_40_json)
    window32_40_empty = load_json(args.window32_40_empty_json)
    window40_46_report = load_json(args.window40_46_json)
    window40_46_empty = load_json(args.window40_46_empty_json)
    currentbest_report = load_json(args.currentbest_json)
    tile_schedule = load_json(args.tile_schedule_json)
    controller = load_json(args.controller_json)
    tail_micro = load_json(args.tail_micro_json)

    base_row = find_result(base_report, target_layer)
    base_empty_row = find_result(base_emptyhooks, target_layer)
    base_trial_opt = int(base_row["opt_cycles"])
    base_empty_opt = int(base_empty_row["opt_cycles"])
    base_delta_vs_empty = base_trial_opt - base_empty_opt

    backhalf_row = find_compare_row(backhalf_vs_empty, target_layer)
    backthird_row = find_compare_row(backthird_vs_empty, target_layer)

    variants = [
        {
            "name": "mode1_full",
            "row_window": "[0, 46) interior rows",
            "trial_opt_cycles": base_trial_opt,
            "emptyhooks_opt_cycles": base_empty_opt,
            "currentbest_opt_cycles": int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "delta_vs_emptyhooks": base_delta_vs_empty,
            "delta_vs_currentbest": base_trial_opt
            - int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "kept_ratio_vs_mode1": 1.0,
        },
        {
            "name": "mode1_backhalf",
            "row_window": "[24, 46) interior rows",
            "trial_opt_cycles": int(find_result(backhalf_report, target_layer)["opt_cycles"]),
            "emptyhooks_opt_cycles": int(backhalf_row["lhs_opt_cycles"]),
            "currentbest_opt_cycles": int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "delta_vs_emptyhooks": int(backhalf_row["rhs_minus_lhs"]),
            "delta_vs_currentbest": int(find_result(backhalf_report, target_layer)["opt_cycles"])
            - int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "kept_ratio_vs_mode1": 0.0,
        },
        {
            "name": "mode1_backthird",
            "row_window": "[32, 46) interior rows",
            "trial_opt_cycles": int(find_result(backthird_report, target_layer)["opt_cycles"]),
            "emptyhooks_opt_cycles": int(backthird_row["lhs_opt_cycles"]),
            "currentbest_opt_cycles": int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "delta_vs_emptyhooks": int(backthird_row["rhs_minus_lhs"]),
            "delta_vs_currentbest": int(find_result(backthird_report, target_layer)["opt_cycles"])
            - int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "kept_ratio_vs_mode1": 0.0,
        },
        build_variant_summary(
            name="mode1_window32_40",
            row_window="[32, 40) interior rows",
            trial_report=window32_40_report,
            emptyhooks_report=window32_40_empty,
            currentbest_report=currentbest_report,
            target_layer=target_layer,
        ),
        build_variant_summary(
            name="mode1_window40_46",
            row_window="[40, 46) interior rows",
            trial_report=window40_46_report,
            emptyhooks_report=window40_46_empty,
            currentbest_report=currentbest_report,
            target_layer=target_layer,
        ),
    ]

    for item in variants:
        item["kept_ratio_vs_mode1"] = (
            float(item["delta_vs_emptyhooks"]) / float(base_delta_vs_empty)
            if base_delta_vs_empty != 0
            else 0.0
        )

    mode1_candidate = None
    post_right_edge_candidate = None
    advance_x_candidate = None
    advance_row_candidate = None
    for candidate in tail_micro["candidate_families"]:
        if candidate["name"] == "post_right_edge_row_terminal":
            post_right_edge_candidate = candidate
        elif candidate["name"] == "s6_tile_advance_x":
            advance_x_candidate = candidate
        elif candidate["name"] == "s6_tile_row_advance":
            advance_row_candidate = candidate
        elif candidate["name"] == "existing_x2_tail_entry":
            mode1_candidate = candidate

    if not post_right_edge_candidate or not advance_x_candidate or not advance_row_candidate:
        raise KeyError("Missing next-step candidates in tail micro report")

    tiles_y = int(tile_schedule["grid"]["tiles_y"])
    tiles_x = int(tile_schedule["grid"]["tiles_x"])
    controller_trace_events = int(controller["trace_event_count"])
    controller_trace_truncated = bool(controller["trace_truncated"])

    row_window_deltas = [
        item["delta_vs_emptyhooks"]
        for item in variants
        if item["name"].startswith("mode1_window")
    ]
    row_window_spread = max(row_window_deltas) - min(row_window_deltas)

    next_candidates = [
        {
            "rank": 1,
            "name": "post_right_edge_row_terminal + 非纯 row 条件",
            "trigger_dimension": "row-end + 更贴近 row/tile 节拍",
            "reason": "保留当前已验证可显影的 row terminal 锚点，但不要继续只按连续 row 窗口后移。",
            "est_conv2_3x3_b_branch_delta": int(
                post_right_edge_candidate["est_from_official_best"]["branch_only_delta"]
            ),
            "est_conv2_3x3_b_writeback_branch_delta": int(
                post_right_edge_candidate["est_from_official_best"]["writeback_branch_delta"]
            ),
        },
        {
            "rank": 2,
            "name": "tile 末切列节拍",
            "trigger_dimension": "advance out_x_tile",
            "reason": "与 row-only 不同，开始引入 spatial reuse / window shift 节拍，理论空间大于单纯 row-end。",
            "est_conv2_3x3_b_branch_delta": int(
                advance_x_candidate["est_from_official_best"]["branch_only_delta"]
            ),
            "est_conv2_3x3_b_writeback_branch_delta": int(
                advance_x_candidate["est_from_official_best"]["writeback_branch_delta"]
            ),
        },
        {
            "rank": 3,
            "name": "tile-row 切行节拍",
            "trigger_dimension": "advance out_y_tile",
            "reason": "更贴近 line buffer 纵向换行，但触发次数太少，更适合作为二次确认。",
            "est_conv2_3x3_b_branch_delta": int(
                advance_row_candidate["est_from_official_best"]["branch_only_delta"]
            ),
            "est_conv2_3x3_b_writeback_branch_delta": int(
                advance_row_candidate["est_from_official_best"]["writeback_branch_delta"]
            ),
        },
    ]

    return {
        "model": base_report["model"],
        "target_layer": {
            "layer_name": target_layer,
            "shape": "{}x{}x{} -> 3x3 -> {}x{}x{}".format(
                base_row["input_shape"][1],
                base_row["input_shape"][2],
                base_row["input_shape"][3],
                base_row["output_shape"][1],
                base_row["output_shape"][2],
                base_row["output_shape"][3],
            ),
        },
        "baseline": {
            "currentbest_opt_cycles": int(find_result(currentbest_report, target_layer)["opt_cycles"]),
            "mode1_delta_vs_emptyhooks": base_delta_vs_empty,
            "tiles_y": tiles_y,
            "tiles_x": tiles_x,
            "controller_trace_event_count": controller_trace_events,
            "controller_trace_truncated": controller_trace_truncated,
        },
        "row_window_family": variants,
        "plateau_metrics": {
            "window_delta_min": min(row_window_deltas),
            "window_delta_max": max(row_window_deltas),
            "window_delta_spread": row_window_spread,
            "window_spread_vs_mode1": abs(float(row_window_spread) / float(base_delta_vs_empty))
            if base_delta_vs_empty != 0
            else 0.0,
        },
        "decision": {
            "row_only_narrowing_plateau": True,
            "summary": "window32_40 与 window40_46 的净收益几乎重合，且都弱于原始 mode=1，说明单靠连续 row 区间继续后移已经平台化。",
            "why": [
                "mode1_full 对 emptyhooks 为 -9,205，而两个 row-window 只剩约 -7.46k。",
                "window32_40 与 window40_46 之间只差 28 cycles，已经小到不足以支持继续沿纯 row 维度盲扫。",
                "这类窗口仍然只表达 software row loop 的位置，尚未引入更贴近 RTL 的 spatial reuse / tile terminal 节拍。",
            ],
        },
        "next_candidates": next_candidates,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# strategy8 rowhandoff row-window 家族量化",
        "",
        f"- 目标层：`{report['target_layer']['layer_name']}`",
        f"- 形状：`{report['target_layer']['shape']}`",
        f"- current best rerun：`{report['baseline']['currentbest_opt_cycles']:,}`",
        f"- 原始 `mode=1` 相对 emptyhooks：`{report['baseline']['mode1_delta_vs_emptyhooks']:+,}`",
        "",
        "## row-window 家族结果",
        "",
        "| 变体 | 生效区间 | trial opt | emptyhooks opt | delta vs emptyhooks | delta vs currentbest | 保留比例 vs mode1 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in report["row_window_family"]:
        lines.append(
            "| `{name}` | `{row_window}` | {trial:,} | {empty:,} | {delta_empty:+,} | {delta_best:+,} | {ratio:.3f} |".format(
                name=item["name"],
                row_window=item["row_window"],
                trial=item["trial_opt_cycles"],
                empty=item["emptyhooks_opt_cycles"],
                delta_empty=item["delta_vs_emptyhooks"],
                delta_best=item["delta_vs_currentbest"],
                ratio=item["kept_ratio_vs_mode1"],
            )
        )

    plateau = report["plateau_metrics"]
    lines.extend(
        [
            "",
            "## 平台化判断",
            "",
            f"- `window32_40` 与 `window40_46` 的净收益区间：`{plateau['window_delta_min']:+,} ~ {plateau['window_delta_max']:+,}`",
            f"- 两个 window 之间的 spread：`{plateau['window_delta_spread']:+,}`",
            f"- spread / 原始 mode1：`{plateau['window_spread_vs_mode1']:.4f}`",
            "",
            "结论：",
            report["decision"]["summary"],
            "",
            "原因：",
        ]
    )
    for reason in report["decision"]["why"]:
        lines.append(f"- {reason}")

    lines.extend(
        [
            "",
            "## 下一批候选",
            "",
            "| 排名 | 候选 | 触发维度 | branch delta | writeback+branch delta | 说明 |",
            "| --- | --- | --- | ---: | ---: | --- |",
        ]
    )
    for item in report["next_candidates"]:
        lines.append(
            "| {rank} | `{name}` | `{dim}` | {branch:+,} | {wb:+,} | {reason} |".format(
                rank=item["rank"],
                name=item["name"],
                dim=item["trigger_dimension"],
                branch=item["est_conv2_3x3_b_branch_delta"],
                wb=item["est_conv2_3x3_b_writeback_branch_delta"],
                reason=item["reason"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛结论",
            "",
            "- 原始 `rowhandoff_rowbase_recur mode=1` 仍是当前第二层保底最佳语义样本。",
            "- `backhalf / backthird / window32_40 / window40_46` 已把“纯 row 触发条件继续后移”基本判到平台区。",
            "- 下一步不应继续扫 `MIN_OUT_Y=36/40/...` 或更多连续 row window，而应转向更贴近 RTL 的 row-end / spatial tile terminal 节拍。",
        ]
    )
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(args)

    out_json = Path(args.out_json)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, out_md)

    print(f"Wrote {out_json.resolve()}")
    print(f"Wrote {out_md.resolve()}")


if __name__ == "__main__":
    main()
