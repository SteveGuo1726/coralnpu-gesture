"""导出 rowhandoff 最小 sideband 脉冲 patch 草案。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE_ANCHOR_JSON = (
    PROJECT_ROOT
    / "reports"
    / "core_3x3_strategy8_rowhandoff_source_event_anchor_map_2026-06-11.json"
)
DEFAULT_TRACE_CSR_JSON = (
    PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_trace_csr_integration.json"
)
DEFAULT_PATCH_PLAN_JSON = (
    PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_corecsr_patch_plan.json"
)
DEFAULT_BOARD_CONTRACT_JSON = (
    PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_board_contract.json"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source_anchor_json",
        default=str(DEFAULT_SOURCE_ANCHOR_JSON),
        help="源码事件锚点 JSON。",
    )
    parser.add_argument(
        "--trace_csr_json",
        default=str(DEFAULT_TRACE_CSR_JSON),
        help="trace + CSR 集成 JSON。",
    )
    parser.add_argument(
        "--patch_plan_json",
        default=str(DEFAULT_PATCH_PLAN_JSON),
        help="CoreCSR patch 计划 JSON。",
    )
    parser.add_argument(
        "--board_contract_json",
        default=str(DEFAULT_BOARD_CONTRACT_JSON),
        help="board contract JSON。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(
    source_anchor: dict[str, Any],
    trace_csr: dict[str, Any],
    patch_plan: dict[str, Any],
    board_contract: dict[str, Any],
) -> dict[str, Any]:
    anchors = source_anchor["anchors"]
    required_top = patch_plan["required_top_signals"]
    wiring = {item["signal"]: item for item in trace_csr["wiring"]}

    minimal_inputs = [
        {
            "rtl_signal": "row_enter_event",
            "source_candidate": {
                "gate_line": anchors["gate_enable_expr"],
                "event_line": anchors["interior_row_enter_macro"],
            },
            "drives": ["interior_row_enter_pulse"],
            "maps_to_counters": ["interior_row_enter_count"],
            "note": "当前最接近“该 row 被 gate 接纳并进入 interior 主体”的单拍。",
        },
        {
            "rtl_signal": "row_terminal_done",
            "source_candidate": {
                "call_line": anchors["right_edge_call"],
                "event_line": anchors["right_edge_done_macro"],
            },
            "drives": ["right_edge_done_pulse", "rowhandoff_produce_pulse"],
            "maps_to_counters": ["right_edge_done_count", "rowhandoff_produce_count"],
            "note": "当前最接近“right-edge 完成后 row terminal 收口”的单拍。",
        },
        {
            "rtl_signal": "out_y_q",
            "source_candidate": {
                "payload_line": source_anchor["rtl_candidates"][2]["line_payload"],
                "produce_line": anchors["produce_macro"],
            },
            "drives": ["rowhandoff_row_out_y_in", "rowhandoff_tail_hit_pulse"],
            "maps_to_counters": ["rowhandoff_row_out_y_last", "rowhandoff_tail_hit_count"],
            "note": "第一版不追求内部命名一致，只要关键拍上能稳定提供当前 row 索引快照即可。",
        },
    ]

    derived_signals = [
        {
            "signal": "rowhandoff_hit_pulse",
            "formula": wiring["rowhandoff_hit_pulse"]["source"],
            "depends_on": ["rowhandoff_can_consume", "row_gate_enable", "row_is_interior"],
        },
        {
            "signal": "rowhandoff_miss_pulse",
            "formula": wiring["rowhandoff_miss_pulse"]["source"],
            "depends_on": ["rowhandoff_can_consume", "row_gate_enable", "row_is_interior"],
        },
        {
            "signal": "rowhandoff_invalidate_pulse",
            "formula": wiring["rowhandoff_invalidate_pulse"]["source"],
            "depends_on": ["row_advance_done", "rowhandoff_valid", "row_gate_enable", "row_is_interior"],
        },
        {
            "signal": "rowhandoff_tail_hit_pulse",
            "formula": wiring["rowhandoff_tail_hit_pulse"]["source"],
            "depends_on": ["rowhandoff_hit_pulse", "out_y_q"],
        },
    ]

    return {
        "project_stage": "strategy8 rowhandoff minimal sideband pulse patch draft",
        "board_target": board_contract["layers"][0]["layer_name"],
        "required_top_signals": required_top,
        "minimal_new_inputs": minimal_inputs,
        "derived_signals": derived_signals,
        "source_event_order": source_anchor["ordered_events"],
        "expected_mode1_full": {
            "hit": 45,
            "miss": 1,
            "invalidate": 1,
            "produce": 46,
            "tail_hit": 21,
            "interior_row_enter": 46,
            "right_edge_done": 46,
            "row_out_y_last": 46,
        },
        "expected_backhalf": {
            "hit": 21,
            "miss": 1,
            "invalidate": 1,
            "produce": 22,
            "tail_hit": 21,
            "interior_row_enter": 22,
            "right_edge_done": 22,
            "row_out_y_last": 45,
        },
        "next_step": (
            "先在真实控制路径中接出 row_enter_event / row_terminal_done / out_y_q，"
            "再用现有 CounterBank/CSR 链做 trace-only 对账，不直接改 datapath 生效。"
        ),
    }


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff 最小 sideband 脉冲 patch 草案",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        f"- 第一目标层：`{report['board_target']}`",
        "- 目标：把“源码事件锚点 -> CoreAxi/CoreAxiCSR/CounterBank 输入”收口成一张可直接照着接的最小草案。",
        "",
        "## 最小新增输入",
        "",
        "| RTL 输入 | 源码锚点 | 驱动信号 | 对应计数 | 说明 |",
        "| --- | --- | --- | --- | --- |",
    ]

    for item in report["minimal_new_inputs"]:
        anchor_desc = ", ".join(f"{k}={v}" for k, v in item["source_candidate"].items())
        lines.append(
            "| `{rtl}` | `{anchor}` | `{drives}` | `{counters}` | {note} |".format(
                rtl=item["rtl_signal"],
                anchor=anchor_desc,
                drives=", ".join(item["drives"]),
                counters=", ".join(item["maps_to_counters"]),
                note=item["note"],
            )
        )

    lines.extend(
        [
            "",
            "## 可直接派生的 sideband 脉冲",
            "",
            "| 信号 | 公式 | 依赖 |",
            "| --- | --- | --- |",
        ]
    )

    for item in report["derived_signals"]:
        lines.append(
            "| `{signal}` | `{formula}` | `{depends}` |".format(
                signal=item["signal"],
                formula=item["formula"],
                depends=", ".join(item["depends_on"]),
            )
        )

    lines.extend(
        [
            "",
            "## 预期对账值",
            "",
            "### mode1_full",
            "",
        ]
    )

    for key, value in report["expected_mode1_full"].items():
        lines.append(f"- `{key} = {value}`")

    lines.extend(
        [
            "",
            "### backhalf",
            "",
        ]
    )

    for key, value in report["expected_backhalf"].items():
        lines.append(f"- `{key} = {value}`")

    lines.extend(
        [
            "",
            "## 当前顺序",
            "",
            "- " + "\n- ".join(report["source_event_order"]),
            "",
            "## 下一步",
            "",
            f"- {report['next_step']}",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        load_json(args.source_anchor_json),
        load_json(args.trace_csr_json),
        load_json(args.patch_plan_json),
        load_json(args.board_contract_json),
    )
    Path(args.out_json).write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(report, Path(args.out_md))


if __name__ == "__main__":
    main()
