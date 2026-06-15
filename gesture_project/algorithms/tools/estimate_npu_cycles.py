"""Estimate model Conv2D cycle impact from NPUSim microbenchmarks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


# Cycles/MAC from current NPUSim records. These are coarse estimates used only
# for ranking optimization opportunities before model-specific NPUSim replay.
DEFAULT_BASELINES = {
    # Aggregated from reports/static_cnn_v1_npucycles.json.
    "conv2d_3x3_ref": {"macs": 39_518_208, "cycles": 491_614_476},
    "conv2d_3x3_opt": {"macs": 39_518_208, "cycles": 22_960_527},
    # Aggregated from reports/pointwise_conv2d_npucycles.json.
    "conv2d_1x1_ref": {"macs": 4_587_520, "cycles": 124_231_348},
    "conv2d_1x1_opt": {"macs": 4_587_520, "cycles": 60_417_080},
    # Aggregated from notes/depthwise_conv原始基线.md.
    "depthwise_conv2d_ref": {"macs": 24_768, "cycles": 1_289_767},
    "depthwise_conv2d_opt": {"macs": 24_768, "cycles": 44_643},
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ops", required=True, help="JSON from profile_tflite_ops.py.")
    parser.add_argument("--out", required=True, help="Output JSON estimate.")
    return parser.parse_args()


def cycles_per_mac(key: str) -> float:
    item = DEFAULT_BASELINES[key]
    return item["cycles"] / item["macs"]


def select_rates(op: dict) -> tuple[float, float, str]:
    if op["op_name"] not in {"CONV_2D", "DEPTHWISE_CONV_2D"} or len(op["input_shapes"]) < 2:
        return 0.0, 0.0, "unsupported"
    weight_shape = op["input_shapes"][1]
    if len(weight_shape) != 4:
        return 0.0, 0.0, "unknown_weight_shape"
    if op["op_name"] == "DEPTHWISE_CONV_2D":
        return (
            cycles_per_mac("depthwise_conv2d_ref"),
            cycles_per_mac("depthwise_conv2d_opt"),
            "depthwise_conv2d_npusim_rate",
        )
    kernel_h, kernel_w = weight_shape[1], weight_shape[2]
    if kernel_h == 3 and kernel_w == 3:
        return (
            cycles_per_mac("conv2d_3x3_ref"),
            cycles_per_mac("conv2d_3x3_opt"),
            "3x3_oc_vectorized_microbench",
        )
    if kernel_h == 1 and kernel_w == 1:
        return (
            cycles_per_mac("conv2d_1x1_ref"),
            cycles_per_mac("conv2d_1x1_opt"),
            "1x1_pointwise_microbench",
        )
    return 0.0, 0.0, f"unsupported_kernel_{kernel_h}x{kernel_w}"


def main() -> None:
    args = parse_args()
    ops_path = Path(args.ops).resolve()
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    profile = json.loads(ops_path.read_text(encoding="utf-8"))
    layer_estimates = []
    total_ref = 0.0
    total_opt = 0.0

    for op in profile["operators"]:
        macs = op.get("estimated_macs")
        if not macs:
            continue
        ref_rate, opt_rate, source = select_rates(op)
        if source == "unsupported":
            continue
        ref_cycles = macs * ref_rate
        opt_cycles = macs * opt_rate
        total_ref += ref_cycles
        total_opt += opt_cycles
        layer_estimates.append(
            {
                "index": op["index"],
                "op_name": op["op_name"],
                "input_shapes": op["input_shapes"],
                "output_shapes": op["output_shapes"],
                "estimated_macs": macs,
                "rate_source": source,
                "estimated_reference_cycles": round(ref_cycles),
                "estimated_optimized_cycles": round(opt_cycles),
                "estimated_speedup": ref_cycles / opt_cycles if opt_cycles else None,
            }
        )

    report = {
        "profile": str(ops_path),
        "baseline_rates": {
            key: {
                **value,
                "cycles_per_mac": value["cycles"] / value["macs"],
            }
            for key, value in DEFAULT_BASELINES.items()
        },
        "layers": layer_estimates,
        "total_reference_cycles": round(total_ref),
        "total_optimized_cycles": round(total_opt),
        "total_speedup": total_ref / total_opt if total_opt else None,
    }
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")
    print(
        f"Estimated Conv2D cycles: ref={round(total_ref)} "
        f"opt={round(total_opt)} speedup={report['total_speedup']:.2f}x"
        if total_opt
        else "No supported Conv2D MACs found."
    )


if __name__ == "__main__":
    main()
