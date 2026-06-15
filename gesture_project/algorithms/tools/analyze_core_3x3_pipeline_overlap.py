"""Analyze pipeline-overlap potential for core 3x3 row-template execution."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--row_templates_json", required=True, help="Input row-template analysis JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_overlap_model(layer: dict[str, Any], strategy_name: str) -> dict[str, Any]:
    strategy = layer["strategies"][strategy_name]
    counts = strategy["counts"]
    avg = strategy["average_state_cycles"]
    row_templates = strategy["row_templates"]
    sim_total = int(strategy["simulation_summary"]["total_cycles"])

    tiles_y = int(counts["tile_rows"])
    tiles_x = int(counts["tiles_per_row"])
    tiles_oc = int(counts["oc_groups_per_tile"])

    preload = float(avg["preload"])
    line_fill = float(avg["line_fill"])
    weight_group = float(avg["weight_group"])
    compute = float(avg["compute"])
    writeback = float(avg["writeback"])
    branch = float(avg["branch"])
    window_shift = float(avg["window_shift"])
    row_advance = float(avg["row_advance"])
    done = float(avg["done"])

    serial_tile_body = float(row_templates["tile_body_cycles"])

    load_overlap_tile_body = weight_group + tiles_oc * (compute + writeback + branch)
    full_pipeline_tile_body = weight_group + tiles_oc * compute + writeback + branch

    serial_first_row = float(row_templates["first_row_cycles"])
    serial_steady_row = float(row_templates["steady_row_cycles"])

    first_row_prefix = preload + line_fill
    steady_row_prefix = preload + row_advance
    row_shift_cost = max(tiles_x - 1, 0) * window_shift

    load_overlap_first_row = first_row_prefix + tiles_x * load_overlap_tile_body + row_shift_cost
    load_overlap_steady_row = steady_row_prefix + tiles_x * load_overlap_tile_body + row_shift_cost

    full_pipeline_first_row = first_row_prefix + tiles_x * full_pipeline_tile_body + row_shift_cost
    full_pipeline_steady_row = steady_row_prefix + tiles_x * full_pipeline_tile_body + row_shift_cost

    dual_port_first_prefix = max(preload, line_fill)
    dual_port_steady_prefix = max(preload, row_advance)
    dual_port_full_pipeline_first_row = dual_port_first_prefix + tiles_x * full_pipeline_tile_body + row_shift_cost
    dual_port_full_pipeline_steady_row = (
        dual_port_steady_prefix + tiles_x * full_pipeline_tile_body + row_shift_cost
    )

    load_overlap_total = load_overlap_first_row + max(tiles_y - 1, 0) * load_overlap_steady_row + done
    full_pipeline_total = full_pipeline_first_row + max(tiles_y - 1, 0) * full_pipeline_steady_row + done
    dual_port_full_pipeline_total = (
        dual_port_full_pipeline_first_row
        + max(tiles_y - 1, 0) * dual_port_full_pipeline_steady_row
        + done
    )

    baseline_opt = int(layer["baseline_opt_cycles"])
    load_overlap_mapped_opt = int(round(baseline_opt * (load_overlap_total / sim_total)))
    full_pipeline_mapped_opt = int(round(baseline_opt * (full_pipeline_total / sim_total)))
    dual_port_full_pipeline_mapped_opt = int(round(baseline_opt * (dual_port_full_pipeline_total / sim_total)))

    return {
        "strategy": strategy_name,
        "serial": {
            "tile_body_cycles": serial_tile_body,
            "first_row_cycles": serial_first_row,
            "steady_row_cycles": serial_steady_row,
            "total_cycles": sim_total,
        },
        "stage_cycles": {
            "preload": preload,
            "line_fill": line_fill,
            "weight_group": weight_group,
            "compute": compute,
            "writeback": writeback,
            "branch": branch,
            "window_shift": window_shift,
            "row_advance": row_advance,
        },
        "overlap_models": {
            "load_overlap": {
                "description": "假设下一 oc_group 的 weight/load-select 可在当前 compute 期间完成，但 writeback/branch 仍串行挂在每组后面。",
                "tile_body_cycles": load_overlap_tile_body,
                "first_row_cycles": load_overlap_first_row,
                "steady_row_cycles": load_overlap_steady_row,
                "total_cycles": int(round(load_overlap_total)),
                "cycle_delta_vs_serial": int(round(load_overlap_total)) - sim_total,
                "cycle_ratio_vs_serial": load_overlap_total / sim_total,
                "mapped_opt_cycles_from_baseline": load_overlap_mapped_opt,
                "mapped_opt_delta_vs_baseline": load_overlap_mapped_opt - baseline_opt,
            },
            "full_pipeline": {
                "description": "假设 weight/load-select 与 writeback/branch 都能借助双缓冲和独立端口被 compute 吞掉，仅保留首组装填与末组收尾。",
                "tile_body_cycles": full_pipeline_tile_body,
                "first_row_cycles": full_pipeline_first_row,
                "steady_row_cycles": full_pipeline_steady_row,
                "total_cycles": int(round(full_pipeline_total)),
                "cycle_delta_vs_serial": int(round(full_pipeline_total)) - sim_total,
                "cycle_ratio_vs_serial": full_pipeline_total / sim_total,
                "mapped_opt_cycles_from_baseline": full_pipeline_mapped_opt,
                "mapped_opt_delta_vs_baseline": full_pipeline_mapped_opt - baseline_opt,
            },
            "dual_port_full_pipeline": {
                "description": "在 full_pipeline 基础上，进一步假设 weight_preload 可与 line_fill/row_advance 通过独立端口并行进行。",
                "tile_body_cycles": full_pipeline_tile_body,
                "first_row_cycles": dual_port_full_pipeline_first_row,
                "steady_row_cycles": dual_port_full_pipeline_steady_row,
                "total_cycles": int(round(dual_port_full_pipeline_total)),
                "cycle_delta_vs_serial": int(round(dual_port_full_pipeline_total)) - sim_total,
                "cycle_ratio_vs_serial": dual_port_full_pipeline_total / sim_total,
                "mapped_opt_cycles_from_baseline": dual_port_full_pipeline_mapped_opt,
                "mapped_opt_delta_vs_baseline": dual_port_full_pipeline_mapped_opt - baseline_opt,
            },
        },
    }


def build_pair_deltas(layers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_name = {layer["layer_name"]: layer for layer in layers}
    pairs = [
        ("conv2_3x3_a", "conv3_3x3_a"),
        ("conv2_3x3_b", "conv3_3x3_b"),
    ]
    output: list[dict[str, Any]] = []
    for lhs_name, rhs_name in pairs:
        lhs = by_name.get(lhs_name)
        rhs = by_name.get(rhs_name)
        if lhs is None or rhs is None:
            continue
        lhs_full = lhs["strategies"]["row_resident"]["overlap_models"]["dual_port_full_pipeline"]
        rhs_full = rhs["strategies"]["row_resident"]["overlap_models"]["dual_port_full_pipeline"]
        output.append(
            {
                "pair": f"{lhs_name} vs {rhs_name}",
                "dual_port_full_pipeline_total_cycle_delta": lhs_full["total_cycles"] - rhs_full["total_cycles"],
                "dual_port_full_pipeline_steady_row_delta": round(
                    lhs_full["steady_row_cycles"] - rhs_full["steady_row_cycles"], 2
                ),
                "dual_port_full_pipeline_mapped_opt_delta": (
                    lhs_full["mapped_opt_cycles_from_baseline"] - rhs_full["mapped_opt_cycles_from_baseline"]
                ),
            }
        )
    return output


def build_report(row_templates: dict[str, Any]) -> dict[str, Any]:
    layers = []
    for layer in row_templates["layers"]:
        layers.append(
            {
                "layer_name": layer["layer_name"],
                "shape": layer["shape"],
                "tile_config": layer["tile_config"],
                "baseline_opt_cycles": layer["baseline_opt_cycles"],
                "strategies": {
                    "reload": build_overlap_model(layer, "reload"),
                    "row_resident": build_overlap_model(layer, "row_resident"),
                },
            }
        )
    return {
        "model": row_templates["model"],
        "scope": "Pipeline-overlap proxy on top of row-template execution model",
        "resource_model": row_templates["resource_model"],
        "layers": layers,
        "pair_deltas": build_pair_deltas(layers),
    }


def fmt_num(value: float) -> str:
    rounded = round(value, 2)
    if abs(rounded - round(rounded)) < 1e-9:
        return f"{int(round(rounded)):,}"
    return f"{rounded:,.2f}"


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# static_cnn_i96 core 3x3 阶段重叠分析",
        "",
        "- 目标：在现有 tile-row 执行模板之上，再向前推一层更贴近 RTL 的 `阶段重叠 / 双缓冲` 口径。",
        "- 四档口径：`serial`、`load_overlap`、`full_pipeline`、`dual_port_full_pipeline`。",
        "- 这里仍然是部署代理模型，不是 official worktree 的正式 cycle 结果。",
        "",
        "## row_resident 主表",
        "",
        "| 层名 | serial 总周期 | load_overlap | full_pipeline | dual_port_full | dual/serial | baseline 映射 dual_port_full |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for layer in report["layers"]:
        row = layer["strategies"]["row_resident"]
        full_model = row["overlap_models"]["full_pipeline"]
        load_model = row["overlap_models"]["load_overlap"]
        dual_model = row["overlap_models"]["dual_port_full_pipeline"]
        lines.append(
            "| `{name}` | {serial:,} | {load:,} | {full:,} | {dual:,} | {ratio:.4f} | {mapped:,} |".format(
                name=layer["layer_name"],
                serial=row["serial"]["total_cycles"],
                load=load_model["total_cycles"],
                full=full_model["total_cycles"],
                dual=dual_model["total_cycles"],
                ratio=dual_model["cycle_ratio_vs_serial"],
                mapped=dual_model["mapped_opt_cycles_from_baseline"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 主体层的 tile-body 变化",
            "",
            "| 层名 | 每组 weight/select | compute | writeback | branch | serial tile_body | load_overlap | full_pipeline |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for layer in report["layers"]:
        if not layer["shape"].startswith("48x48"):
            continue
        row = layer["strategies"]["row_resident"]
        stage = row["stage_cycles"]
        lines.append(
            "| `{name}` | {weight} | {compute} | {write} | {branch} | {serial} | {load} | {full} |".format(
                name=layer["layer_name"],
                weight=fmt_num(stage["weight_group"]),
                compute=fmt_num(stage["compute"]),
                write=fmt_num(stage["writeback"]),
                branch=fmt_num(stage["branch"]),
                serial=fmt_num(row["serial"]["tile_body_cycles"]),
                load=fmt_num(row["overlap_models"]["load_overlap"]["tile_body_cycles"]),
                full=fmt_num(row["overlap_models"]["full_pipeline"]["tile_body_cycles"]),
            )
        )

    lines.extend(
        [
            "",
            "## reload 与 row_resident 对照（dual_port_full_pipeline）",
            "",
            "| 层名 | reload dual_port_full | row_resident dual_port_full | 谁更低 |",
            "| --- | ---: | ---: | --- |",
        ]
    )

    for layer in report["layers"]:
        reload_full = layer["strategies"]["reload"]["overlap_models"]["dual_port_full_pipeline"]["total_cycles"]
        row_full = layer["strategies"]["row_resident"]["overlap_models"]["dual_port_full_pipeline"]["total_cycles"]
        winner = "row_resident" if row_full <= reload_full else "reload"
        lines.append(
            "| `{name}` | {reload_full:,} | {row_full:,} | `{winner}` |".format(
                name=layer["layer_name"],
                reload_full=reload_full,
                row_full=row_full,
                winner=winner,
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 对 24x24 配对差异（row_resident / dual_port_full_pipeline）",
            "",
            "| 对照对 | dual_port_full 总周期差 | dual_port_full 稳态行差 | baseline 映射差 |",
            "| --- | ---: | ---: | ---: |",
        ]
    )

    for item in report["pair_deltas"]:
        lines.append(
            "| `{pair}` | {total_delta:+,} | {steady_delta} | {mapped_delta:+,} |".format(
                pair=item["pair"],
                total_delta=item["dual_port_full_pipeline_total_cycle_delta"],
                steady_delta=fmt_num(item["dual_port_full_pipeline_steady_row_delta"]),
                mapped_delta=item["dual_port_full_pipeline_mapped_opt_delta"],
            )
        )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            "- `load_overlap` 主要回答：如果下一组 weight/select 能在当前 compute 期间准备好，tile-body 还能省多少控制空洞。",
            "- `full_pipeline` 更进一步，把 writeback/branch 也视作可被 compute 吞掉的尾部相位，因此更接近真正带双缓冲 accumulator / weight bank 的硬件流水结构。",
            "- `dual_port_full_pipeline` 再往前走一层：如果 input port 与 weight port 能独立工作，那么每条 tile-row 开头的 `weight_preload` 也不必和 `line_fill/row_advance` 串行排队。",
            "- 对 `48x48` 主体层，`weight/select` 本身已经很小，真正值得吃掉的是它在大量 tile-body 中重复出现的控制边角；这和前面行模板分析形成了闭环。",
            "- 这份结果适合拿来指导下一步：先在模型里继续压 `tile_body`，再判断是否值得回 official worktree 找最小 patch 对应某一类重叠收益。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    row_templates = load_json(args.row_templates_json)
    report = build_report(row_templates)

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
