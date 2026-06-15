"""导出 rowhandoff sideband CSR 接入到官方 CoreCSR/CoreAxi 的伪 patch 与验证模板。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CSR_MAP_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_board_csr_map.json"
DEFAULT_INTEGRATION_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_trace_csr_integration.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--csr_map_json",
        default=str(DEFAULT_CSR_MAP_JSON),
        help="rowhandoff CSR 地址表 JSON。",
    )
    parser.add_argument(
        "--integration_json",
        default=str(DEFAULT_INTEGRATION_JSON),
        help="trace + CSR 集成 JSON。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    parser.add_argument("--out_scala", required=True, help="输出 Scala 伪 patch。")
    parser.add_argument("--out_cocotb", required=True, help="输出 cocotb 测试模板。")
    return parser.parse_args()


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(csr_map: dict[str, Any], integration: dict[str, Any]) -> dict[str, Any]:
    return {
        "project_stage": integration["project_stage"],
        "csr_entries": csr_map["csr_entries"],
        "required_top_signals": [
            "row_enter_event",
            "row_terminal_done",
            "row_is_interior",
            "row_gate_enable",
            "row_advance_done",
            "out_y_q",
            "rowhandoff_valid",
            "rowhandoff_row_out_y",
            "rowhandoff_can_consume",
        ],
        "corecsr_extension_strategy": {
            "style": "sideband_read_only_regs",
            "why": [
                "不改 scalar csr.out 的 9 个正式输出槽位",
                "直接沿用 CoreCSR 的 allReadRegs/groupedRegs/readDataValid 读图结构",
                "只加读寄存器，不加写寄存器，第一阶段风险最低",
            ],
        },
        "cocotb_checks": [
            {
                "name": "valid_rowhandoff_csrs",
                "addrs": [entry["addr"] for entry in csr_map["csr_entries"]],
                "expected_resp": "OKAY",
            },
            {
                "name": "neighbor_invalid_probe",
                "addrs": [0x081c, 0x0840],
                "expected_resp": "SLVERR",
            },
        ],
    }


def write_scala(report: dict[str, Any], out_scala: Path) -> None:
    lines = [
        "// rowhandoff sideband CSR pseudo patch for CoreAxiCSR.scala",
        "// 目标：沿用官方 CoreCSR 的 allReadRegs/groupedRegs 结构，",
        "// 增加一组只读 board trace/counter CSR，不修改 scalar csr.out。",
        "",
        "package coralnpu",
        "",
        "import chisel3._",
        "import chisel3.util._",
        "",
        "class RowhandoffCsrIO extends Bundle {",
    ]
    for entry in report["csr_entries"]:
        width = entry["width_bits"]
        lines.append(f"  val {entry['name']} = Input(UInt({width}.W))")
    lines.extend(
        [
            "}",
            "",
            "object RowhandoffCsrAddrs {",
        ]
    )
    for entry in report["csr_entries"]:
        lines.append(f"  val {entry['name']} = 0x{entry['addr']:03x}.U")
    lines.extend(
        [
            "}",
            "",
            "// In CoreCSR IO bundle, add:",
            "// val rowhandoff = Input(new RowhandoffCsrIO)",
            "",
            "// In CoreCSR read map section, add:",
            "val rowhandoffReadMap = Seq(",
        ]
    )
    for idx, entry in enumerate(report["csr_entries"]):
        comma = "," if idx != len(report["csr_entries"]) - 1 else ""
        lines.append(
            f"  RowhandoffCsrAddrs.{entry['name']} -> io.rowhandoff.{entry['name']}{comma}"
        )
    lines.extend(
        [
            ").map { case (k, v) => k.litValue.toInt -> v }.toMap",
            "",
            "// Then replace:",
            "// val allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap",
            "// with:",
            "// val allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap ++ rowhandoffReadMap",
            "",
            "// Write map intentionally unchanged in trace-only first stage:",
            "// val allWriteRegs = Map(0x0 -> true.B, 0x4 -> true.B) ++ debugWriteValidMap",
            "",
            "// In CoreAxiCSR IO bundle, add:",
            "// val rowhandoff = Input(new RowhandoffCsrIO)",
            "",
            "// In CoreAxiCSR module body, add:",
            "// csr.io.rowhandoff := io.rowhandoff",
            "",
            "// In CoreAxi top-level, connect these from the future rowhandoff counter bank.",
        ]
    )
    out_scala.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_cocotb(report: dict[str, Any], out_cocotb: Path) -> None:
    valid_addrs = [entry["addr"] for entry in report["csr_entries"]]
    lines = [
        "# Copyright 2026",
        "# rowhandoff CoreAxiCSR readback template",
        "",
        "import cocotb",
        "import numpy as np",
        "",
        "from coralnpu_test_utils.core_mini_axi_interface import AxiResp, CoreMiniAxiInterface",
        "",
        "",
        "@cocotb.test()",
        "async def core_mini_axi_rowhandoff_csr_template(dut):",
        "    core_mini_axi = CoreMiniAxiInterface(dut)",
        "    await core_mini_axi.init()",
        "    await core_mini_axi.reset()",
        "    cocotb.start_soon(core_mini_axi.clock.start())",
        "",
        "    # 这里默认 DUT 已经把 rowhandoff counter bank 接到 CoreAxiCSR。",
        "    # 第一阶段不要求真实运行 full program，先确认 CSR decode 可读。",
        "",
        "    valid_addrs = [",
    ]
    for addr in valid_addrs:
        lines.append(f"        0x30000 + 0x{addr:03x},")
    lines.extend(
        [
            "    ]",
            "    for addr in valid_addrs:",
            "        _ = await core_mini_axi.read_word(addr)",
            "",
            "    # 邻居探针：左边一个非法地址，右边一个非法地址。",
            "    await core_mini_axi.read_word(0x30000 + 0x081c, expected_resp=AxiResp.SLVERR)",
            "    await core_mini_axi.read_word(0x30000 + 0x0840, expected_resp=AxiResp.SLVERR)",
            "",
            "    # 如果后续接入 trace-only mode1_full，可把这里改成固定值断言：",
            "    # hit = await core_mini_axi.read_word(0x30820)",
            "    # assert hit.view(np.uint32)[0] == 45",
        ]
    )
    out_cocotb.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff CoreCSR 官方接入骨架",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        "- 目标：把 `CoreCSR/CoreAxiCSR` 侧最小改动收敛成可以直接照着填的骨架。",
        "",
        "## 设计结论",
        "",
        "- 第一阶段应走 `sideband_read_only_regs`，不改 scalar `csr.out` 的 9 个正式槽位。",
        "- 直接复用官方 `CoreCSR` 里的 `allReadRegs -> groupedRegs -> readDataValid` 读图结构即可。",
        "- 第一阶段不增加 rowhandoff 写寄存器，`allWriteRegs` 保持只含 `reset/pc/debug`。",
        "",
        "## CoreCSR 需要增加的 IO",
        "",
        "| 名称 | 位宽 | 地址偏移 | 用途 |",
        "| --- | ---: | --- | --- |",
    ]
    for entry in report["csr_entries"]:
        lines.append(
            "| `{name}` | {width} | `{addr}` | {why} |".format(
                name=entry["name"],
                width=entry["width_bits"],
                addr=entry["addr_hex"],
                why=entry["why"],
            )
        )
    lines.extend(
        [
            "",
            "## 顶层最少必拉的控制/状态信号",
            "",
        ]
    )
    for signal in report["required_top_signals"]:
        lines.append(f"- `{signal}`")
    lines.extend(
        [
            "",
            "## cocotb 第一阶段检查",
            "",
            "- 所有 `0x30820~0x3083c` 有效 CSR 应读成功。",
            "- `0x3081c` 与 `0x30840` 这两个邻居探针应返回 `SLVERR`。",
            "- 如果后续已经接入 trace-only `mode1_full`，再追加固定值断言 `45/1/1/46/21/46/46/46`。",
        ]
    )
    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    csr_map = load_json(args.csr_map_json)
    integration = load_json(args.integration_json)
    report = build_report(csr_map, integration)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, out_md)

    out_scala = Path(args.out_scala).resolve()
    out_scala.parent.mkdir(parents=True, exist_ok=True)
    write_scala(report, out_scala)

    out_cocotb = Path(args.out_cocotb).resolve()
    out_cocotb.parent.mkdir(parents=True, exist_ok=True)
    write_cocotb(report, out_cocotb)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")
    print(f"Wrote {out_scala}")
    print(f"Wrote {out_cocotb}")


if __name__ == "__main__":
    main()
