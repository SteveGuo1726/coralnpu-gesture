"""Analyze row-template execution structure for core 3x3 layers."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from simulate_conv2_3x3_b_handshake_controller import run_simulation


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--impact_json", required=True, help="Input core 3x3 handshake impact JSON.")
    parser.add_argument("--input_bw", type=int, default=512, help="Input port bandwidth in B/cycle.")
    parser.add_argument("--weight_bw", type=int, default=512, help="Weight port bandwidth in B/cycle.")
    parser.add_argument("--output_bw", type=int, default=256, help="Output port bandwidth in B/cycle.")
    parser.add_argument("--compute_cycles", type=int, default=32, help="Cycles per oc-group compute.")
    parser.add_argument(
        "--local_weight_select_cycles",
        type=int,
        default=1,
        help="Cycles for local weight-bank select in row-resident mode.",
    )
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def parse_shape(shape: str) -> dict[str, int]:
    lhs, _, rhs = shape.partition("-> 3x3 ->")
    in_shape = lhs.strip()
    out_shape = rhs.strip()
    in_h, in_w, in_d = [int(part) for part in in_shape.split("x")]
    out_h, out_w, out_d = [int(part) for part in out_shape.split("x")]
    return {
        "in_h": in_h,
        "in_w": in_w,
        "in_d": in_d,
        "out_h": out_h,
        "out_w": out_w,
        "out_d": out_d,
    }


def state_avg_cycles(total_cycles: int, count: int) -> float:
    if count <= 0:
        return 0.0
    return total_cycles / count


def build_strategy_report(
    layer: dict[str, Any],
    strategy: str,
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    schedule = layer["schedule"]
    shape = parse_shape(schedule["shape"])
    grid = schedule["grid"]
    tiles_y = int(grid["tiles_y"])
    tiles_x = int(grid["tiles_x"])
    tiles_oc = int(grid["tiles_oc"])
    spatial_tiles = int(grid["spatial_sites"])
    oc_groups_total = spatial_tiles * tiles_oc
    shift_count = tiles_y * max(tiles_x - 1, 0)
    row_advance_count = max(tiles_y - 1, 0)
    preload_count = tiles_y if strategy == "row_resident" else 0

    sim = run_simulation(
        schedule=schedule,
        strategy=strategy,
        input_bw=input_bw,
        weight_bw=weight_bw,
        output_bw=output_bw,
        compute_cycles=compute_cycles,
        local_weight_select_cycles=local_weight_select_cycles,
        max_trace_cycles=0,
    )
    summary = sim["summary"]
    state_cycles = summary["state_cycles"]

    s1_avg = state_avg_cycles(int(state_cycles.get("S1_PRELOAD_WEIGHTS", 0)), preload_count)
    s2_avg = state_avg_cycles(int(state_cycles.get("S2_FILL_FIRST_TILE", 0)), 1)
    s3_avg = state_avg_cycles(int(state_cycles.get("S3_LOAD_WEIGHT_GROUP", 0)), oc_groups_total)
    s4_avg = state_avg_cycles(int(state_cycles.get("S4_COMPUTE_ACC", 0)), oc_groups_total)
    s5_avg = state_avg_cycles(int(state_cycles.get("S5_QUANTIZE_WRITEBACK", 0)), oc_groups_total)
    s6_avg = state_avg_cycles(int(state_cycles.get("S6_NEXT_OC_OR_SHIFT", 0)), oc_groups_total)
    s7_avg = state_avg_cycles(int(state_cycles.get("S7_WINDOW_SHIFT", 0)), shift_count)
    s8_avg = state_avg_cycles(int(state_cycles.get("S8_ADVANCE_ROW", 0)), row_advance_count)
    s9_cycles = int(state_cycles.get("S9_DONE", 0))

    tile_body_cycles = tiles_oc * (s3_avg + s4_avg + s5_avg + s6_avg)
    first_row_cycles = (s1_avg if strategy == "row_resident" else 0.0) + s2_avg
    first_row_cycles += tiles_x * tile_body_cycles + max(tiles_x - 1, 0) * s7_avg
    steady_row_cycles = (s1_avg if strategy == "row_resident" else 0.0) + s8_avg
    steady_row_cycles += tiles_x * tile_body_cycles + max(tiles_x - 1, 0) * s7_avg
    template_total_cycles = first_row_cycles + max(tiles_y - 1, 0) * steady_row_cycles + s9_cycles

    input_phase_cycles = int(state_cycles.get("S2_FILL_FIRST_TILE", 0))
    input_phase_cycles += int(state_cycles.get("S7_WINDOW_SHIFT", 0))
    input_phase_cycles += int(state_cycles.get("S8_ADVANCE_ROW", 0))

    external_weight_cycles = int(state_cycles.get("S1_PRELOAD_WEIGHTS", 0))
    local_weight_cycles = 0
    if strategy == "reload":
        external_weight_cycles += int(state_cycles.get("S3_LOAD_WEIGHT_GROUP", 0))
    else:
        local_weight_cycles = int(state_cycles.get("S3_LOAD_WEIGHT_GROUP", 0))

    full_acc_bytes = shape["out_h"] * shape["out_w"] * shape["out_d"] * 4
    row_acc_bytes = shape["out_w"] * shape["out_d"] * 4
    tile_acc_bytes = int(schedule["writeback"]["tile_acc_bytes"])

    x_new_bytes = int(schedule["x_shift"]["new_bytes_per_shift"])
    x_reuse_bytes = int(schedule["x_shift"]["reused_bytes_per_shift"])
    y_new_bytes = int(schedule["y_advance"]["new_bytes_per_advance"])
    y_reuse_bytes = int(schedule["y_advance"]["reused_bytes_per_advance"])

    return {
        "strategy": strategy,
        "simulation_summary": {
            "total_cycles": int(summary["total_cycles"]),
            "bytes_summary": summary["bytes_summary"],
            "resource_busy_cycles": summary["resource_busy_cycles"],
            "state_cycles": state_cycles,
        },
        "counts": {
            "tile_rows": tiles_y,
            "tiles_per_row": tiles_x,
            "oc_groups_per_tile": tiles_oc,
            "spatial_tiles": spatial_tiles,
            "oc_groups_total": oc_groups_total,
            "window_shift_count": shift_count,
            "row_advance_count": row_advance_count,
            "weight_preload_count": preload_count,
        },
        "average_state_cycles": {
            "preload": s1_avg,
            "line_fill": s2_avg,
            "weight_group": s3_avg,
            "compute": s4_avg,
            "writeback": s5_avg,
            "branch": s6_avg,
            "window_shift": s7_avg,
            "row_advance": s8_avg,
            "done": float(s9_cycles),
        },
        "row_templates": {
            "tile_body_cycles": tile_body_cycles,
            "first_row_cycles": first_row_cycles,
            "steady_row_cycles": steady_row_cycles,
            "template_total_cycles": template_total_cycles,
            "sim_total_cycles": int(summary["total_cycles"]),
            "template_match_delta": int(round(template_total_cycles)) - int(summary["total_cycles"]),
        },
        "phase_breakdown": {
            "input_pipeline_cycles": input_phase_cycles,
            "external_weight_cycles": external_weight_cycles,
            "local_weight_cycles": local_weight_cycles,
            "compute_cycles": int(state_cycles.get("S4_COMPUTE_ACC", 0)),
            "writeback_cycles": int(state_cycles.get("S5_QUANTIZE_WRITEBACK", 0)),
            "branch_cycles": int(state_cycles.get("S6_NEXT_OC_OR_SHIFT", 0)),
            "done_cycles": s9_cycles,
        },
        "residency": {
            "full_acc_bytes": full_acc_bytes,
            "row_acc_bytes": row_acc_bytes,
            "tile_acc_bytes": tile_acc_bytes,
            "full_vs_row_reduction": full_acc_bytes / row_acc_bytes if row_acc_bytes else 0.0,
            "full_vs_tile_reduction": full_acc_bytes / tile_acc_bytes if tile_acc_bytes else 0.0,
            "row_vs_tile_reduction": row_acc_bytes / tile_acc_bytes if tile_acc_bytes else 0.0,
        },
        "spatial_reuse": {
            "x_shift_new_bytes_total": shift_count * x_new_bytes,
            "x_shift_reused_bytes_total": shift_count * x_reuse_bytes,
            "row_advance_new_bytes_total": row_advance_count * y_new_bytes,
            "row_advance_reused_bytes_total": row_advance_count * y_reuse_bytes,
            "x_shift_reuse_ratio": float(schedule["x_shift"]["reuse_ratio"]),
            "row_advance_reuse_ratio": float(schedule["y_advance"]["reuse_ratio"]),
        },
    }


def build_pair_deltas(layers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_name = {item["layer_name"]: item for item in layers}
    pairs = [
        ("conv2_3x3_a", "conv3_3x3_a"),
        ("conv2_3x3_b", "conv3_3x3_b"),
    ]
    deltas: list[dict[str, Any]] = []
    for lhs_name, rhs_name in pairs:
        lhs = by_name.get(lhs_name)
        rhs = by_name.get(rhs_name)
        if lhs is None or rhs is None:
            continue
        lhs_row = lhs["strategies"]["row_resident"]
        rhs_row = rhs["strategies"]["row_resident"]
        deltas.append(
            {
                "pair": f"{lhs_name} vs {rhs_name}",
                "first_row_cycle_delta": round(
                    lhs_row["row_templates"]["first_row_cycles"] - rhs_row["row_templates"]["first_row_cycles"], 2
                ),
                "steady_row_cycle_delta": round(
                    lhs_row["row_templates"]["steady_row_cycles"] - rhs_row["row_templates"]["steady_row_cycles"], 2
                ),
                "tile_row_count_delta": int(lhs_row["counts"]["tile_rows"] - rhs_row["counts"]["tile_rows"]),
                "window_shift_count_delta": int(
                    lhs_row["counts"]["window_shift_count"] - rhs_row["counts"]["window_shift_count"]
                ),
                "row_acc_bytes_delta": int(lhs_row["residency"]["row_acc_bytes"] - rhs_row["residency"]["row_acc_bytes"]),
                "sim_total_cycles_delta": int(
                    lhs_row["simulation_summary"]["total_cycles"] - rhs_row["simulation_summary"]["total_cycles"]
                ),
            }
        )
    return deltas


def build_layer_entry(
    layer: dict[str, Any],
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    reload_report = build_strategy_report(
        layer,
        "reload",
        input_bw,
        weight_bw,
        output_bw,
        compute_cycles,
        local_weight_select_cycles,
    )
    row_report = build_strategy_report(
        layer,
        "row_resident",
        input_bw,
        weight_bw,
        output_bw,
        compute_cycles,
        local_weight_select_cycles,
    )
    return {
        "layer_name": layer["layer_name"],
        "shape": layer["shape"],
        "tile_config": layer["tile_config"],
        "baseline_opt_cycles": int(layer["baseline"]["opt_cycles"]),
        "strategies": {
            "reload": reload_report,
            "row_resident": row_report,
        },
        "row_resident_vs_reload": {
            "sim_cycle_delta": int(row_report["simulation_summary"]["total_cycles"])
            - int(reload_report["simulation_summary"]["total_cycles"]),
            "sim_cycle_ratio": (
                int(row_report["simulation_summary"]["total_cycles"])
                / int(reload_report["simulation_summary"]["total_cycles"])
            ),
            "steady_row_cycle_delta": round(
                row_report["row_templates"]["steady_row_cycles"] - reload_report["row_templates"]["steady_row_cycles"],
                2,
            ),
            "external_weight_cycle_delta": int(row_report["phase_breakdown"]["external_weight_cycles"])
            - int(reload_report["phase_breakdown"]["external_weight_cycles"]),
        },
    }


def build_report(
    impact: dict[str, Any],
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    layers = [
        build_layer_entry(
            layer,
            input_bw,
            weight_bw,
            output_bw,
            compute_cycles,
            local_weight_select_cycles,
        )
        for layer in impact["layers"]
    ]
    return {
        "model": impact["model"],
        "scope": "Row-template execution analysis for verified core 3x3 layers",
        "resource_model": {
            "input_bw_bytes_per_cycle": input_bw,
            "weight_bw_bytes_per_cycle": weight_bw,
            "output_bw_bytes_per_cycle": output_bw,
            "compute_cycles_per_oc_group": compute_cycles,
            "local_weight_select_cycles": local_weight_select_cycles,
        },
        "layers": layers,
        "pair_deltas": build_pair_deltas(layers),
    }


def fmt_cycles(value: float) -> str:
    rounded = round(value, 2)
    if math.isclose(rounded, round(rounded)):
        return f"{int(round(rounded)):,}"
    return f"{rounded:,.2f}"


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# static_cnn_i96 core 3x3 行模板执行分析",
        "",
        "- 目标：把统一 `4x8x8` 控制骨架进一步拆成更接近 RTL 的 tile-row 执行模板。",
        "- 关注点：`48x48` 主体层为何更值得优先做行驻留、空间复用和输出驻留。",
        "- 数据来源：`static_cnn_i96_core_3x3_handshake_impact.json` + 通用握手控制器仿真。",
        "",
        "## 分层总表（row_resident）",
        "",
        "| 层名 | tile_rows | row 首行周期 | row 稳态周期 | 仿真总周期 | 输入阶段 | 外部 weight | compute | writeback |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for layer in report["layers"]:
        row = layer["strategies"]["row_resident"]
        lines.append(
            "| `{name}` | {rows} | {first_row} | {steady_row} | {total:,} | {input_cycles:,} | {weight_cycles:,} | {compute_cycles:,} | {write_cycles:,} |".format(
                name=layer["layer_name"],
                rows=row["counts"]["tile_rows"],
                first_row=fmt_cycles(row["row_templates"]["first_row_cycles"]),
                steady_row=fmt_cycles(row["row_templates"]["steady_row_cycles"]),
                total=row["simulation_summary"]["total_cycles"],
                input_cycles=row["phase_breakdown"]["input_pipeline_cycles"],
                weight_cycles=row["phase_breakdown"]["external_weight_cycles"],
                compute_cycles=row["phase_breakdown"]["compute_cycles"],
                write_cycles=row["phase_breakdown"]["writeback_cycles"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 主体层重点",
            "",
            "| 层名 | 横向 shift 次数 | 换行次数 | x-shift 新增输入 | 换行新增输入 | 整图 acc | 单行 acc | 单 tile acc |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for layer in report["layers"]:
        if not layer["shape"].startswith("48x48"):
            continue
        row = layer["strategies"]["row_resident"]
        lines.append(
            "| `{name}` | {shift_count} | {row_adv} | {x_new:,} B | {y_new:,} B | {full_acc:,} B | {row_acc:,} B | {tile_acc:,} B |".format(
                name=layer["layer_name"],
                shift_count=row["counts"]["window_shift_count"],
                row_adv=row["counts"]["row_advance_count"],
                x_new=row["spatial_reuse"]["x_shift_new_bytes_total"],
                y_new=row["spatial_reuse"]["row_advance_new_bytes_total"],
                full_acc=row["residency"]["full_acc_bytes"],
                row_acc=row["residency"]["row_acc_bytes"],
                tile_acc=row["residency"]["tile_acc_bytes"],
            )
        )

    lines.extend(
        [
            "",
            "## reload vs row_resident",
            "",
            "| 层名 | 仿真周期比 | 稳态 row 周期变化 | 外部 weight 周期变化 |",
            "| --- | ---: | ---: | ---: |",
        ]
    )

    for layer in report["layers"]:
        delta = layer["row_resident_vs_reload"]
        lines.append(
            "| `{name}` | {ratio:.4f} | {steady_delta} | {weight_delta:+,} |".format(
                name=layer["layer_name"],
                ratio=delta["sim_cycle_ratio"],
                steady_delta=fmt_cycles(delta["steady_row_cycle_delta"]),
                weight_delta=delta["external_weight_cycle_delta"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 对 24x24 配对差异（row_resident）",
            "",
            "| 对照对 | 首行周期差 | 稳态行周期差 | tile_rows 差 | 横向 shift 差 | 总周期差 |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for item in report["pair_deltas"]:
        lines.append(
            "| `{pair}` | {first_row} | {steady_row} | {row_delta:+,} | {shift_delta:+,} | {total_delta:+,} |".format(
                pair=item["pair"],
                first_row=fmt_cycles(item["first_row_cycle_delta"]),
                steady_row=fmt_cycles(item["steady_row_cycle_delta"]),
                row_delta=item["tile_row_count_delta"],
                shift_delta=item["window_shift_count_delta"],
                total_delta=item["sim_total_cycles_delta"],
            )
        )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            "- 这份分析把统一控制骨架拆成了 `首行启动`、`稳态 tile-row`、`tile 内 oc_group 主体` 三层重复单元，后续再推进 RTL 时可以直接对这些单元逐项压缩。",
            "- `48x48` 主体层的关键不是单次 x-shift 或单次换行有多贵，而是它们在 `12` 条 tile-row、`6` 个 tile-col 下会被重复得更多；这正是做行驻留和空间复用最值钱的地方。",
            "- 从输出驻留看，`48x48` 主体层整图 accumulator 规模是 `294,912 B`，而单行只需 `6,144 B`、单 tile 仅 `1,024 B`，说明输出不落地的收益空间远大于继续抠边界微核。",
            "- `reload` 到 `row_resident` 的变化，主要是在外部 weight 周期被压缩，而 `compute` 与 `writeback` 主体不变。这和前面官方 `conv.cc` 已经把软件主体路径压得比较紧的现实是对齐的。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    impact = load_json(args.impact_json)
    report = build_report(
        impact=impact,
        input_bw=args.input_bw,
        weight_bw=args.weight_bw,
        output_bw=args.output_bw,
        compute_cycles=args.compute_cycles,
        local_weight_select_cycles=args.local_weight_select_cycles,
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
