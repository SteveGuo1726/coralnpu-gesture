"""Model tile-to-tile reuse and schedule for conv2_3x3_b 4x8x8 main config."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROW_TILE = 4
COL_TILE = 8
OC_TILE = 8
FILTER_HW = 3
PAD = 1
INPUT_DEPTH = 32
OUTPUT_DEPTH = 32
OUTPUT_HEIGHT = 48
OUTPUT_WIDTH = 48


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out_json", required=True, help="Output JSON report.")
    parser.add_argument("--out_md", required=True, help="Output Markdown report.")
    return parser.parse_args()


def ceil_div(lhs: int, rhs: int) -> int:
    return (lhs + rhs - 1) // rhs


def build_report() -> dict[str, Any]:
    padded_width = OUTPUT_WIDTH + 2 * PAD
    line_rows = ROW_TILE + FILTER_HW - 1
    window_rows = line_rows
    window_cols = COL_TILE + FILTER_HW - 1

    tiles_y = ceil_div(OUTPUT_HEIGHT, ROW_TILE)
    tiles_x = ceil_div(OUTPUT_WIDTH, COL_TILE)
    tiles_oc = ceil_div(OUTPUT_DEPTH, OC_TILE)

    first_spatial_line_fill = line_rows * padded_width * INPUT_DEPTH
    x_shift_new_cols = COL_TILE * window_rows * INPUT_DEPTH
    x_shift_reuse_cols = (FILTER_HW - 1) * window_rows * INPUT_DEPTH
    y_advance_new_rows = ROW_TILE * padded_width * INPUT_DEPTH
    y_advance_reuse_rows = (FILTER_HW - 1) * padded_width * INPUT_DEPTH

    weight_tile_bytes = OC_TILE * FILTER_HW * FILTER_HW * INPUT_DEPTH
    weights_per_spatial_site = tiles_oc * weight_tile_bytes
    weight_total_naive = tiles_y * tiles_x * tiles_oc * weight_tile_bytes
    weight_total_row_resident = tiles_y * tiles_oc * weight_tile_bytes
    weight_row_resident_gain = weight_total_naive / weight_total_row_resident

    spatial_sites = tiles_y * tiles_x
    total_x_shift_bytes = tiles_y * (tiles_x - 1) * x_shift_new_cols
    total_y_advance_bytes = (tiles_y - 1) * y_advance_new_rows

    return {
        "layer_name": "conv2_3x3_b",
        "shape": "48x48x32 -> 3x3 -> 48x48x32",
        "config": {"row_tile": ROW_TILE, "col_tile": COL_TILE, "oc_tile": OC_TILE},
        "grid": {
            "tiles_y": tiles_y,
            "tiles_x": tiles_x,
            "tiles_oc": tiles_oc,
            "spatial_sites": spatial_sites,
        },
        "buffer_geometry": {
            "padded_width": padded_width,
            "line_rows": line_rows,
            "window_rows": window_rows,
            "window_cols": window_cols,
        },
        "x_shift": {
            "new_input_cols": COL_TILE,
            "reused_input_cols": FILTER_HW - 1,
            "new_bytes_per_shift": x_shift_new_cols,
            "reused_bytes_per_shift": x_shift_reuse_cols,
            "reuse_ratio": x_shift_reuse_cols / (window_rows * window_cols * INPUT_DEPTH),
        },
        "y_advance": {
            "new_input_rows": ROW_TILE,
            "reused_input_rows": FILTER_HW - 1,
            "new_bytes_per_advance": y_advance_new_rows,
            "reused_bytes_per_advance": y_advance_reuse_rows,
            "reuse_ratio": y_advance_reuse_rows / (line_rows * padded_width * INPUT_DEPTH),
        },
        "line_fill": {
            "first_spatial_site_bytes": first_spatial_line_fill,
            "all_x_shift_bytes": total_x_shift_bytes,
            "all_y_advance_bytes": total_y_advance_bytes,
            "total_streamed_bytes_with_reuse": (
                first_spatial_line_fill + total_x_shift_bytes + total_y_advance_bytes
            ),
            "naive_refill_bytes_from_previous_model": 691200,
        },
        "weight_schedule": {
            "weight_tile_bytes": weight_tile_bytes,
            "weights_per_spatial_site": weights_per_spatial_site,
            "total_weight_bytes_naive": weight_total_naive,
            "total_weight_bytes_row_resident": weight_total_row_resident,
            "row_resident_gain": weight_row_resident_gain,
        },
        "writeback": {
            "tile_output_bytes": ROW_TILE * COL_TILE * OC_TILE,
            "total_output_bytes": OUTPUT_HEIGHT * OUTPUT_WIDTH * OUTPUT_DEPTH,
            "tile_acc_bytes": ROW_TILE * COL_TILE * OC_TILE * 4,
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    grid = report["grid"]
    x_shift = report["x_shift"]
    y_advance = report["y_advance"]
    line_fill = report["line_fill"]
    weight_schedule = report["weight_schedule"]
    writeback = report["writeback"]

    lines = [
        "# conv2_3x3_b 4x8x8 tile 调度代理模型",
        "",
        "- 对象：`conv2_3x3_b`",
        "- 配置：`row_tile=4, col_tile=8, oc_tile=8`",
        "- 目的：把相邻 tile 之间的复用关系量化出来，为更细的模块级时序图提供输入。",
        "",
        "## Tile 网格",
        "",
        f"- `tiles_y = {grid['tiles_y']}`",
        f"- `tiles_x = {grid['tiles_x']}`",
        f"- `tiles_oc = {grid['tiles_oc']}`",
        f"- 空间 tile 总数：`{grid['spatial_sites']}`",
        "",
        "## 横向推进：out_x tile -> out_x+1 tile",
        "",
        f"- 当前 window 视图大小：`6 x 10 x 32 = {report['buffer_geometry']['window_rows']}x{report['buffer_geometry']['window_cols']}x32`",
        f"- 每次横向推进只需新增 `8` 列输入，对应 `{x_shift['new_bytes_per_shift']:,} B`",
        f"- 同时保留左侧 `2` 列历史窗口内容，对应 `{x_shift['reused_bytes_per_shift']:,} B`",
        f"- 从完整 `6x10` 视图看，横向推进的窗口复用比例约为 `{x_shift['reuse_ratio']:.1%}`",
        "",
        "## 纵向推进：out_y tile -> out_y+1 tile",
        "",
        f"- line buffer 共保留 `6` 行输入",
        f"- 每次纵向推进只需新增 `4` 行输入，对应 `{y_advance['new_bytes_per_advance']:,} B`",
        f"- 保留顶部 `2` 行历史内容，对应 `{y_advance['reused_bytes_per_advance']:,} B`",
        f"- 从整块 line buffer 看，纵向推进的行复用比例约为 `{y_advance['reuse_ratio']:.1%}`",
        "",
        "## 输入流量口径",
        "",
        "| 项目 | 字节数 |",
        "| --- | ---: |",
        f"| 第一空间 tile 初始 line fill | {line_fill['first_spatial_site_bytes']:,} B |",
        f"| 全部横向 shift 新增量 | {line_fill['all_x_shift_bytes']:,} B |",
        f"| 全部纵向推进新增量 | {line_fill['all_y_advance_bytes']:,} B |",
        f"| 复用后总输入流量 | {line_fill['total_streamed_bytes_with_reuse']:,} B |",
        f"| 先前粗模型中的 naive refill | {line_fill['naive_refill_bytes_from_previous_model']:,} B |",
        "",
        "## Weight 调度两种策略",
        "",
        "| 策略 | 总 weight 流量 | 说明 |",
        "| --- | ---: | --- |",
        f"| 每空间 tile 都重载一次 | {weight_schedule['total_weight_bytes_naive']:,} B | 当前最保守口径 |",
        f"| 同一 out_y 行常驻 | {weight_schedule['total_weight_bytes_row_resident']:,} B | 每个 tile row 内复用同一组 weight |",
        "",
        f"- 如果 weight 能在同一 `out_y_tile` 行内常驻，weight 流量理论上可再降 `{weight_schedule['row_resident_gain']:.2f}x`。",
        "",
        "## 对时序图的直接含义",
        "",
        "- 横向相邻 tile 之间，不应重建整个 `6x10` window；更合理的是做 `window shift`，只补右侧 `8` 列新数据。",
        "- 纵向相邻 tile 之间，不应重灌全部 `6` 行 line buffer；更合理的是保留旧的 `2` 行，只补 `4` 行新数据。",
        "- `oc_tile=8` 的当前主配置仍需要 `4` 次 OC 子块切换，因此 weight buffer 是否能跨多个 `out_x_tile` 常驻，会直接影响外层调度成本。",
        "- 因此后续模块级时序图应至少显式区分四个阶段：`首 tile 装载`、`横向 shift`、`纵向换行`、`oc_tile 切换`。",
        "",
        "## 当前推荐",
        "",
        "- 第一版时序图按 `4x8x8` 展开。",
        "- 输入侧优先假设 `line buffer + window shift` 成立。",
        "- weight 侧应同时保留两种口径：`每空间 tile 重载` 与 `同一 out_y_tile 行常驻`。",
    ]

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report()

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
