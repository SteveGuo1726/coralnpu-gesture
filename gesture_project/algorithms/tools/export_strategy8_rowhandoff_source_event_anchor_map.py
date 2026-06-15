"""导出 conv.cc 中 rowhandoff 源码事件锚点图。"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONV_CC = (
    PROJECT_ROOT
    / "worktrees"
    / "coralnpu-3x3-conv"
    / "sw"
    / "opt"
    / "litert-micro"
    / "conv.cc"
)


EVENT_BIT_PATTERNS = [
    ("layer_start", r"constexpr uint32_t kRowhandoffEventLayerStartBit = \(1u << (\d+)\);"),
    ("hit", r"constexpr uint32_t kRowhandoffEventHitBit = \(1u << (\d+)\);"),
    ("tail_hit", r"constexpr uint32_t kRowhandoffEventTailHitBit = \(1u << (\d+)\);"),
    ("miss", r"constexpr uint32_t kRowhandoffEventMissBit = \(1u << (\d+)\);"),
    ("invalidate", r"constexpr uint32_t kRowhandoffEventInvalidateBit = \(1u << (\d+)\);"),
    ("produce", r"constexpr uint32_t kRowhandoffEventProduceBit = \(1u << (\d+)\);"),
    ("interior_row_enter", r"constexpr uint32_t kRowhandoffEventInteriorRowEnterBit = \(1u << (\d+)\);"),
    ("right_edge_done", r"constexpr uint32_t kRowhandoffEventRightEdgeDoneBit = \(1u << (\d+)\);"),
    ("row_out_y_write", r"constexpr uint32_t kRowhandoffEventRowOutYWriteBit = \(1u << (\d+)\);"),
]


ANCHOR_PATTERNS = [
    ("layer_start_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_LAYER_START();"),
    ("gate_enable_expr", "const bool enable_rowhandoff_rowbase_for_this_row ="),
    ("interior_row_enter_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_INTERIOR_ROW_ENTER(out_y);"),
    ("reuse_try_begin", "if (enable_rowhandoff_rowbase_for_this_row) {"),
    ("hit_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_HIT(out_y);"),
    ("tail_hit_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_TAIL_HIT(out_y);"),
    ("miss_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_MISS(out_y);"),
    ("right_edge_call", "run_right_edge_point("),
    ("right_edge_done_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_RIGHT_EDGE_DONE(out_y);"),
    ("produce_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_PRODUCE(out_y);"),
    ("invalidate_non_gate_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_INVALIDATE(out_y);"),
    ("final_invalidate_macro", "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_INVALIDATE(output_height);"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--conv_cc",
        default=str(DEFAULT_CONV_CC),
        help="待分析的 conv.cc 路径。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_lines(path: str | Path) -> list[str]:
    return Path(path).read_text(encoding="utf-8").splitlines()


def find_line(lines: list[str], needle: str, start: int = 0) -> int:
    for idx in range(start, len(lines)):
        if needle in lines[idx]:
            return idx + 1
    raise ValueError(f"Needle not found: {needle}")


def extract_event_bits(text: str) -> list[dict[str, Any]]:
    bits: list[dict[str, Any]] = []
    for name, pattern in EVENT_BIT_PATTERNS:
        match = re.search(pattern, text)
        if not match:
            raise ValueError(f"Event bit pattern not found: {name}")
        bits.append(
            {
                "name": name,
                "bit": int(match.group(1)),
            }
        )
    return bits


def build_anchor_map(lines: list[str]) -> dict[str, int]:
    anchors: dict[str, int] = {}
    search_from = 0
    for name, needle in ANCHOR_PATTERNS:
        line_no = find_line(lines, needle, start=search_from)
        anchors[name] = line_no
        if name == "gate_enable_expr":
            search_from = line_no - 1
    return anchors


def build_report(conv_cc: Path) -> dict[str, Any]:
    lines = load_lines(conv_cc)
    text = "\n".join(lines)
    event_bits = extract_event_bits(text)
    anchors = build_anchor_map(lines)

    return {
        "project_stage": "strategy8 rowhandoff source-event anchor extraction",
        "conv_cc": str(conv_cc.relative_to(PROJECT_ROOT.parent)),
        "event_csr_addr_macro": "STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_CSR_ADDR",
        "event_payload_row_bits": "[21:16]",
        "event_bits": event_bits,
        "anchors": anchors,
        "rtl_candidates": [
            {
                "name": "row_enter_event",
                "line_gate": anchors["gate_enable_expr"],
                "line_event": anchors["interior_row_enter_macro"],
                "reason": "最接近“该 row 被 gate 接纳并开始进入 interior 主体计算”的单拍。",
            },
            {
                "name": "row_terminal_done",
                "line_call": anchors["right_edge_call"],
                "line_event": anchors["right_edge_done_macro"],
                "reason": "最接近“right-edge 完成后，当前 row terminal 收口”的单拍。",
            },
            {
                "name": "row_index_snapshot",
                "line_event": anchors["produce_macro"],
                "line_payload": 319,
                "reason": "当前 software bridge 用 out_y 直接编码进 payload[21:16]，可作为 out_y_q 的第一版代理。",
            },
        ],
        "ordered_events": [
            "layer_start",
            "interior_row_enter",
            "hit/miss",
            "tail_hit",
            "right_edge_done",
            "produce",
            "invalidate",
        ],
    }


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff 源码事件锚点自动导出",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        f"- 目标源码：`{report['conv_cc']}`",
        f"- 事件地址宏：`{report['event_csr_addr_macro']}`",
        f"- `out_y` 负载位：`{report['event_payload_row_bits']}`",
        "",
        "## 事件位",
        "",
        "| 名称 | bit |",
        "| --- | ---: |",
    ]
    for item in report["event_bits"]:
        lines.append(f"| `{item['name']}` | {item['bit']} |")

    lines.extend(
        [
            "",
            "## 关键锚点",
            "",
            "| 名称 | 行号 |",
            "| --- | ---: |",
        ]
    )
    for name, line_no in report["anchors"].items():
        lines.append(f"| `{name}` | {line_no} |")

    lines.extend(
        [
            "",
            "## RTL 候选锚点",
            "",
            "| 名称 | 关键行 | 说明 |",
            "| --- | ---: | --- |",
        ]
    )
    for item in report["rtl_candidates"]:
        if "line_event" in item:
            key_line = item["line_event"]
        else:
            key_line = item["line_payload"]
        lines.append(f"| `{item['name']}` | {key_line} | {item['reason']} |")

    lines.extend(
        [
            "",
            "## 当前顺序",
            "",
            "- " + "\n- ".join(report["ordered_events"]),
            "",
            "## 当前结论",
            "",
            "- `row_enter_event` 最接近 `enable_rowhandoff_rowbase_for_this_row` 成立后立即打出的 `INTERIOR_ROW_ENTER(out_y)`。",
            "- `row_terminal_done` 最接近 `run_right_edge_point(...)` 完成后立即打出的 `RIGHT_EDGE_DONE(out_y)`。",
            "- `row_index_snapshot` 当前第一版可直接沿 software bridge 的 `payload[21:16]` 代理 `out_y_q`。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(Path(args.conv_cc))
    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(report, out_md)


if __name__ == "__main__":
    main()
