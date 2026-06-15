"""Summarize model hardware hotspots from TFLite op profiling and cycle estimates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ops", required=True, help="JSON from profile_tflite_ops.py.")
    parser.add_argument("--cycles", required=True, help="JSON from estimate_npu_cycles.py.")
    parser.add_argument("--out_json", required=True, help="Output JSON summary.")
    parser.add_argument("--out_md", help="Optional Markdown summary.")
    parser.add_argument("--top_k", type=int, default=8, help="Number of hotspot layers to keep.")
    return parser.parse_args()


def classify_layer(op_name: str, input_shapes: list[list[int]]) -> str:
    if op_name == "DEPTHWISE_CONV_2D":
        return "depthwise_conv2d"
    if op_name != "CONV_2D" or len(input_shapes) < 2:
        return "other"
    weight_shape = input_shapes[1]
    if len(weight_shape) != 4:
        return "conv2d_unknown"
    kernel_h, kernel_w = weight_shape[1], weight_shape[2]
    if kernel_h == 3 and kernel_w == 3:
        return "conv2d_3x3"
    if kernel_h == 1 and kernel_w == 1:
        return "conv2d_1x1"
    return f"conv2d_{kernel_h}x{kernel_w}"


def kernel_text(op_name: str, input_shapes: list[list[int]]) -> str:
    if op_name == "DEPTHWISE_CONV_2D":
        weight_shape = input_shapes[1] if len(input_shapes) > 1 else []
        if len(weight_shape) == 4:
            return f"depthwise_{weight_shape[1]}x{weight_shape[2]}"
        return "depthwise"
    if op_name == "CONV_2D" and len(input_shapes) > 1 and len(input_shapes[1]) == 4:
        weight_shape = input_shapes[1]
        return f"{weight_shape[1]}x{weight_shape[2]}"
    return "unknown"


def format_shape(shape: list[int]) -> str:
    return "x".join(str(dim) for dim in shape)


def layer_shape_text(layer: dict[str, Any]) -> str:
    input_shape = layer.get("input_shapes", [[]])[0]
    output_shape = layer.get("output_shapes", [[]])[0]
    if not input_shape or not output_shape:
        return "unknown"
    return f"{format_shape(input_shape)} -> {kernel_text(layer['op_name'], layer['input_shapes'])} -> {format_shape(output_shape)}"


def pct(value: float, total: float) -> float:
    if not total:
        return 0.0
    return value / total * 100.0


def build_summary(ops_report: dict[str, Any], cycle_report: dict[str, Any], top_k: int) -> dict[str, Any]:
    ops_by_index = {item["index"]: item for item in ops_report["operators"]}
    merged_layers: list[dict[str, Any]] = []
    total_macs = 0
    total_ref_cycles = 0
    total_opt_cycles = 0
    category_map: dict[str, dict[str, Any]] = {}

    for layer in cycle_report["layers"]:
        op = ops_by_index.get(layer["index"], {})
        category = classify_layer(layer["op_name"], layer["input_shapes"])
        macs = int(layer.get("estimated_macs") or 0)
        ref_cycles = int(layer.get("estimated_reference_cycles") or 0)
        opt_cycles = int(layer.get("estimated_optimized_cycles") or 0)
        merged = {
            "index": layer["index"],
            "op_name": layer["op_name"],
            "category": category,
            "kernel": kernel_text(layer["op_name"], layer["input_shapes"]),
            "shape_signature": layer_shape_text(layer),
            "input_shapes": op.get("input_shapes", layer.get("input_shapes")),
            "output_shapes": op.get("output_shapes", layer.get("output_shapes")),
            "estimated_macs": macs,
            "estimated_reference_cycles": ref_cycles,
            "estimated_optimized_cycles": opt_cycles,
            "estimated_speedup": layer.get("estimated_speedup"),
            "rate_source": layer.get("rate_source"),
        }
        merged_layers.append(merged)
        total_macs += macs
        total_ref_cycles += ref_cycles
        total_opt_cycles += opt_cycles

        if category not in category_map:
            category_map[category] = {
                "category": category,
                "layer_count": 0,
                "total_macs": 0,
                "total_reference_cycles": 0,
                "total_optimized_cycles": 0,
            }
        item = category_map[category]
        item["layer_count"] += 1
        item["total_macs"] += macs
        item["total_reference_cycles"] += ref_cycles
        item["total_optimized_cycles"] += opt_cycles

    categories = []
    for category in sorted(category_map.values(), key=lambda x: x["total_optimized_cycles"], reverse=True):
        ref_cycles = category["total_reference_cycles"]
        opt_cycles = category["total_optimized_cycles"]
        categories.append(
            {
                **category,
                "mac_share_pct": round(pct(category["total_macs"], total_macs), 2),
                "optimized_cycle_share_pct": round(pct(opt_cycles, total_opt_cycles), 2),
                "reference_cycle_share_pct": round(pct(ref_cycles, total_ref_cycles), 2),
                "speedup": round(ref_cycles / opt_cycles, 4) if opt_cycles else None,
            }
        )

    hotspots = []
    for rank, layer in enumerate(
        sorted(merged_layers, key=lambda x: x["estimated_optimized_cycles"], reverse=True)[:top_k],
        start=1,
    ):
        hotspots.append(
            {
                **layer,
                "rank": rank,
                "optimized_cycle_share_pct": round(
                    pct(layer["estimated_optimized_cycles"], total_opt_cycles), 2
                ),
                "reference_cycle_share_pct": round(
                    pct(layer["estimated_reference_cycles"], total_ref_cycles), 2
                ),
                "mac_share_pct": round(pct(layer["estimated_macs"], total_macs), 2),
            }
        )

    return {
        "model": ops_report["model"],
        "ops_profile": cycle_report["profile"],
        "total_layers_counted": len(merged_layers),
        "total_macs": total_macs,
        "total_reference_cycles": total_ref_cycles,
        "total_optimized_cycles": total_opt_cycles,
        "total_speedup": round(total_ref_cycles / total_opt_cycles, 6) if total_opt_cycles else None,
        "categories": categories,
        "top_hotspots_by_optimized_cycles": hotspots,
    }


def write_markdown(summary: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 硬件热点摘要",
        "",
        f"- 模型：`{summary['model']}`",
        f"- 统计层数：`{summary['total_layers_counted']}`",
        f"- 总 MAC：`{summary['total_macs']:,}`",
        f"- 估算 reference cycles：`{summary['total_reference_cycles']:,}`",
        f"- 估算 optimized cycles：`{summary['total_optimized_cycles']:,}`",
        f"- 模型级估算加速：`{summary['total_speedup']:.2f}x`",
        "",
        "## 按算子类别汇总",
        "",
        "| 类别 | 层数 | 总 MAC | MAC 占比 | 优化后周期 | 周期占比 | 估算加速 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in summary["categories"]:
        lines.append(
            "| {category} | {layer_count} | {total_macs:,} | {mac_share_pct:.2f}% | "
            "{total_optimized_cycles:,} | {optimized_cycle_share_pct:.2f}% | {speedup:.2f}x |".format(
                category=item["category"],
                layer_count=item["layer_count"],
                total_macs=item["total_macs"],
                mac_share_pct=item["mac_share_pct"],
                total_optimized_cycles=item["total_optimized_cycles"],
                optimized_cycle_share_pct=item["optimized_cycle_share_pct"],
                speedup=item["speedup"] if item["speedup"] is not None else 0.0,
            )
        )

    lines.extend(
        [
            "",
            "## 优化后周期热点层",
            "",
            "| 排名 | 层 index | 类别 | 形状 | MAC 占比 | 优化后周期占比 | 估算加速 |",
            "| --- | ---: | --- | --- | ---: | ---: | ---: |",
        ]
    )
    for item in summary["top_hotspots_by_optimized_cycles"]:
        lines.append(
            "| {rank} | {index} | {category} | `{shape_signature}` | {mac_share_pct:.2f}% | "
            "{optimized_cycle_share_pct:.2f}% | {estimated_speedup:.2f}x |".format(
                **item
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    ops_path = Path(args.ops).resolve()
    cycles_path = Path(args.cycles).resolve()
    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)

    ops_report = json.loads(ops_path.read_text(encoding="utf-8"))
    cycle_report = json.loads(cycles_path.read_text(encoding="utf-8"))
    summary = build_summary(ops_report, cycle_report, args.top_k)
    out_json.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    if args.out_md:
        out_md = Path(args.out_md).resolve()
        out_md.parent.mkdir(parents=True, exist_ok=True)
        write_markdown(summary, out_md)

    print(f"Wrote {out_json}")
    if args.out_md:
        print(f"Wrote {Path(args.out_md).resolve()}")
    print(
        f"Hotspots summarized: layers={summary['total_layers_counted']} "
        f"speedup={summary['total_speedup']:.2f}x"
    )


if __name__ == "__main__":
    main()
