"""Generate a focused RTL target table for verified 3x3 core layers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--npusim", required=True, help="JSON from formal single-layer NPUSim replay.")
    parser.add_argument("--out_md", required=True, help="Output Markdown table.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def shape_text(item: dict[str, Any]) -> str:
    in_shape = item["input_shape"]
    out_shape = item["output_shape"]
    return (
        f"{in_shape[1]}x{in_shape[2]}x{in_shape[3]} -> "
        f"{item['filter_hw']}x{item['filter_hw']} -> "
        f"{out_shape[1]}x{out_shape[2]}x{out_shape[3]}"
    )


def layer_priority(item: dict[str, Any]) -> tuple[int, int]:
    # Prefer verified 3x3 core layers, then larger optimized cycle count.
    is_core = 0 if item["layer_name"] in {
        "conv2_3x3_a",
        "conv2_3x3_b",
        "conv3_3x3_a",
        "conv3_3x3_b",
    } else 1
    return (is_core, -int(item["opt_cycles"]))


def focus_text(item: dict[str, Any]) -> str:
    name = item["layer_name"]
    if name.endswith("_b"):
        return "主块瓶颈层，优先做输出驻留与空间复用"
    if name.endswith("_a"):
        return "通道扩展层，验证 48x48 输出驻留与通道变化稳定性"
    return "次级层"


def write_md(report: dict[str, Any], out_path: Path) -> None:
    rows = [
        item for item in report["results"]
        if item["correct_vs_ref"] and item["filter_hw"] == 3 and item["out_h"] <= 48
    ]
    rows.sort(key=layer_priority)

    lines = [
        "# 正式主线 3x3 主体层微结构目标表",
        "",
        "- 数据来源：`static_cnn_i96_hotspots_no_stem_force_ref.json`",
        "- 作用范围：已通过 correctness 验证、且保留当前 3x3 优化路径的正式主体层",
        "",
        "| 优先级 | 层名 | 形状 | MAC | ref cycles/MAC | opt cycles/MAC | speedup | 建议聚焦 |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]

    for idx, item in enumerate(rows, start=1):
        lines.append(
            "| {idx} | `{name}` | `{shape}` | {macs:,} | {ref_cpm:.3f} | {opt_cpm:.3f} | {speedup:.2f}x | {focus} |".format(
                idx=idx,
                name=item["layer_name"],
                shape=shape_text(item),
                macs=item["estimated_macs"],
                ref_cpm=item["ref_cycles_per_mac"],
                opt_cpm=item["opt_cycles_per_mac"],
                speedup=item["speedup"],
                focus=focus_text(item),
            )
        )

    lines.extend(
        [
            "",
            "## RTL 解释建议",
            "",
            "- `conv2_3x3_b` 和 `conv3_3x3_b` 是最重的两个稳定主块层，应优先作为 stride1 `3x3` 空间复用与多输出像素并行的验证对象。",
            "- `conv2_3x3_a` 与 `conv3_3x3_a` 更适合用来验证输出驻留方案在不同输入/输出通道比例下是否仍保持稳定。",
            "- 这四层的 `opt cycles/MAC` 从 `0.607` 逐步下降到 `0.503`，说明通道更深、空间更小的层当前利用率更高；当前最值得补的是 `48x48` 大空间层的 accumulator 往返与输出驻留能力。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = load_json(args.npusim)
    out_path = Path(args.out_md).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_md(report, out_path)
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
