"""Analyze RTL-oriented dataflow pressure for verified core 3x3 layers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--npusim", required=True, help="Input NPUSim JSON.")
    parser.add_argument("--out_json", required=True, help="Output analysis JSON.")
    parser.add_argument("--out_md", required=True, help="Output Markdown report.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def count_valid_kernel_points(
    input_height: int,
    input_width: int,
    output_height: int,
    output_width: int,
    filter_height: int,
    filter_width: int,
    stride_height: int,
    stride_width: int,
    pad_height: int,
    pad_width: int,
) -> int:
    total = 0
    for out_y in range(output_height):
        in_y_origin = out_y * stride_height - pad_height
        for out_x in range(output_width):
            in_x_origin = out_x * stride_width - pad_width
            for ky in range(filter_height):
                in_y = in_y_origin + ky
                if in_y < 0 or in_y >= input_height:
                    continue
                for kx in range(filter_width):
                    in_x = in_x_origin + kx
                    if 0 <= in_x < input_width:
                        total += 1
    return total


def pair_window_union_points(parallel_outputs: int) -> int:
    return 3 * (parallel_outputs + 2)


def shape_text(item: dict[str, Any]) -> str:
    return (
        f"{item['input_shape'][1]}x{item['input_shape'][2]}x{item['input_shape'][3]} -> "
        f"{item['filter_hw']}x{item['filter_hw']} -> "
        f"{item['output_shape'][1]}x{item['output_shape'][2]}x{item['output_shape'][3]}"
    )


def analyze_item(item: dict[str, Any]) -> dict[str, Any]:
    input_height = int(item["input_shape"][1])
    input_width = int(item["input_shape"][2])
    input_depth = int(item["input_shape"][3])
    output_height = int(item["output_shape"][1])
    output_width = int(item["output_shape"][2])
    output_depth = int(item["output_shape"][3])
    filter_hw = int(item["filter_hw"])
    stride = int(item["stride"])
    pad = int(item["pad"])

    output_elements = output_height * output_width * output_depth
    padded_input_points = (input_height + 2 * pad) * (input_width + 2 * pad)
    valid_kernel_points = count_valid_kernel_points(
        input_height=input_height,
        input_width=input_width,
        output_height=output_height,
        output_width=output_width,
        filter_height=filter_hw,
        filter_width=filter_hw,
        stride_height=stride,
        stride_width=stride,
        pad_height=pad,
        pad_width=pad,
    )
    baseline_input_scalar_reads = valid_kernel_points * input_depth
    padded_stream_scalar_loads = padded_input_points * input_depth

    full_map_acc_scratch_bytes = output_elements * 4
    full_map_acc_roundtrip_bytes = full_map_acc_scratch_bytes * 2
    output_write_bytes = output_elements
    row_stationary_acc_scratch_bytes = output_width * output_depth * 4
    row_stationary_scratch_reduction = (
        full_map_acc_scratch_bytes / row_stationary_acc_scratch_bytes
        if row_stationary_acc_scratch_bytes
        else 0.0
    )

    two_output_union = pair_window_union_points(2)
    four_output_union = pair_window_union_points(4)
    two_output_naive = 2 * filter_hw * filter_hw
    four_output_naive = 4 * filter_hw * filter_hw

    return {
        "layer_name": item["layer_name"],
        "shape": shape_text(item),
        "estimated_macs": int(item["estimated_macs"]),
        "opt_cycles": int(item["opt_cycles"]),
        "opt_cycles_per_mac": float(item["opt_cycles_per_mac"]),
        "output_elements": output_elements,
        "full_map_acc_scratch_bytes": full_map_acc_scratch_bytes,
        "full_map_acc_roundtrip_bytes": full_map_acc_roundtrip_bytes,
        "output_write_bytes": output_write_bytes,
        "acc_roundtrip_vs_output_write": (
            full_map_acc_roundtrip_bytes / output_write_bytes if output_write_bytes else 0.0
        ),
        "row_stationary_acc_scratch_bytes": row_stationary_acc_scratch_bytes,
        "row_stationary_scratch_reduction": row_stationary_scratch_reduction,
        "valid_kernel_points": valid_kernel_points,
        "baseline_input_scalar_reads": baseline_input_scalar_reads,
        "padded_stream_scalar_loads": padded_stream_scalar_loads,
        "input_stream_reduction_ratio": (
            baseline_input_scalar_reads / padded_stream_scalar_loads
            if padded_stream_scalar_loads
            else 0.0
        ),
        "two_output_parallel": {
            "naive_points": two_output_naive,
            "union_points": two_output_union,
            "spatial_load_saving_ratio": 1.0 - (two_output_union / two_output_naive),
        },
        "four_output_parallel": {
            "naive_points": four_output_naive,
            "union_points": four_output_union,
            "spatial_load_saving_ratio": 1.0 - (four_output_union / four_output_naive),
        },
    }


def build_peer_deltas(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_name = {item["layer_name"]: item for item in results}
    pairs = [
        ("conv2_3x3_a", "conv3_3x3_a"),
        ("conv2_3x3_b", "conv3_3x3_b"),
    ]
    deltas: list[dict[str, Any]] = []
    for lhs_name, rhs_name in pairs:
        lhs = by_name.get(lhs_name)
        rhs = by_name.get(rhs_name)
        if not lhs or not rhs:
            continue
        deltas.append(
            {
                "pair": f"{lhs_name} vs {rhs_name}",
                "same_mac": lhs["estimated_macs"] == rhs["estimated_macs"],
                "extra_opt_cycles_48x48": lhs["opt_cycles"] - rhs["opt_cycles"],
                "extra_opt_cycles_per_mac_48x48": lhs["opt_cycles_per_mac"] - rhs["opt_cycles_per_mac"],
                "extra_acc_roundtrip_bytes_48x48": (
                    lhs["full_map_acc_roundtrip_bytes"] - rhs["full_map_acc_roundtrip_bytes"]
                ),
            }
        )
    return deltas


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# static_cnn_i96 core 3x3 数据流建模报告",
        "",
        "- 口径说明：本报告不声称新的加速结果，只把当前 baseline 的数据搬运压力转成更贴近 RTL 的量化指标。",
        "- 数据来源：`gesture_project/reports/static_cnn_i96_core_3x3_npusim.json`",
        "- 目标对象：已通过 correctness 验证的四个 core 3x3 主体层，重点观察 `48x48` 两层。",
        "",
        "## 全层指标",
        "",
        "| 层名 | 形状 | opt cycles/MAC | acc 整图往返 | 整图 scratch | 行驻留 scratch | scratch 缩减 | 输入流量压缩潜力 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in report["results"]:
        lines.append(
            "| `{name}` | `{shape}` | {cpm:.3f} | {acc_rt:,} B | {acc_scratch:,} B | {row_scratch:,} B | {scratch_red:.1f}x | {stream_red:.2f}x |".format(
                name=item["layer_name"],
                shape=item["shape"],
                cpm=item["opt_cycles_per_mac"],
                acc_rt=item["full_map_acc_roundtrip_bytes"],
                acc_scratch=item["full_map_acc_scratch_bytes"],
                row_scratch=item["row_stationary_acc_scratch_bytes"],
                scratch_red=item["row_stationary_scratch_reduction"],
                stream_red=item["input_stream_reduction_ratio"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 对 24x24 的同 MAC 对照",
            "",
            "| 对照对 | 48x48 额外 opt cycles | 48x48 额外 cycles/MAC | 48x48 额外 acc 往返 |",
            "| --- | ---: | ---: | ---: |",
        ]
    )

    for item in report["peer_deltas"]:
        lines.append(
            "| `{pair}` | {cycles:,} | {cpm:.3f} | {bytes_:,} B |".format(
                pair=item["pair"],
                cycles=item["extra_opt_cycles_48x48"],
                cpm=item["extra_opt_cycles_per_mac_48x48"],
                bytes_=item["extra_acc_roundtrip_bytes_48x48"],
            )
        )

    lines.extend(
        [
            "",
            "## 空间复用建模",
            "",
            "| 并行输出数 | naive 3x3 取数点 | 共享后 union 点 | 单步空间取数节省 |",
            "| --- | ---: | ---: | ---: |",
        ]
    )

    sample = report["results"][0]
    lines.append(
        "| 2 | {naive} | {union} | {saving:.1%} |".format(
            naive=sample["two_output_parallel"]["naive_points"],
            union=sample["two_output_parallel"]["union_points"],
            saving=sample["two_output_parallel"]["spatial_load_saving_ratio"],
        )
    )
    lines.append(
        "| 4 | {naive} | {union} | {saving:.1%} |".format(
            naive=sample["four_output_parallel"]["naive_points"],
            union=sample["four_output_parallel"]["union_points"],
            saving=sample["four_output_parallel"]["spatial_load_saving_ratio"],
        )
    )

    lines.extend(
        [
            "",
            "## 结论",
            "",
            "- `48x48` 两层的整图 `accs_buf` 往返分别达到 `589,824 B`，正好是对应最终 `int8` 输出写回的 `8x`，这解释了它们为什么更像输出驻留优化的第一受益对象。",
            "- 如果 RTL 改成按行或小 tile 驻留，`48x48` 层的 accumulator scratch 可以从整图 `294,912 B` 压到单行 `6,144 B`，规模上是 `48x` 的削减；`24x24` 层对应是 `24x`。",
            "- 对 stride1 的 `3x3` 主体层，水平相邻 2 个输出像素共享后只需要 `12` 个空间点而不是 `18` 个，单步空间取数可省 `33.3%`；若做到 4 像素并行，空间点需求可从 `36` 降到 `18`。",
            "- 以上数字只是数据流上限分析，不等价于软件 kernel 立刻能拿到同等提速；它的意义是为后续 RTL 设计明确哪部分搬运最值得被硬件吞掉。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = load_json(args.npusim)
    results = [analyze_item(item) for item in report["results"]]
    results.sort(key=lambda item: (-item["output_elements"], item["layer_name"]))

    analysis = {
        "model": report["model"],
        "scope": "RTL-oriented dataflow analysis for verified core 3x3 layers",
        "results": results,
        "peer_deltas": build_peer_deltas(results),
    }

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(analysis, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(analysis, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
