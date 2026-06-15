"""Estimate candidate-model cycles from current NPUSim microbenchmarks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


# Current DepthwiseConv NPUSim records from notes/depthwise_conv原始基线.md.
# All cases use out_h=4, out_w=4, kernel=3x3.
DEPTHWISE_BASELINES = [
    {"name": "test_dwconv8to8stride1", "macs": 4 * 4 * 8 * 3 * 3, "ref": 183_142, "opt": 7_310},
    {"name": "test_dwconv32to32stride2", "macs": 4 * 4 * 32 * 3 * 3, "ref": 188_128, "opt": 7_229},
    {"name": "test_dwconv64to64stride1", "macs": 4 * 4 * 64 * 3 * 3, "ref": 360_997, "opt": 10_600},
    {"name": "test_dwconv64to64stride2", "macs": 4 * 4 * 64 * 3 * 3, "ref": 371_072, "opt": 10_441},
    {"name": "test_dwconv16to32stride2", "macs": 4 * 4 * 32 * 3 * 3, "ref": 186_428, "opt": 9_063},
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", required=True)
    parser.add_argument(
        "--conv_report",
        action="append",
        required=True,
        help="Conv2D NPUSim JSON report. Pass multiple times.",
    )
    parser.add_argument("--json_out", required=True)
    parser.add_argument("--md_out", required=True)
    return parser.parse_args()


def empty_accumulator() -> dict:
    return {"macs": 0, "ref_cycles": 0, "opt_cycles": 0}


def add_result(accumulator: dict, result: dict) -> None:
    accumulator["macs"] += result["estimated_macs"]
    accumulator["ref_cycles"] += result["ref_cycles"]
    accumulator["opt_cycles"] += result["opt_cycles"]


def cycles_per_mac(item: dict, cycle_key: str) -> float:
    return item[cycle_key] / item["macs"] if item["macs"] else 0.0


def build_rates(conv_report_paths: list[Path]) -> dict:
    accumulators = {
        "conv2d_3x3": empty_accumulator(),
        "conv2d_1x1": empty_accumulator(),
        "depthwise_conv2d": empty_accumulator(),
    }
    for conv_report_path in conv_report_paths:
        report = json.loads(conv_report_path.read_text(encoding="utf-8"))
        for result in report["results"]:
            filter_shape = result["filter_shape"]
            kernel = [filter_shape[1], filter_shape[2]]
            if kernel == [3, 3]:
                add_result(accumulators["conv2d_3x3"], result)
            elif kernel == [1, 1]:
                add_result(accumulators["conv2d_1x1"], result)

    for baseline in DEPTHWISE_BASELINES:
        accumulators["depthwise_conv2d"]["macs"] += baseline["macs"]
        accumulators["depthwise_conv2d"]["ref_cycles"] += baseline["ref"]
        accumulators["depthwise_conv2d"]["opt_cycles"] += baseline["opt"]

    return {
        name: {
            **item,
            "ref_cycles_per_mac": cycles_per_mac(item, "ref_cycles"),
            "opt_cycles_per_mac": cycles_per_mac(item, "opt_cycles"),
        }
        for name, item in accumulators.items()
    }


def result_shape_key(result: dict) -> tuple[int, int, int, int, int]:
    return (
        result["output_shape"][1],
        result["output_shape"][2],
        result["input_shape"][3],
        result["output_shape"][3],
        result["filter_shape"][1],
    )


def layer_shape_key(layer: dict) -> tuple[int, int, int, int, int] | None:
    if layer["op"] != "CONV_2D" or "kernel" not in layer:
        return None
    return (
        layer["output_shape"][1],
        layer["output_shape"][2],
        layer["input_shape"][3],
        layer["output_shape"][3],
        layer["kernel"][0],
    )


def build_exact_results(conv_report_paths: list[Path]) -> dict:
    exact_results = {}
    for conv_report_path in conv_report_paths:
        report = json.loads(conv_report_path.read_text(encoding="utf-8"))
        for result in report["results"]:
            exact_results[result_shape_key(result)] = result
    return exact_results


def layer_rate_key(layer: dict) -> str | None:
    if layer["op"] == "CONV_2D":
        if layer.get("kernel") == [3, 3]:
            return "conv2d_3x3"
        if layer.get("kernel") == [1, 1]:
            return "conv2d_1x1"
    if layer["op"] == "DEPTHWISE_CONV_2D":
        return "depthwise_conv2d"
    return None


def estimate_candidate(candidate: dict, rates: dict, exact_results: dict) -> dict:
    layers = []
    totals_by_source: dict[str, dict] = {}
    covered_macs = 0
    unsupported_macs = 0
    total_ref_cycles = 0.0
    total_opt_cycles = 0.0

    for layer in candidate["layers"]:
        macs = layer["macs"]
        rate_key = layer_rate_key(layer)
        if rate_key is None:
            unsupported_macs += macs
            layers.append(
                {
                    "name": layer["name"],
                    "op": layer["op"],
                    "estimated_macs": macs,
                    "rate_source": "unsupported",
                }
            )
            continue

        exact_result = exact_results.get(layer_shape_key(layer))
        if exact_result is not None:
            ref_cycles = exact_result["ref_cycles"]
            opt_cycles = exact_result["opt_cycles"]
            source = f"{rate_key}_exact"
        else:
            rate = rates[rate_key]
            ref_cycles = macs * rate["ref_cycles_per_mac"]
            opt_cycles = macs * rate["opt_cycles_per_mac"]
            source = rate_key
        covered_macs += macs
        total_ref_cycles += ref_cycles
        total_opt_cycles += opt_cycles
        source_total = totals_by_source.setdefault(
            rate_key, {"macs": 0, "ref_cycles": 0.0, "opt_cycles": 0.0}
        )
        source_total["macs"] += macs
        source_total["ref_cycles"] += ref_cycles
        source_total["opt_cycles"] += opt_cycles
        layers.append(
            {
                "name": layer["name"],
                "op": layer["op"],
                "kernel": layer.get("kernel"),
                "estimated_macs": macs,
                "rate_source": source,
                "estimated_ref_cycles": round(ref_cycles),
                "estimated_opt_cycles": round(opt_cycles),
            }
        )

    dominant_source = None
    if totals_by_source:
        dominant_source = max(
            totals_by_source.items(), key=lambda item: item[1]["opt_cycles"]
        )[0]

    total_macs = candidate["totals"]["total_macs"]
    return {
        "name": candidate["name"],
        "family": candidate["family"],
        "total_macs": total_macs,
        "covered_macs": covered_macs,
        "covered_mac_ratio": covered_macs / total_macs if total_macs else None,
        "unsupported_macs": unsupported_macs,
        "estimated_ref_cycles": round(total_ref_cycles),
        "estimated_opt_cycles": round(total_opt_cycles),
        "estimated_speedup": (
            total_ref_cycles / total_opt_cycles if total_opt_cycles else None
        ),
        "dominant_opt_source": dominant_source,
        "by_source": {
            name: {
                "macs": value["macs"],
                "estimated_ref_cycles": round(value["ref_cycles"]),
                "estimated_opt_cycles": round(value["opt_cycles"]),
            }
            for name, value in totals_by_source.items()
        },
        "layers": layers,
    }


def format_int_or_dash(value: int | None) -> str:
    return f"{value:,}" if value is not None else "-"


def format_float_or_dash(value: float | None, suffix: str = "") -> str:
    return f"{value:.2f}{suffix}" if value is not None else "-"


def write_markdown(report: dict, out_path: Path) -> None:
    lines = [
        "# 手势识别候选模型粗周期估算",
        "",
        "该报告用当前 NPUSim microbenchmark 的 cycles/MAC 做结构级粗估，只用于排序候选和定位优化优先级，不等同于真实端到端延迟。",
        "",
        "## 使用的基线",
        "",
        "| 类别 | ref cycles/MAC | opt cycles/MAC | 来源 |",
        "| --- | ---: | ---: | --- |",
    ]
    for key, value in report["rates"].items():
        lines.append(
            "| {key} | {ref:.3f} | {opt:.3f} | {source} |".format(
                key=key,
                ref=value["ref_cycles_per_mac"],
                opt=value["opt_cycles_per_mac"],
                source=value["source"],
            )
        )

    lines += [
        "",
        "## 候选估算",
        "",
        "| 模型 | 覆盖 MAC | 估算 ref cycles | 估算 opt cycles | 估算 speedup | 主要 opt 来源 | 判断 |",
        "| --- | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for item in report["candidates"]:
        if item["estimated_opt_cycles"]:
            judgment = "可进入训练/真实 profiling"
            if item["dominant_opt_source"] == "conv2d_1x1":
                judgment = "1x1 pointwise 是主要硬件风险"
            if item["name"].startswith("gesture_static"):
                judgment = "3x3 优化展示主线，当前闭环最清楚"
        else:
            judgment = "当前 NPU 卷积基线不能覆盖"

        lines.append(
            "| {name} | {covered:.1%} | {ref} | {opt} | {speedup} | {source} | {judgment} |".format(
                name=item["name"],
                covered=item["covered_mac_ratio"] or 0.0,
                ref=format_int_or_dash(item["estimated_ref_cycles"]),
                opt=format_int_or_dash(item["estimated_opt_cycles"]),
                speedup=format_float_or_dash(item["estimated_speedup"], "x"),
                source=item["dominant_opt_source"] or "-",
                judgment=judgment,
            )
        )

    lines += [
        "",
        "## 结论",
        "",
        "- `gesture_static_cnn_v1_64` 的模型级 Conv2D 估算已覆盖 100% MAC，当前 opt 约 2,776 万 cycles，是最清楚的硬件优化展示主线。",
        "- `mobilenet_v1_0.25_64` 的估算 opt cycles 与 static CNN 同量级，但主要受 1x1 pointwise Conv2D 限制，必须训练后再决定是否投入 1x1 kernel 优化。",
        "- `mobilenet_v1_0.50_96` 的 MAC 虽低于 static CNN，但在当前 1x1 路径下估算 cycles 更高；除非准确率明显更好，否则不是第一优先硬件验证模型。",
        "- `keypoint_tcn_16f` 当前不被 Conv2D/DepthwiseConv 基线覆盖，它是产品路线对照，不是验证当前 NPU 3x3/1x1 kernel 的主线。",
        "",
    ]
    out_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    candidates_path = Path(args.candidates).resolve()
    conv_report_paths = [Path(path).resolve() for path in args.conv_report]
    json_out = Path(args.json_out).resolve()
    md_out = Path(args.md_out).resolve()
    json_out.parent.mkdir(parents=True, exist_ok=True)
    md_out.parent.mkdir(parents=True, exist_ok=True)

    candidates_report = json.loads(candidates_path.read_text(encoding="utf-8"))
    rates = build_rates(conv_report_paths)
    exact_results = build_exact_results(conv_report_paths)
    rates_with_sources = {
        "conv2d_3x3": {
            **rates["conv2d_3x3"],
            "source": "static_cnn_v1_npucycles.json",
        },
        "conv2d_1x1": {
            **rates["conv2d_1x1"],
            "source": "pointwise_conv2d_npucycles.json",
        },
        "depthwise_conv2d": {
            **rates["depthwise_conv2d"],
            "source": "notes/depthwise_conv原始基线.md",
        },
    }

    report = {
        "candidates": [
            estimate_candidate(candidate, rates_with_sources, exact_results)
            for candidate in candidates_report["candidates"]
        ],
        "rates": rates_with_sources,
        "inputs": {
            "candidates": str(candidates_path),
            "conv_reports": [str(path) for path in conv_report_paths],
        },
    }
    json_out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    write_markdown(report, md_out)
    print(f"Wrote {json_out}")
    print(f"Wrote {md_out}")


if __name__ == "__main__":
    main()
