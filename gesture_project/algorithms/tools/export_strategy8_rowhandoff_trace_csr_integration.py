"""导出 rowhandoff trace 模块与 CSR bank 的集成伪 RTL 与接线清单。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BOARD_CONTRACT_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_board_contract.json"
DEFAULT_CSR_MAP_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_board_csr_map.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--board_contract_json",
        default=str(DEFAULT_BOARD_CONTRACT_JSON),
        help="rowhandoff board contract JSON。",
    )
    parser.add_argument(
        "--csr_map_json",
        default=str(DEFAULT_CSR_MAP_JSON),
        help="rowhandoff CSR map JSON。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    parser.add_argument("--out_sv", required=True, help="输出伪 SystemVerilog 顶层。")
    return parser.parse_args()


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(board_contract: dict[str, Any], csr_map: dict[str, Any]) -> dict[str, Any]:
    wiring = [
        {
            "signal": "rowhandoff_hit_pulse",
            "source": "rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior",
            "target": "csr_bank.rowhandoff_hit_pulse",
            "note": "命中时打一拍到 CSR bank。",
        },
        {
            "signal": "rowhandoff_miss_pulse",
            "source": "!rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior",
            "target": "csr_bank.rowhandoff_miss_pulse",
            "note": "第一条生效 row 预期只 miss 一次。",
        },
        {
            "signal": "rowhandoff_invalidate_pulse",
            "source": "row_advance_done && rowhandoff_valid && (!row_gate_enable || !row_is_interior)",
            "target": "csr_bank.rowhandoff_invalidate_pulse",
            "note": "离开有效窗口或 interior 时打一拍。",
        },
        {
            "signal": "rowhandoff_produce_pulse",
            "source": "row_terminal_done && row_gate_enable && row_is_interior",
            "target": "csr_bank.rowhandoff_produce_pulse",
            "note": "right-edge 后 produce next-row base state。",
        },
        {
            "signal": "rowhandoff_tail_hit_pulse",
            "source": "rowhandoff_hit_pulse && (out_y_q >= 6'd24)",
            "target": "csr_bank.rowhandoff_tail_hit_pulse",
            "note": "默认把后段 bucket 设为 out_y>=24，可按后续实板再细化。",
        },
        {
            "signal": "interior_row_enter_pulse",
            "source": "row_gate_enable && row_is_interior && row_enter_event",
            "target": "csr_bank.interior_row_enter_pulse",
            "note": "需要控制器给出 row_enter_event 单拍。",
        },
        {
            "signal": "right_edge_done_pulse",
            "source": "row_terminal_done && row_gate_enable && row_is_interior",
            "target": "csr_bank.right_edge_done_pulse",
            "note": "与 produce_count 应保持一一对齐。",
        },
        {
            "signal": "rowhandoff_row_out_y_in",
            "source": "rowhandoff_trace.rowhandoff_row_out_y",
            "target": "csr_bank.rowhandoff_row_out_y_in",
            "note": "最后一次 produce 的 row 索引快照。",
        },
    ]

    return {
        "project_stage": board_contract["project_stage"],
        "csr_entries": csr_map["csr_entries"],
        "wiring": wiring,
        "board_targets": board_contract["layers"],
    }


def write_sv(report: dict[str, Any], out_sv: Path) -> None:
    lines = [
        "module conv2_3x3_b_rowhandoff_trace_with_csr (",
        "  input  logic        clk,",
        "  input  logic        rst_n,",
        "  input  logic        layer_start,",
        "  input  logic        row_advance_done,",
        "  input  logic        row_terminal_done,",
        "  input  logic        row_is_interior,",
        "  input  logic        row_gate_enable,",
        "  input  logic        row_enter_event,",
        "  input  logic [5:0]  out_y_q,",
        "  input  logic [31:0] next_row0_base_in,",
        "  input  logic [31:0] next_row1_base_in,",
        "  input  logic [31:0] next_row2_base_in,",
        "  input  logic        csr_read_en,",
        "  input  logic [15:0] csr_addr,",
        "  output logic [31:0] csr_rdata",
        ");",
        "",
        "  logic        rowhandoff_valid;",
        "  logic [5:0]  rowhandoff_row_out_y;",
        "  logic [31:0] rowhandoff_row0_base;",
        "  logic [31:0] rowhandoff_row1_base;",
        "  logic [31:0] rowhandoff_row2_base;",
        "  logic        rowhandoff_can_consume;",
        "  logic [31:0] rowhandoff_hit_count_unused;",
        "  logic [31:0] rowhandoff_miss_count_unused;",
        "  logic [31:0] rowhandoff_invalidate_count_unused;",
        "  logic [31:0] rowhandoff_produce_count_unused;",
        "",
        "  logic rowhandoff_hit_pulse;",
        "  logic rowhandoff_miss_pulse;",
        "  logic rowhandoff_invalidate_pulse;",
        "  logic rowhandoff_produce_pulse;",
        "  logic rowhandoff_tail_hit_pulse;",
        "  logic interior_row_enter_pulse;",
        "  logic right_edge_done_pulse;",
        "",
        "  assign rowhandoff_hit_pulse =",
        "      rowhandoff_can_consume && row_gate_enable && row_is_interior;",
        "  assign rowhandoff_miss_pulse =",
        "      !rowhandoff_can_consume && row_gate_enable && row_is_interior;",
        "  assign rowhandoff_invalidate_pulse =",
        "      row_advance_done && rowhandoff_valid && (!row_gate_enable || !row_is_interior);",
        "  assign rowhandoff_produce_pulse =",
        "      row_terminal_done && row_gate_enable && row_is_interior;",
        "  assign rowhandoff_tail_hit_pulse = rowhandoff_hit_pulse && (out_y_q >= 6'd24);",
        "  assign interior_row_enter_pulse = row_enter_event && row_gate_enable && row_is_interior;",
        "  assign right_edge_done_pulse = row_terminal_done && row_gate_enable && row_is_interior;",
        "",
        "  conv2_3x3_b_ctrl_4x8x8_rowhandoff_trace u_rowhandoff_trace (",
        "    .clk(clk),",
        "    .rst_n(rst_n),",
        "    .layer_start(layer_start),",
        "    .row_advance_done(row_advance_done),",
        "    .row_terminal_done(row_terminal_done),",
        "    .row_is_interior(row_is_interior),",
        "    .row_gate_enable(row_gate_enable),",
        "    .out_y_q(out_y_q),",
        "    .next_row0_base_in(next_row0_base_in),",
        "    .next_row1_base_in(next_row1_base_in),",
        "    .next_row2_base_in(next_row2_base_in),",
        "    .rowhandoff_valid(rowhandoff_valid),",
        "    .rowhandoff_row_out_y(rowhandoff_row_out_y),",
        "    .rowhandoff_row0_base(rowhandoff_row0_base),",
        "    .rowhandoff_row1_base(rowhandoff_row1_base),",
        "    .rowhandoff_row2_base(rowhandoff_row2_base),",
        "    .rowhandoff_can_consume(rowhandoff_can_consume),",
        "    .rowhandoff_hit_count(rowhandoff_hit_count_unused),",
        "    .rowhandoff_miss_count(rowhandoff_miss_count_unused),",
        "    .rowhandoff_invalidate_count(rowhandoff_invalidate_count_unused),",
        "    .rowhandoff_produce_count(rowhandoff_produce_count_unused)",
        "  );",
        "",
        "  rowhandoff_counter_csr_bank u_rowhandoff_csr_bank (",
        "    .clk(clk),",
        "    .rst_n(rst_n),",
        "    .csr_read_en(csr_read_en),",
        "    .csr_addr(csr_addr),",
        "    .csr_rdata(csr_rdata),",
        "    .rowhandoff_valid_in(rowhandoff_valid),",
        "    .rowhandoff_row_out_y_in(rowhandoff_row_out_y),",
        "    .rowhandoff_hit_pulse(rowhandoff_hit_pulse),",
        "    .rowhandoff_tail_hit_pulse(rowhandoff_tail_hit_pulse),",
        "    .rowhandoff_miss_pulse(rowhandoff_miss_pulse),",
        "    .rowhandoff_invalidate_pulse(rowhandoff_invalidate_pulse),",
        "    .rowhandoff_produce_pulse(rowhandoff_produce_pulse),",
        "    .interior_row_enter_pulse(interior_row_enter_pulse),",
        "    .right_edge_done_pulse(right_edge_done_pulse)",
        "  );",
        "",
        "endmodule",
        "",
    ]

    out_sv.write_text("\n".join(lines), encoding="utf-8")


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff trace + CSR 集成接线清单",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        "- 目标：把 `rowhandoff_trace` 与 `rowhandoff_counter_csr_bank` 从两份独立伪骨架推进成一份可直接抄线的集成清单。",
        "",
        "## 接线表",
        "",
        "| 信号 | 来源 | 去向 | 说明 |",
        "| --- | --- | --- | --- |",
    ]

    for item in report["wiring"]:
        lines.append(
            "| `{signal}` | `{source}` | `{target}` | {note} |".format(
                signal=item["signal"],
                source=item["source"],
                target=item["target"],
                note=item["note"],
            )
        )

    lines.extend(
        [
            "",
            "## 当前板级目标层",
            "",
            "| 层 | 优先级 | handshake 对照 | 说明 |",
            "| --- | ---: | --- | --- |",
        ]
    )

    for item in report["board_targets"]:
        handshake = (
            f"`{item['handshake_reload_cycles']} -> {item['handshake_row_resident_cycles']}`"
            if item["handshake_reload_cycles"] is not None
            else "`待补`"
        )
        lines.append(
            "| `{layer}` | {prio} | {handshake} | {gate} |".format(
                layer=item["layer_name"],
                prio=item["board_run_priority"],
                handshake=handshake,
                gate=item["gate_assumption"],
            )
        )

    lines.extend(
        [
            "",
            "## 当前最小集成结论",
            "",
            "- `rowhandoff_trace` 负责状态与 next-row base 递推语义。",
            "- `rowhandoff_counter_csr_bank` 负责把命中/失效/produce/tail-hit 变成板级可读寄存器。",
            "- 两者之间最关键的新桥梁并不是数据路径，而是 `row_enter_event / row_terminal_done / out_y_q` 这组三类控制脉冲与快照。",
            "- 因此下一步 RTL 接入应优先补这些控制脉冲，再谈是否让 row-base 选择真正受影响。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    board_contract = load_json(args.board_contract_json)
    csr_map = load_json(args.csr_map_json)
    report = build_report(board_contract, csr_map)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, out_md)

    out_sv = Path(args.out_sv).resolve()
    out_sv.parent.mkdir(parents=True, exist_ok=True)
    write_sv(report, out_sv)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")
    print(f"Wrote {out_sv}")


if __name__ == "__main__":
    main()
