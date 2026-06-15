"""Export machine-readable FSM spec for conv2_3x3_b 4x8x8 controller."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="Input tile schedule JSON.")
    parser.add_argument("--fsm_table_json", required=True, help="Input FSM table JSON.")
    parser.add_argument("--out_json", required=True, help="Output machine-readable FSM spec.")
    parser.add_argument("--out_md", required=True, help="Output Markdown summary.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_spec(schedule: dict[str, Any], fsm_table: dict[str, Any]) -> dict[str, Any]:
    signal_defs = [
        {
            "name": "line_fill_req",
            "role": "请求首 tile line fill 或新 tile-row 初始化",
            "asserted_by": ["S2_FILL_FIRST_TILE"],
        },
        {
            "name": "window_shift_req",
            "role": "请求横向 window shift",
            "asserted_by": ["S7_WINDOW_SHIFT"],
        },
        {
            "name": "row_advance_req",
            "role": "请求纵向换行并补 4 行输入",
            "asserted_by": ["S8_ADVANCE_ROW"],
        },
        {
            "name": "weight_preload_req",
            "role": "请求同一 tile-row 的整行 weight preload",
            "asserted_by": ["S1_PRELOAD_WEIGHTS"],
        },
        {
            "name": "weight_group_load_req",
            "role": "请求当前 oc_group 的 weight tile 有效",
            "asserted_by": ["S3_LOAD_WEIGHT_GROUP"],
        },
        {
            "name": "compute_req",
            "role": "启动当前 oc_group 的 accumulator 计算",
            "asserted_by": ["S4_COMPUTE_ACC"],
        },
        {
            "name": "quant_write_req",
            "role": "启动当前 tile 的量化写回",
            "asserted_by": ["S5_QUANTIZE_WRITEBACK"],
        },
        {
            "name": "done_pulse",
            "role": "当前 layer 完成脉冲",
            "asserted_by": ["S9_DONE"],
        },
    ]

    state_entries = []
    for state in fsm_table["states"]:
        asserted = [signal["name"] for signal in signal_defs if state["state"] in signal["asserted_by"]]
        state_entries.append(
            {
                "state": state["state"],
                "role": state["role"],
                "enter_when": state["enter_when"],
                "asserted_signals": asserted,
                "next_default": state["next_default"],
            }
        )

    counters = [
        {
            "name": "out_y_tile",
            "range": [0, int(schedule["grid"]["tiles_y"]) - 1],
            "updated_in": ["S8_ADVANCE_ROW"],
        },
        {
            "name": "out_x_tile",
            "range": [0, int(schedule["grid"]["tiles_x"]) - 1],
            "updated_in": ["S6_NEXT_OC_OR_SHIFT", "S7_WINDOW_SHIFT"],
        },
        {
            "name": "oc_group",
            "range": [0, int(schedule["grid"]["tiles_oc"]) - 1],
            "updated_in": ["S5_QUANTIZE_WRITEBACK", "S6_NEXT_OC_OR_SHIFT"],
        },
    ]

    return {
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "config": schedule["config"],
        "grid": schedule["grid"],
        "signals": signal_defs,
        "counters": counters,
        "states": state_entries,
    }


def write_markdown(spec: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 Machine-readable FSM Spec",
        "",
        "- 目标：给当前最小控制器原型补一份更接近接口定义的机器可读规格。",
        "",
        "## 控制信号",
        "",
        "| 信号 | 作用 | 由哪些状态拉起 |",
        "| --- | --- | --- |",
    ]

    for signal in spec["signals"]:
        lines.append(
            "| `{name}` | {role} | {states} |".format(
                name=signal["name"],
                role=signal["role"],
                states=", ".join(f"`{state}`" for state in signal["asserted_by"]),
            )
        )

    lines.extend(
        [
            "",
            "## 计数器",
            "",
            "| 计数器 | 范围 | 主要更新状态 |",
            "| --- | --- | --- |",
        ]
    )

    for counter in spec["counters"]:
        lines.append(
            "| `{name}` | `{lo}..{hi}` | {states} |".format(
                name=counter["name"],
                lo=counter["range"][0],
                hi=counter["range"][1],
                states=", ".join(f"`{state}`" for state in counter["updated_in"]),
            )
        )

    lines.extend(
        [
            "",
            "## 状态映射",
            "",
            "| 状态 | 作用 | 拉起信号 | 默认下一状态 |",
            "| --- | --- | --- | --- |",
        ]
    )

    for state in spec["states"]:
        signals = ", ".join(f"`{name}`" for name in state["asserted_signals"]) or "-"
        lines.append(
            "| `{state}` | {role} | {signals} | `{next_}` |".format(
                state=state["state"],
                role=state["role"],
                signals=signals,
                next_=state["next_default"],
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    fsm_table = load_json(args.fsm_table_json)
    spec = build_spec(schedule, fsm_table)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(spec, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(spec, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
