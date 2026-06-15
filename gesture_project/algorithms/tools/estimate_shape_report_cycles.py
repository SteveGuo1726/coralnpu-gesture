"""Estimate static CNN Conv2D cycles from shape and NPUSim reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shape_report", required=True)
    parser.add_argument(
        "--npusim_report",
        action="append",
        required=True,
        help="NPUSim JSON report. Pass multiple times to merge reports.",
    )
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def shape_key(layer: dict) -> tuple[int, int, int, int, int]:
    return (
        layer["output_shape"][1],
        layer["output_shape"][2],
        layer["input_shape"][3],
        layer["output_shape"][3],
        layer["kernel"][0],
    )


def result_key(result: dict) -> tuple[int, int, int, int, int]:
    return (
        result["output_shape"][1],
        result["output_shape"][2],
        result["input_shape"][3],
        result["output_shape"][3],
        result["filter_shape"][1],
    )


def main() -> None:
    args = parse_args()
    shape_report_path = Path(args.shape_report).resolve()
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    shape_report = json.loads(shape_report_path.read_text(encoding="utf-8"))
    npusim_report_paths = [Path(path).resolve() for path in args.npusim_report]
    result_by_shape = {}
    for npusim_report_path in npusim_report_paths:
        npusim_report = json.loads(npusim_report_path.read_text(encoding="utf-8"))
        for result in npusim_report["results"]:
            result_by_shape[result_key(result)] = result

    layers = []
    total_macs = 0
    matched_macs = 0
    total_ref_cycles = 0
    total_opt_cycles = 0
    all_matched_have_ref = True

    for layer in shape_report["layers"]:
        if layer["type"] != "Conv2D":
            continue
        total_macs += layer["estimated_macs"]
        result = result_by_shape.get(shape_key(layer))
        layer_report = {
            "name": layer["name"],
            "kernel": layer["kernel"],
            "input_shape": layer["input_shape"],
            "output_shape": layer["output_shape"],
            "estimated_macs": layer["estimated_macs"],
            "npusim_matched": result is not None,
        }
        if result is not None:
            matched_macs += layer["estimated_macs"]
            layer_report.update(
                {
                    "expected_current_path": result["expected_current_path"],
                    "ref_cycles": result["ref_cycles"],
                    "opt_cycles": result["opt_cycles"],
                    "speedup": result["speedup"],
                    "opt_cycles_per_mac": result["opt_cycles_per_mac"],
                    "ref_cycles_per_mac": result["ref_cycles_per_mac"],
                }
            )
            total_opt_cycles += result["opt_cycles"]
            if result["ref_cycles"] is None:
                all_matched_have_ref = False
            else:
                total_ref_cycles += result["ref_cycles"]
        layers.append(layer_report)

    report = {
        "shape_report": str(shape_report_path),
        "npusim_reports": [str(path) for path in npusim_report_paths],
        "layers": layers,
        "totals": {
            "conv2d_total_macs": total_macs,
            "matched_macs": matched_macs,
            "matched_mac_ratio": matched_macs / total_macs if total_macs else None,
            "matched_ref_cycles": total_ref_cycles if all_matched_have_ref else None,
            "matched_opt_cycles": total_opt_cycles,
            "matched_speedup": (
                total_ref_cycles / total_opt_cycles
                if all_matched_have_ref and total_opt_cycles
                else None
            ),
        },
    }

    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")
    print(
        "Matched MAC ratio: "
        f"{report['totals']['matched_mac_ratio'] * 100:.2f}%"
        if report["totals"]["matched_mac_ratio"] is not None
        else "No Conv2D MACs found."
    )


if __name__ == "__main__":
    main()
