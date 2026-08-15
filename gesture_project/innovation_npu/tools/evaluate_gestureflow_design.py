#!/usr/bin/env python3
"""Evaluate project-local GestureFlow-NPU candidates against a CNN description.

This is a deterministic analytical model, intentionally kept separate from the
read-only Google CoralNPU repository. It is a design gate: every reported
quantity comes from a network layer shape and an explicit dataflow assumption.
It does not claim RTL-cycle or FPGA timing accuracy.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


@dataclass
class LayerShape:
    name: str
    height: int
    width: int
    input_channels: int
    output_channels: int
    kernel: int

    @property
    def output_pixels(self) -> int:
        return self.height * self.width

    @property
    def macs(self) -> int:
        return self.output_pixels * self.input_channels * self.output_channels * self.kernel * self.kernel

    @property
    def input_bytes(self) -> int:
        return self.height * self.width * self.input_channels

    @property
    def weight_bytes(self) -> int:
        return self.kernel * self.kernel * self.input_channels * self.output_channels

    @property
    def output_bytes(self) -> int:
        return self.height * self.width * self.output_channels


def network_shapes(config: dict[str, Any]) -> tuple[list[LayerShape], int]:
    network = config["network"]
    height = int(network["input_height"])
    width = int(network["input_width"])
    channels = int(network["input_channels"])
    shapes: list[LayerShape] = []

    for layer in network["layers"]:
        shape = LayerShape(
            name=str(layer["name"]),
            height=height,
            width=width,
            input_channels=channels,
            output_channels=int(layer["output_channels"]),
            kernel=int(layer["kernel"]),
        )
        shapes.append(shape)
        pool = int(layer.get("pool_after", 1))
        height = ceil_div(height, pool)
        width = ceil_div(width, pool)
        channels = shape.output_channels

    classifier = network["classifier"]
    if channels != int(classifier["input_channels"]):
        raise ValueError("Classifier input channels do not match final convolution output channels.")
    classifier_macs = int(classifier["input_channels"]) * int(classifier["output_classes"])
    return shapes, classifier_macs


def layer_report(shape: LayerShape, candidate: dict[str, Any], assumptions: dict[str, Any]) -> dict[str, Any]:
    spatial = int(candidate["spatial_parallel"])
    oc_parallel = int(candidate["output_channel_parallel"])
    ic_parallel = int(candidate["input_channel_parallel"])
    macs_per_cycle = int(candidate["macs_per_cycle"])
    if spatial * oc_parallel * ic_parallel != macs_per_cycle:
        raise ValueError(f"{candidate['name']}: macs_per_cycle must equal spatial*oc*ic.")

    activation_bytes = int(assumptions["activation_bytes"])
    weight_bytes = int(assumptions["weight_bytes"])
    output_bytes = int(assumptions["output_bytes"])
    partial_sum_bytes = int(assumptions["partial_sum_bytes"])
    stripe_rows = min(int(candidate["stripe_output_rows"]), shape.height)
    oc_tiles = ceil_div(shape.output_channels, oc_parallel)
    ic_tiles = ceil_div(shape.input_channels, ic_parallel)
    spatial_tiles = ceil_div(shape.output_pixels, spatial)
    compute_cycles = spatial_tiles * oc_tiles * ic_tiles * shape.kernel * shape.kernel
    ideal_cycles = ceil_div(shape.macs, macs_per_cycle)
    lane_utilization = shape.macs / (compute_cycles * macs_per_cycle)

    # Direct tiled traversal reloads an input window for every output-channel tile.
    # This is the explicit no-row-reuse baseline, not a claim about an optimized NPU.
    no_reuse_input = shape.output_pixels * oc_tiles * shape.kernel * shape.kernel * shape.input_channels * activation_bytes
    no_reuse_weight = shape.weight_bytes * ceil_div(shape.output_pixels, stripe_rows * shape.width) * weight_bytes
    no_reuse_output = shape.output_bytes * output_bytes

    # A 16-KiB weight SRAM retains one output-channel tile, rather than claiming
    # that all layer weights fit. Two legal traversal orders are compared:
    # 1. Stripe outer: keep the K-row input stream continuous and reload every
    #    output-channel weight tile for each stripe.
    # 2. Output-channel tile outer: load each weight tile once, but reread the
    #    feature map for each output-channel tile.
    # The controller selects the lower byte count per layer. This is deliberately
    # stricter than a theoretical lower bound that assumes all input and all
    # weights can both remain on-chip.
    stripe_count = ceil_div(shape.height, stripe_rows)
    weight_tile_bytes = shape.kernel * shape.kernel * shape.input_channels * min(oc_parallel, shape.output_channels) * weight_bytes
    stripe_outer_input = shape.input_bytes * activation_bytes
    stripe_outer_weight = shape.weight_bytes * weight_bytes * stripe_count
    stripe_outer_ddr = stripe_outer_input + stripe_outer_weight + shape.output_bytes * output_bytes
    oc_outer_input = shape.input_bytes * activation_bytes * oc_tiles
    oc_outer_weight = shape.weight_bytes * weight_bytes
    oc_outer_ddr = oc_outer_input + oc_outer_weight + shape.output_bytes * output_bytes
    if stripe_outer_ddr <= oc_outer_ddr:
        flow_schedule = "stripe_outer"
        flow_ddr = stripe_outer_ddr
    else:
        flow_schedule = "output_channel_tile_outer"
        flow_ddr = oc_outer_ddr
    no_reuse_ddr = no_reuse_input + no_reuse_weight + no_reuse_output

    line_buffer = (shape.kernel - 1) * shape.width * shape.input_channels * activation_bytes
    input_stripe = min(shape.height, stripe_rows + shape.kernel - 1) * shape.width * shape.input_channels * activation_bytes
    psum_stripe = stripe_rows * shape.width * min(oc_parallel, shape.output_channels) * partial_sum_bytes
    output_stripe = stripe_rows * shape.width * min(oc_parallel, shape.output_channels) * output_bytes
    required_data_sram = line_buffer + input_stripe + psum_stripe + 2 * output_stripe
    capacity_ok = required_data_sram <= int(candidate["data_sram_bytes"])
    weights_fit = weight_tile_bytes <= int(candidate["weight_sram_bytes"])

    return {
        "name": shape.name,
        "shape": {
            "height": shape.height,
            "width": shape.width,
            "input_channels": shape.input_channels,
            "output_channels": shape.output_channels,
            "kernel": shape.kernel,
        },
        "macs": shape.macs,
        "compute_cycles_estimate": compute_cycles,
        "ideal_cycles_lower_bound": ideal_cycles,
        "array_utilization": lane_utilization,
        "ddr_bytes_no_reuse_baseline": no_reuse_ddr,
        "ddr_bytes_gestureflow_estimate": flow_ddr,
        "ddr_reduction_ratio": no_reuse_ddr / flow_ddr,
        "dataflow_schedule": flow_schedule,
        "stripe_count": stripe_count,
        "weight_tile_bytes": weight_tile_bytes,
        "stripe_outer_ddr_bytes": stripe_outer_ddr,
        "output_channel_tile_outer_ddr_bytes": oc_outer_ddr,
        "sram": {
            "line_buffer_bytes": line_buffer,
            "input_stripe_bytes": input_stripe,
            "partial_sum_stripe_bytes": psum_stripe,
            "output_pingpong_bytes": 2 * output_stripe,
            "required_data_sram_bytes": required_data_sram,
            "data_sram_capacity_ok": capacity_ok,
            "weight_tile_bytes": weight_tile_bytes,
            "weight_tile_capacity_ok": weights_fit,
        },
    }


def evaluate(config: dict[str, Any]) -> dict[str, Any]:
    shapes, classifier_macs = network_shapes(config)
    assumptions = config["assumptions"]
    results: list[dict[str, Any]] = []
    for candidate in config["array_candidates"]:
        layers = [layer_report(shape, candidate, assumptions) for shape in shapes]
        totals = {
            "convolution_macs": sum(layer["macs"] for layer in layers),
            "classifier_macs": classifier_macs,
            "compute_cycles_estimate": sum(layer["compute_cycles_estimate"] for layer in layers),
            "ideal_cycles_lower_bound": sum(layer["ideal_cycles_lower_bound"] for layer in layers),
            "ddr_bytes_no_reuse_baseline": sum(layer["ddr_bytes_no_reuse_baseline"] for layer in layers),
            "ddr_bytes_gestureflow_estimate": sum(layer["ddr_bytes_gestureflow_estimate"] for layer in layers),
        }
        totals["ddr_reduction_ratio"] = totals["ddr_bytes_no_reuse_baseline"] / totals["ddr_bytes_gestureflow_estimate"]
        totals["array_utilization"] = totals["convolution_macs"] / (totals["compute_cycles_estimate"] * int(candidate["macs_per_cycle"]))
        totals["all_data_sram_layers_fit"] = all(layer["sram"]["data_sram_capacity_ok"] for layer in layers)
        totals["all_weight_tiles_fit"] = all(layer["sram"]["weight_tile_capacity_ok"] for layer in layers)
        results.append({"candidate": candidate, "layers": layers, "totals": totals})
    return {
        "project_module": config["project_module"],
        "ownership": config["ownership"],
        "model_assumptions": assumptions,
        "results": results,
    }


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# GestureFlow-NPU v0 真实层形状评估",
        "",
        "此报告由项目侧 `innovation_npu/tools/evaluate_gestureflow_design.py` 生成，",
        "不是 Google 官方 CoralNPU 报告，也不是 RTL/FPGA 周期结果。",
        "",
    ]
    for item in report["results"]:
        candidate = item["candidate"]
        totals = item["totals"]
        lines.extend([
            f"## {candidate['name']} ({candidate['macs_per_cycle']} INT8 MAC/周期)",
            "",
            f"- 卷积 MAC: {totals['convolution_macs']:,}",
            f"- 分类 MAC: {totals['classifier_macs']:,}",
            f"- 计算周期估计: {totals['compute_cycles_estimate']:,}",
            f"- 理想下界: {totals['ideal_cycles_lower_bound']:,}",
            f"- 阵列利用率: {totals['array_utilization']:.2%}",
            f"- 无行复用分块基线 DDR: {totals['ddr_bytes_no_reuse_baseline']:,} B",
            f"- GestureFlow 估计 DDR: {totals['ddr_bytes_gestureflow_estimate']:,} B",
            f"- DDR 降低倍数: {totals['ddr_reduction_ratio']:.2f}x",
            f"- 所有层数据 SRAM 可容纳: {totals['all_data_sram_layers_fit']}",
            f"- 所有输出通道权重 tile 可容纳: {totals['all_weight_tiles_fit']}",
            "",
            "|层|MAC|周期估计|阵列利用率|调度|GestureFlow DDR (B)|所需数据 SRAM (B)|",
            "|---|---:|---:|---:|---|---:|---:|",
        ])
        for layer in item["layers"]:
            lines.append(
                f"|{layer['name']}|{layer['macs']:,}|{layer['compute_cycles_estimate']:,}|"
                f"{layer['array_utilization']:.2%}|{layer['dataflow_schedule']}|{layer['ddr_bytes_gestureflow_estimate']:,}|"
                f"{layer['sram']['required_data_sram_bytes']:,}|"
            )
        lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--markdown-out", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    report = evaluate(config)
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    args.markdown_out.write_text(markdown(report) + "\n", encoding="utf-8")
    for item in report["results"]:
        totals = item["totals"]
        print(
            f"{item['candidate']['name']}: macs={totals['convolution_macs']:,} "
            f"cycles={totals['compute_cycles_estimate']:,} "
            f"util={totals['array_utilization']:.2%} "
            f"ddr_reduction={totals['ddr_reduction_ratio']:.2f}x "
            f"sram_fit={totals['all_data_sram_layers_fit']}"
        )


if __name__ == "__main__":
    main()
