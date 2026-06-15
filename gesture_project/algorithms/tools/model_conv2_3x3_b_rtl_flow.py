"""Model RTL-like tile dataflow for conv2_3x3_b candidate configurations."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


CANDIDATES = (
    {"name": "trial_min_1x4x8", "row_tile": 1, "col_tile": 4, "oc_tile": 8},
    {"name": "trial_main_4x8x8", "row_tile": 4, "col_tile": 8, "oc_tile": 8},
    {"name": "trial_dense_8x8x16", "row_tile": 8, "col_tile": 8, "oc_tile": 16},
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--npusim", required=True, help="Input NPUSim JSON.")
    parser.add_argument("--out_json", required=True, help="Output modeling JSON.")
    parser.add_argument("--out_md", required=True, help="Output Markdown report.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ceil_div(lhs: int, rhs: int) -> int:
    return (lhs + rhs - 1) // rhs


def load_case(report: dict[str, Any], layer_name: str) -> dict[str, Any]:
    for item in report["results"]:
        if item["layer_name"] == layer_name:
            return item
    raise KeyError(f"Layer {layer_name} not found")


def shape_text(item: dict[str, Any]) -> str:
    return (
        f"{item['input_shape'][1]}x{item['input_shape'][2]}x{item['input_shape'][3]} -> "
        f"{item['filter_hw']}x{item['filter_hw']} -> "
        f"{item['output_shape'][1]}x{item['output_shape'][2]}x{item['output_shape'][3]}"
    )


def build_candidate(case: dict[str, Any], candidate: dict[str, int | str]) -> dict[str, Any]:
    input_height = int(case["input_shape"][1])
    input_width = int(case["input_shape"][2])
    input_depth = int(case["input_shape"][3])
    output_height = int(case["output_shape"][1])
    output_width = int(case["output_shape"][2])
    output_depth = int(case["output_shape"][3])
    filter_hw = int(case["filter_hw"])
    pad = int(case["pad"])

    row_tile = int(candidate["row_tile"])
    col_tile = int(candidate["col_tile"])
    oc_tile = int(candidate["oc_tile"])

    padded_input_width = input_width + 2 * pad
    padded_input_height = input_height + 2 * pad
    line_rows = row_tile + filter_hw - 1
    line_buffer_bytes = line_rows * padded_input_width * input_depth

    window_points = (row_tile + filter_hw - 1) * (col_tile + filter_hw - 1)
    window_bytes = window_points * input_depth
    weight_bytes = oc_tile * filter_hw * filter_hw * input_depth
    acc_bytes = row_tile * col_tile * oc_tile * 4
    output_bytes = row_tile * col_tile * oc_tile
    local_bytes = line_buffer_bytes + window_bytes + weight_bytes + acc_bytes + output_bytes

    tiles_y = ceil_div(output_height, row_tile)
    tiles_x = ceil_div(output_width, col_tile)
    tiles_oc = ceil_div(output_depth, oc_tile)
    total_tiles = tiles_y * tiles_x * tiles_oc
    spatial_sites = tiles_y * tiles_x

    line_fill_per_spatial_site = line_rows * padded_input_width * input_depth
    line_refill_bytes = line_fill_per_spatial_site * spatial_sites
    line_refill_reuse_factor = (
        (output_depth // oc_tile) if output_depth % oc_tile == 0 else tiles_oc
    )

    weight_load_bytes = weight_bytes * total_tiles
    quant_writes_bytes = row_tile * col_tile * oc_tile * total_tiles
    acc_roundtrip_saved_bytes = output_height * output_width * output_depth * 4 * 2
    full_map_output_bytes = output_height * output_width * output_depth
    full_map_acc_bytes = output_height * output_width * output_depth * 4

    naive_window_points = row_tile * col_tile * filter_hw * filter_hw
    spatial_saving_ratio = 1.0 - (window_points / naive_window_points)

    return {
        "name": candidate["name"],
        "row_tile": row_tile,
        "col_tile": col_tile,
        "oc_tile": oc_tile,
        "line_rows": line_rows,
        "line_buffer_bytes": line_buffer_bytes,
        "window_bytes": window_bytes,
        "weight_bytes": weight_bytes,
        "acc_bytes": acc_bytes,
        "output_bytes": output_bytes,
        "local_bytes": local_bytes,
        "tiles_y": tiles_y,
        "tiles_x": tiles_x,
        "tiles_oc": tiles_oc,
        "total_tiles": total_tiles,
        "spatial_sites": spatial_sites,
        "line_fill_per_spatial_site": line_fill_per_spatial_site,
        "line_refill_bytes": line_refill_bytes,
        "line_refill_reuse_factor": line_refill_reuse_factor,
        "weight_load_bytes": weight_load_bytes,
        "quant_writes_bytes": quant_writes_bytes,
        "acc_roundtrip_saved_bytes": acc_roundtrip_saved_bytes,
        "full_map_output_bytes": full_map_output_bytes,
        "full_map_acc_bytes": full_map_acc_bytes,
        "spatial_saving_ratio": spatial_saving_ratio,
        "throughput_proxy": row_tile * col_tile * oc_tile,
        "oc_switches_per_spatial_site": tiles_oc,
    }


def compare_candidates(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    baseline = entries[0]
    comparisons = []
    for entry in entries[1:]:
        comparisons.append(
            {
                "from": baseline["name"],
                "to": entry["name"],
                "tile_count_ratio": baseline["total_tiles"] / entry["total_tiles"],
                "weight_load_ratio": baseline["weight_load_bytes"] / entry["weight_load_bytes"],
                "line_refill_ratio": baseline["line_refill_bytes"] / entry["line_refill_bytes"],
                "throughput_proxy_ratio": entry["throughput_proxy"] / baseline["throughput_proxy"],
            }
        )
    return comparisons


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b tile 数据流代理模型",
        "",
        "- 目标层：`conv2_3x3_b`",
        f"- 形状：`{report['shape']}`",
        "- 目的：把 `1x4x8 / 4x8x8 / 8x8x16` 三档候选转成可比较的 tile 数据流指标，为下一步 RTL 草案提供直接输入。",
        "",
        "## 三档候选总表",
        "",
        "| 配置 | 局部 scratch | tiles_y/x/oc | tile 总数 | line refill | weight load | 输出写回 | 空间取数节省 | 吞吐代理 |",
        "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["candidates"]:
        lines.append(
            "| `{name}` | {local:,} B | `{ty}/{tx}/{toc}` | {tiles:,} | {line_refill:,} B | {weight_load:,} B | {output_writes:,} B | {saving:.1%} | {tp} |".format(
                name=item["name"],
                local=item["local_bytes"],
                ty=item["tiles_y"],
                tx=item["tiles_x"],
                toc=item["tiles_oc"],
                tiles=item["total_tiles"],
                line_refill=item["line_refill_bytes"],
                weight_load=item["weight_load_bytes"],
                output_writes=item["quant_writes_bytes"],
                saving=item["spatial_saving_ratio"],
                tp=item["throughput_proxy"],
            )
        )

    lines.extend(
        [
            "",
            "## 结构解读",
            "",
            "| 配置 | line buffer | window | weight tile | acc tile | output tile | 每空间点 OC 切换 |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for item in report["candidates"]:
        lines.append(
            "| `{name}` | {line:,} B | {window:,} B | {weight:,} B | {acc:,} B | {output:,} B | {oc_switches} |".format(
                name=item["name"],
                line=item["line_buffer_bytes"],
                window=item["window_bytes"],
                weight=item["weight_bytes"],
                acc=item["acc_bytes"],
                output=item["output_bytes"],
                oc_switches=item["oc_switches_per_spatial_site"],
            )
        )

    lines.extend(
        [
            "",
            "## 相对对比",
            "",
            "| 从 | 到 | tile 数缩减 | weight load 缩减 | line refill 缩减 | 吞吐代理提升 |",
            "| --- | --- | ---: | ---: | ---: | ---: |",
        ]
    )

    for item in report["comparisons"]:
        lines.append(
            "| `{src}` | `{dst}` | {tiles:.2f}x | {weight:.2f}x | {line:.2f}x | {tp:.2f}x |".format(
                src=item["from"],
                dst=item["to"],
                tiles=item["tile_count_ratio"],
                weight=item["weight_load_ratio"],
                line=item["line_refill_ratio"],
                tp=item["throughput_proxy_ratio"],
            )
        )

    lines.extend(
        [
            "",
            "## 对 RTL 草案的直接建议",
            "",
            "- `trial_min_1x4x8` 适合作为最小结构样例：它已经可以验证“整图 accumulator 不落地、tile 内量化写回”的基本机制，但 tile 数仍很高。",
            "- `trial_main_4x8x8` 是最均衡的第一主配置：局部 scratch 约 `15KB`，tile 总数相对最小样例下降 `8x`，同时保留 `4` 个 OC 子块，比较适合作为首个正式设计点。",
            "- `trial_dense_8x8x16` 更像性能导向配置：tile 总数继续减半、吞吐代理提高到 `1024`，但对 accumulator 和 weight tile 的压力明显增大，更适合作为第二阶段配置。",
            "- 这三档里，最值得优先画结构图的是 `4x8x8`，最值得保留作小规模验证的是 `1x4x8`。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = load_json(args.npusim)
    case = load_case(report, "conv2_3x3_b")
    candidates = [build_candidate(case, candidate) for candidate in CANDIDATES]

    output = {
        "layer_name": "conv2_3x3_b",
        "shape": shape_text(case),
        "opt_cycles": int(case["opt_cycles"]),
        "opt_cycles_per_mac": float(case["opt_cycles_per_mac"]),
        "candidates": candidates,
        "comparisons": compare_candidates(candidates),
    }

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(output, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
