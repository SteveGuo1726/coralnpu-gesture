"""导出 rowhandoff 板级 counter/CSR 的地址表与伪 RTL 骨架。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTRACT_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_board_contract.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--board_contract_json",
        default=str(DEFAULT_CONTRACT_JSON),
        help="rowhandoff 板级 contract JSON。",
    )
    parser.add_argument(
        "--base_addr",
        type=lambda value: int(value, 0),
        default=0x820,
        help="CSR 基地址。默认避开官方 debug CSR 的 0x0800~0x0814 段。",
    )
    parser.add_argument("--stride_bytes", type=lambda value: int(value, 0), default=0x4, help="每项地址步进。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    parser.add_argument("--out_sv", required=True, help="输出伪 SystemVerilog 骨架。")
    return parser.parse_args()


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(contract: dict[str, Any], base_addr: int, stride_bytes: int) -> dict[str, Any]:
    csr_entries = []
    for index, entry in enumerate(contract["counter_contract"]):
        addr = base_addr + index * stride_bytes
        csr_entries.append(
            {
                "index": index,
                "name": entry["name"],
                "type": entry["type"],
                "width_bits": entry["width_bits"],
                "addr": addr,
                "addr_hex": f"0x{addr:04x}",
                "expected_mode1_full": entry["expected_mode1_full"],
                "expected_mode1_backhalf": entry["expected_mode1_backhalf"],
                "description": entry["description"],
                "why": entry["why"],
            }
        )

    return {
        "project_stage": contract["project_stage"],
        "base_addr": base_addr,
        "stride_bytes": stride_bytes,
        "csr_entries": csr_entries,
    }


def sv_type(width_bits: int) -> str:
    if width_bits <= 1:
        return "logic"
    return f"logic [{width_bits - 1}:0]"


def write_sv(report: dict[str, Any], out_sv: Path) -> None:
    lines = [
        "module rowhandoff_counter_csr_bank (",
        "  input  logic        clk,",
        "  input  logic        rst_n,",
        "  input  logic        csr_read_en,",
        "  input  logic [15:0] csr_addr,",
        "  output logic [31:0] csr_rdata,",
        "  input  logic        rowhandoff_valid_in,",
        "  input  logic [5:0]  rowhandoff_row_out_y_in,",
        "  input  logic        rowhandoff_hit_pulse,",
        "  input  logic        rowhandoff_tail_hit_pulse,",
        "  input  logic        rowhandoff_miss_pulse,",
        "  input  logic        rowhandoff_invalidate_pulse,",
        "  input  logic        rowhandoff_produce_pulse,",
        "  input  logic        interior_row_enter_pulse,",
        "  input  logic        right_edge_done_pulse",
        ");",
        "",
    ]

    for entry in report["csr_entries"]:
        lines.append(f"  {sv_type(entry['width_bits'])} {entry['name']}_q;")

    lines.extend(
        [
            "",
            "  always_ff @(posedge clk or negedge rst_n) begin",
            "    if (!rst_n) begin",
        ]
    )

    for entry in report["csr_entries"]:
        lines.append(f"      {entry['name']}_q <= '0;")

    lines.extend(
        [
            "    end else begin",
            "      if (rowhandoff_hit_pulse) rowhandoff_hit_count_q <= rowhandoff_hit_count_q + 1'b1;",
            "      if (rowhandoff_tail_hit_pulse) rowhandoff_tail_hit_count_q <= rowhandoff_tail_hit_count_q + 1'b1;",
            "      if (rowhandoff_miss_pulse) rowhandoff_miss_count_q <= rowhandoff_miss_count_q + 1'b1;",
            "      if (rowhandoff_invalidate_pulse) rowhandoff_invalidate_count_q <= rowhandoff_invalidate_count_q + 1'b1;",
            "      if (rowhandoff_produce_pulse) rowhandoff_produce_count_q <= rowhandoff_produce_count_q + 1'b1;",
            "      if (interior_row_enter_pulse) interior_row_enter_count_q <= interior_row_enter_count_q + 1'b1;",
            "      if (right_edge_done_pulse) right_edge_done_count_q <= right_edge_done_count_q + 1'b1;",
            "      rowhandoff_row_out_y_last_q <= rowhandoff_row_out_y_in;",
            "    end",
            "  end",
            "",
            "  always_comb begin",
            "    csr_rdata = 32'h0;",
            "    if (csr_read_en) begin",
            "      unique case (csr_addr)",
        ]
    )

    for entry in report["csr_entries"]:
        lines.append(
            f"        16'h{entry['addr']:04x}: csr_rdata = {{"
            f"{32 - entry['width_bits']}'h0, {entry['name']}_q}};"
        )

    lines.extend(
        [
            "        default: csr_rdata = 32'h0;",
            "      endcase",
            "    end",
            "  end",
            "",
            "endmodule",
            "",
        ]
    )

    out_sv.write_text("\n".join(lines), encoding="utf-8")


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff 板级 CSR 地址表",
        "",
        f"- 基地址：`0x{report['base_addr']:04x}`",
        f"- 步进：`0x{report['stride_bytes']:x}`",
        "- 目标：把 board contract 里的 counter/snapshot 直接映射成可抄写的 CSR 地址表。",
        "",
        "| 索引 | 名称 | 地址 | 类型 | 位宽 | mode1_full | backhalf | 说明 |",
        "| ---: | --- | --- | --- | ---: | ---: | ---: | --- |",
    ]

    for entry in report["csr_entries"]:
        lines.append(
            "| {index} | `{name}` | `{addr}` | `{kind}` | {width} | {full} | {backhalf} | {why} |".format(
                index=entry["index"],
                name=entry["name"],
                addr=entry["addr_hex"],
                kind=entry["type"],
                width=entry["width_bits"],
                full=entry["expected_mode1_full"],
                backhalf=entry["expected_mode1_backhalf"],
                why=entry["why"],
            )
        )

    lines.extend(
        [
            "",
            "## 使用建议",
            "",
            "- `rowhandoff_hit_count` / `miss_count` / `invalidate_count` / `produce_count` 构成第一版最小守恒组。",
            "- `rowhandoff_tail_hit_count` 建议和总 `hit_count` 同时读，用于区分收益是否真的落在后段 row bucket。",
            "- `rowhandoff_row_out_y_last` 不必做计数，只需做最后快照即可。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    contract = load_json(args.board_contract_json)
    report = build_report(contract, args.base_addr, args.stride_bytes)

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
