"""Generate a Markdown RTL target report from hotspot summaries and case configs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hotspots", required=True, help="JSON from summarize_hardware_hotspots.py")
    parser.add_argument("--cases", required=True, help="JSON case config for NPUSim replay")
    parser.add_argument("--out_md", required=True, help="Output Markdown report")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def make_case_map(cases: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    result = {}
    for case in cases:
        source_index = case.get("source_op_index")
        if source_index is not None:
            result[int(source_index)] = case
    return result


def fmt_pct(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}%"


def fmt_x(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


def write_report(hotspots: dict[str, Any], cases_cfg: dict[str, Any], out_path: Path) -> None:
    cases = cases_cfg.get("cases", [])
    case_map = make_case_map(cases)
    top_layers = hotspots.get("top_hotspots_by_optimized_cycles", [])

    lines = [
        "# 正式主线热点层 RTL 目标表",
        "",
        f"- 模型：`{cases_cfg.get('model', 'unknown')}`",
        f"- 作用范围：`{cases_cfg.get('scope', 'unknown')}`",
        f"- 热点来源：`{hotspots.get('ops_profile', 'unknown')}`",
        f"- 模型级估算加速：`{hotspots.get('total_speedup', 0):.2f}x`",
        "",
        "## 建议优先级",
        "",
        "1. 先围绕 3 个最高占比的 `3x3` 主体层做单层 NPUSim 回放和路径确认。",
        "2. 再补 `conv2_3x3_a`、`conv3_3x3_a` 这两个中等占比层，确认不同通道比例下的趋势。",
        "3. 最后再用 `conv_head_1x1` 作为次级瓶颈样例，判断 pointwise 是否需要独立 RTL 线。",
        "",
        "## 热点层目标表",
        "",
        "| 优先级 | op index | case 名称 | 形状 | 当前路径预期 | MAC 占比 | 优化后周期占比 | 估算加速 | RTL 关注点 |",
        "| --- | ---: | --- | --- | --- | ---: | ---: | ---: | --- |",
    ]

    priority = 1
    for layer in top_layers:
        op_index = int(layer["index"])
        case = case_map.get(op_index)
        case_name = case["layer_name"] if case else f"op_{op_index}"
        expected_path = case.get("expected_current_path", "-") if case else "-"
        if layer["category"] == "conv2d_3x3":
            concern = "输出通道向量化、weight repack、feature map 复用"
        elif layer["category"] == "conv2d_1x1":
            concern = "pointwise 数据搬运、broadcast、低 MAC 利用率"
        else:
            concern = "待确认"
        lines.append(
            "| {priority} | {index} | `{case_name}` | `{shape}` | `{path}` | {mac_share} | {cycle_share} | {speedup} | {concern} |".format(
                priority=priority,
                index=op_index,
                case_name=case_name,
                shape=layer["shape_signature"],
                path=expected_path,
                mac_share=fmt_pct(layer.get("mac_share_pct")),
                cycle_share=fmt_pct(layer.get("optimized_cycle_share_pct")),
                speedup=fmt_x(layer.get("estimated_speedup")),
                concern=concern,
            )
        )
        priority += 1

    lines.extend(
        [
            "",
            "## 建议执行命令",
            "",
            "在 worktree 中运行正式主线热点层回放：",
            "",
            "```bash",
            "cd /home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv",
            "bazel --batch --output_base=/tmp/bazel-coralnpu-gesture-3x3-batch \\",
            "  run //tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d -- \\",
            "  --cases_json=/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_hotspots.json \\",
            "  --json_out=/home/steveguo/coralnpu-gesture/gesture_project/reports/static_cnn_i96_hotspots_npusim.json",
            "```",
            "",
            "## 当前判断",
            "",
            "- 如果 5 个 `3x3` 层都能稳定命中 `3x3_oc_vectorized`，下一阶段应优先优化其数据布局和访存。",
            "- 如果 `conv_head_1x1` 周期占比继续明显偏高，它可以作为第二阶段 `1x1 pointwise` RTL 的最小验证样例。",
            "- 如果正式 `96x96` 层的 cycles/MAC 与旧 `64x64` 基线趋势明显偏离，说明当前 rate 不能再只靠旧 microbenchmark 外推，必须用正式层 shape 更新估算口径。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    hotspots = load_json(args.hotspots)
    cases_cfg = load_json(args.cases)
    out_path = Path(args.out_md).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_report(hotspots, cases_cfg, out_path)
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
