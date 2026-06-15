"""Generate a static shape/MAC report for gesture_static_cnn_v1."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image_size", type=int, default=64)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def conv2d_report(name: str, h: int, w: int, in_c: int, out_c: int, k: int) -> dict:
    macs = h * w * out_c * k * k * in_c
    return {
        "name": name,
        "type": "Conv2D",
        "kernel": [k, k],
        "input_shape": [1, h, w, in_c],
        "output_shape": [1, h, w, out_c],
        "estimated_macs": macs,
    }


def main() -> None:
    args = parse_args()
    h = args.image_size
    w = args.image_size
    layers = []

    layers.append(conv2d_report("conv1_3x3_a", h, w, 3, 16, 3))
    layers.append(conv2d_report("conv1_3x3_b", h, w, 16, 16, 3))
    h //= 2
    w //= 2
    layers.append(conv2d_report("conv2_3x3_a", h, w, 16, 32, 3))
    layers.append(conv2d_report("conv2_3x3_b", h, w, 32, 32, 3))
    h //= 2
    w //= 2
    layers.append(conv2d_report("conv3_3x3_a", h, w, 32, 64, 3))
    layers.append(conv2d_report("conv3_3x3_b", h, w, 64, 64, 3))
    h //= 2
    w //= 2
    layers.append(conv2d_report("conv_head_1x1", h, w, 64, 96, 1))

    report = {
        "model": "gesture_static_cnn_v1",
        "image_size": args.image_size,
        "layers": layers,
        "conv2d_total_macs": sum(layer["estimated_macs"] for layer in layers),
        "conv2d_3x3_total_macs": sum(
            layer["estimated_macs"] for layer in layers if layer["kernel"] == [3, 3]
        ),
        "recommended_microbench_shapes": sorted(
            {
                (
                    layer["output_shape"][1],
                    layer["output_shape"][2],
                    layer["input_shape"][3],
                    layer["output_shape"][3],
                    layer["kernel"][0],
                )
                for layer in layers
                if layer["type"] == "Conv2D"
            }
        ),
    }
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
