"""估算 static CNN 四个核心 3x3 层在统一握手级控制策略下的部署收益。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from simulate_conv2_3x3_b_handshake_controller import run_simulation


DEFAULT_TILE_MAP = {
    "conv2_3x3_a": {"row_tile": 4, "col_tile": 8, "oc_tile": 8},
    "conv2_3x3_b": {"row_tile": 4, "col_tile": 8, "oc_tile": 8},
    "conv3_3x3_a": {"row_tile": 4, "col_tile": 8, "oc_tile": 8},
    "conv3_3x3_b": {"row_tile": 4, "col_tile": 8, "oc_tile": 8},
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--npusim_json", required=True, help="核心 3x3 baseline NPUSim JSON。")
    parser.add_argument("--input_bw", type=int, default=512, help="输入端口带宽，单位 B/cycle。")
    parser.add_argument("--weight_bw", type=int, default=512, help="weight 端口带宽，单位 B/cycle。")
    parser.add_argument("--output_bw", type=int, default=256, help="输出端口带宽，单位 B/cycle。")
    parser.add_argument("--compute_cycles", type=int, default=32, help="单个 oc_group 计算延迟。")
    parser.add_argument(
        "--local_weight_select_cycles",
        type=int,
        default=1,
        help="row-resident 模式下本地 weight 组选通延迟。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ceil_div(lhs: int, rhs: int) -> int:
    return (lhs + rhs - 1) // rhs


def build_schedule(item: dict[str, Any], tile_cfg: dict[str, int]) -> dict[str, Any]:
    out_h = int(item["output_shape"][1])
    out_w = int(item["output_shape"][2])
    in_d = int(item["input_shape"][3])
    out_d = int(item["output_shape"][3])
    filter_hw = int(item["filter_hw"])
    pad = int(item["pad"])
    row_tile = int(tile_cfg["row_tile"])
    col_tile = int(tile_cfg["col_tile"])
    oc_tile = int(tile_cfg["oc_tile"])

    padded_width = out_w + 2 * pad
    line_rows = row_tile + filter_hw - 1
    window_cols = col_tile + filter_hw - 1
    tiles_y = ceil_div(out_h, row_tile)
    tiles_x = ceil_div(out_w, col_tile)
    tiles_oc = ceil_div(out_d, oc_tile)

    first_fill_bytes = line_rows * padded_width * in_d
    x_shift_bytes = col_tile * line_rows * in_d
    y_advance_bytes = row_tile * padded_width * in_d
    weight_tile_bytes = filter_hw * filter_hw * in_d * oc_tile
    weight_row_bytes = weight_tile_bytes * tiles_oc
    tile_output_bytes = row_tile * col_tile * oc_tile

    total_input_bytes = first_fill_bytes + (tiles_y * max(tiles_x - 1, 0) * x_shift_bytes) + (
        max(tiles_y - 1, 0) * y_advance_bytes
    )
    total_weight_naive = tiles_y * tiles_x * tiles_oc * weight_tile_bytes
    total_weight_row_resident = tiles_y * weight_row_bytes
    total_output_bytes = tiles_y * tiles_x * tiles_oc * tile_output_bytes

    return {
        "layer_name": item["layer_name"],
        "shape": (
            f"{item['input_shape'][1]}x{item['input_shape'][2]}x{in_d} -> "
            f"{filter_hw}x{filter_hw} -> "
            f"{item['output_shape'][1]}x{item['output_shape'][2]}x{out_d}"
        ),
        "config": tile_cfg,
        "grid": {
            "tiles_y": tiles_y,
            "tiles_x": tiles_x,
            "tiles_oc": tiles_oc,
            "spatial_sites": tiles_y * tiles_x,
        },
        "buffer_geometry": {
            "padded_width": padded_width,
            "line_rows": line_rows,
            "window_rows": line_rows,
            "window_cols": window_cols,
        },
        "x_shift": {
            "new_input_cols": col_tile,
            "reused_input_cols": filter_hw - 1,
            "new_bytes_per_shift": x_shift_bytes,
            "reused_bytes_per_shift": (filter_hw - 1) * line_rows * in_d,
            "reuse_ratio": (filter_hw - 1) / window_cols,
        },
        "y_advance": {
            "new_input_rows": row_tile,
            "reused_input_rows": filter_hw - 1,
            "new_bytes_per_advance": y_advance_bytes,
            "reused_bytes_per_advance": (filter_hw - 1) * padded_width * in_d,
            "reuse_ratio": (filter_hw - 1) / line_rows,
        },
        "line_fill": {
            "first_spatial_site_bytes": first_fill_bytes,
            "all_x_shift_bytes": tiles_y * max(tiles_x - 1, 0) * x_shift_bytes,
            "all_y_advance_bytes": max(tiles_y - 1, 0) * y_advance_bytes,
            "total_streamed_bytes_with_reuse": total_input_bytes,
            "naive_refill_bytes_from_previous_model": tiles_y * tiles_x * first_fill_bytes,
        },
        "weight_schedule": {
            "weight_tile_bytes": weight_tile_bytes,
            "weights_per_spatial_site": weight_row_bytes,
            "total_weight_bytes_naive": total_weight_naive,
            "total_weight_bytes_row_resident": total_weight_row_resident,
            "row_resident_gain": total_weight_naive / total_weight_row_resident
            if total_weight_row_resident
            else 0.0,
        },
        "writeback": {
            "tile_output_bytes": tile_output_bytes,
            "total_output_bytes": total_output_bytes,
            "tile_acc_bytes": row_tile * col_tile * oc_tile * 4,
        },
    }


def build_layer_report(
    item: dict[str, Any],
    schedule: dict[str, Any],
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    reload_report = run_simulation(
        schedule=schedule,
        strategy="reload",
        input_bw=input_bw,
        weight_bw=weight_bw,
        output_bw=output_bw,
        compute_cycles=compute_cycles,
        local_weight_select_cycles=local_weight_select_cycles,
        max_trace_cycles=0,
    )
    row_report = run_simulation(
        schedule=schedule,
        strategy="row_resident",
        input_bw=input_bw,
        weight_bw=weight_bw,
        output_bw=output_bw,
        compute_cycles=compute_cycles,
        local_weight_select_cycles=local_weight_select_cycles,
        max_trace_cycles=0,
    )

    baseline_opt_cycles = int(item["opt_cycles"])
    baseline_ref_cycles = int(item["ref_cycles"])
    reload_cycles = int(reload_report["summary"]["total_cycles"])
    row_cycles = int(row_report["summary"]["total_cycles"])
    mapped_row_opt_cycles = int(round(baseline_opt_cycles * (row_cycles / reload_cycles)))
    mapped_cycle_delta = mapped_row_opt_cycles - baseline_opt_cycles

    return {
        "layer_name": item["layer_name"],
        "shape": schedule["shape"],
        "tile_config": schedule["config"],
        "baseline": {
            "ref_cycles": baseline_ref_cycles,
            "opt_cycles": baseline_opt_cycles,
            "estimated_macs": int(item["estimated_macs"]),
            "opt_cycles_per_mac": float(item["opt_cycles_per_mac"]),
        },
        "schedule": schedule,
        "handshake_reload": {
            "total_cycles": reload_cycles,
            "bytes_summary": reload_report["summary"]["bytes_summary"],
            "resource_busy_cycles": reload_report["summary"]["resource_busy_cycles"],
        },
        "handshake_row_resident": {
            "total_cycles": row_cycles,
            "bytes_summary": row_report["summary"]["bytes_summary"],
            "resource_busy_cycles": row_report["summary"]["resource_busy_cycles"],
        },
        "handshake_delta": {
            "cycle_delta": row_cycles - reload_cycles,
            "cycle_ratio": row_cycles / reload_cycles,
            "weight_byte_delta": int(row_report["summary"]["bytes_summary"]["weight_bytes"])
            - int(reload_report["summary"]["bytes_summary"]["weight_bytes"]),
            "weight_byte_ratio": int(row_report["summary"]["bytes_summary"]["weight_bytes"])
            / int(reload_report["summary"]["bytes_summary"]["weight_bytes"]),
        },
        "deployment_proxy": {
            "row_resident_vs_reload_cycle_ratio": row_cycles / reload_cycles,
            "mapped_row_resident_opt_cycles": mapped_row_opt_cycles,
            "mapped_row_resident_cycle_delta_vs_baseline_opt": mapped_cycle_delta,
            "mapped_row_resident_cycle_ratio_vs_baseline_opt": mapped_row_opt_cycles / baseline_opt_cycles,
            "baseline_speedup_vs_ref": baseline_ref_cycles / baseline_opt_cycles,
        },
    }


def build_report(
    npusim: dict[str, Any],
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    layer_reports = []
    for item in npusim["results"]:
        if item["layer_name"] not in DEFAULT_TILE_MAP:
            continue
        schedule = build_schedule(item, DEFAULT_TILE_MAP[item["layer_name"]])
        layer_reports.append(
            build_layer_report(
                item=item,
                schedule=schedule,
                input_bw=input_bw,
                weight_bw=weight_bw,
                output_bw=output_bw,
                compute_cycles=compute_cycles,
                local_weight_select_cycles=local_weight_select_cycles,
            )
        )

    baseline_opt_total = sum(item["baseline"]["opt_cycles"] for item in layer_reports)
    baseline_ref_total = sum(item["baseline"]["ref_cycles"] for item in layer_reports)
    reload_total = sum(item["handshake_reload"]["total_cycles"] for item in layer_reports)
    row_total = sum(item["handshake_row_resident"]["total_cycles"] for item in layer_reports)
    reload_weight_total = sum(item["handshake_reload"]["bytes_summary"]["weight_bytes"] for item in layer_reports)
    row_weight_total = sum(
        item["handshake_row_resident"]["bytes_summary"]["weight_bytes"] for item in layer_reports
    )
    mapped_row_opt_total = sum(item["deployment_proxy"]["mapped_row_resident_opt_cycles"] for item in layer_reports)
    layer_count_48x48 = sum(1 for item in layer_reports if item["shape"].startswith("48x48"))

    return {
        "model": npusim["model"],
        "scope": "Unified handshake-level deployment proxy for four verified core 3x3 layers",
        "resource_model": {
            "input_bw_bytes_per_cycle": input_bw,
            "weight_bw_bytes_per_cycle": weight_bw,
            "output_bw_bytes_per_cycle": output_bw,
            "compute_cycles_per_oc_group": compute_cycles,
            "local_weight_select_cycles": local_weight_select_cycles,
        },
        "layers": layer_reports,
        "totals": {
            "layer_count": len(layer_reports),
            "focus_48x48_layer_count": layer_count_48x48,
            "baseline_ref_cycles": baseline_ref_total,
            "baseline_opt_cycles": baseline_opt_total,
            "handshake_reload_cycles": reload_total,
            "handshake_row_resident_cycles": row_total,
            "row_resident_vs_reload_cycle_delta": row_total - reload_total,
            "row_resident_vs_reload_cycle_ratio": row_total / reload_total if reload_total else 0.0,
            "handshake_reload_weight_bytes": reload_weight_total,
            "handshake_row_resident_weight_bytes": row_weight_total,
            "row_resident_vs_reload_weight_delta": row_weight_total - reload_weight_total,
            "row_resident_vs_reload_weight_ratio": row_weight_total / reload_weight_total
            if reload_weight_total
            else 0.0,
            "mapped_row_resident_opt_cycles": mapped_row_opt_total,
            "mapped_row_resident_cycle_delta_vs_baseline_opt": mapped_row_opt_total - baseline_opt_total,
            "mapped_row_resident_cycle_ratio_vs_baseline_opt": mapped_row_opt_total / baseline_opt_total
            if baseline_opt_total
            else 0.0,
            "baseline_opt_speedup_vs_ref": baseline_ref_total / baseline_opt_total if baseline_opt_total else 0.0,
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    totals = report["totals"]
    lines = [
        "# static_cnn 核心 3x3 握手级部署收益估算",
        "",
        "- 目标：把 `conv2_3x3_a/b`、`conv3_3x3_a/b` 四个已验证核心层拉到统一握手级资源模型下，估算更贴近部署主线的收益趋势。",
        "- 当前统一假设：四层都沿用 `4x8x8` 控制骨架，便于直接复用 `conv2_3x3_b` 的 RTL-like 控制思路。",
        "",
        "## 总体结果",
        "",
        f"- baseline 四层 opt cycles：`{totals['baseline_opt_cycles']:,}`",
        f"- 握手级 reload 总周期：`{totals['handshake_reload_cycles']:,}`",
        f"- 握手级 row_resident 总周期：`{totals['handshake_row_resident_cycles']:,}`",
        f"- row_resident 相对 reload 周期比：`{totals['row_resident_vs_reload_cycle_ratio']:.4f}`",
        f"- row_resident 相对 reload 周期差：`{totals['row_resident_vs_reload_cycle_delta']:+,}`",
        f"- row_resident 相对 reload weight 流量比：`{totals['row_resident_vs_reload_weight_ratio']:.4f}`",
        f"- 映射回 baseline 后的 row_resident 预测 opt cycles：`{totals['mapped_row_resident_opt_cycles']:,}`",
        f"- 映射回 baseline 后的预测节省：`{totals['mapped_row_resident_cycle_delta_vs_baseline_opt']:+,}` cycle",
        "",
        "## 分层结果",
        "",
        "| 层名 | 形状 | baseline opt | 映射后 row_resident opt | 节省 | 握手周期比 | weight 比 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["layers"]:
        lines.append(
            "| `{layer}` | `{shape}` | {opt_cycles:,} | {mapped_opt:,} | {mapped_delta:+,} | {cycle_ratio:.4f} | {weight_ratio:.4f} |".format(
                layer=item["layer_name"],
                shape=item["shape"],
                opt_cycles=item["baseline"]["opt_cycles"],
                mapped_opt=item["deployment_proxy"]["mapped_row_resident_opt_cycles"],
                mapped_delta=item["deployment_proxy"]["mapped_row_resident_cycle_delta_vs_baseline_opt"],
                cycle_ratio=item["handshake_delta"]["cycle_ratio"],
                weight_ratio=item["handshake_delta"]["weight_byte_ratio"],
            )
        )

    lines.extend(
        [
            "",
            "## 部署解读",
            "",
            "- 这里最值得看的不是握手模型绝对周期值，而是它给出的相对改善比例，再映射回当前已验证 baseline `opt_cycles` 后形成的真实部署收益代理。",
            "- 如果把 `conv2_3x3_b` 的控制骨架推广到四个核心 3x3 层，`row_resident` 的直接价值不只存在于单层，而会累积到整个静态手势识别主干的关键热点集合。",
            "- 48x48 层仍然最值得优先盯紧，因为它们既是控制骨架的第一落点，也是整网里更重的空间驻留压力来源。",
            "- 24x24 层虽然空间尺寸更小，但同样会继承 weight 生命周期管理收益，因此第二阶段增强并不局限于单层样例。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    npusim = load_json(args.npusim_json)
    report = build_report(
        npusim=npusim,
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
