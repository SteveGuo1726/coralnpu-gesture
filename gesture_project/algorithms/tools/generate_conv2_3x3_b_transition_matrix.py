"""Generate transition matrix for conv2_3x3_b 4x8x8 FSM simulation."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


STATE_ORDER = [
    "S0_IDLE",
    "S1_PRELOAD_WEIGHTS",
    "S2_FILL_FIRST_TILE",
    "S3_LOAD_WEIGHT_GROUP",
    "S4_COMPUTE_ACC",
    "S5_QUANTIZE_WRITEBACK",
    "S6_NEXT_OC_OR_SHIFT",
    "S7_WINDOW_SHIFT",
    "S8_ADVANCE_ROW",
    "S9_DONE",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fsm_sim_json", required=True, help="Input FSM sim JSON for one strategy.")
    parser.add_argument("--out_json", required=True, help="Output matrix JSON.")
    parser.add_argument("--out_md", required=True, help="Output matrix Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_matrix(report: dict[str, Any]) -> dict[str, Any]:
    matrix = {src: {dst: 0 for dst in STATE_ORDER} for src in STATE_ORDER}

    trace = report["trace"]
    for idx in range(len(trace) - 1):
        src = trace[idx]["state"]
        dst = trace[idx + 1]["state"]
        if src in matrix and dst in matrix[src]:
            matrix[src][dst] += 1

    return {
        "strategy": report["strategy"],
        "row_resident_weights": report["row_resident_weights"],
        "state_order": STATE_ORDER,
        "matrix": matrix,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    order = report["state_order"]
    matrix = report["matrix"]

    lines = [
        "# conv2_3x3_b 4x8x8 状态转移矩阵",
        "",
        f"- 策略：`{report['strategy']}`",
        "",
        "| from \\ to | " + " | ".join(f"`{state}`" for state in order) + " |",
        "| --- | " + " | ".join("---:" for _ in order) + " |",
    ]

    for src in order:
        row = " | ".join(str(matrix[src][dst]) for dst in order)
        lines.append(f"| `{src}` | {row} |")

    lines.extend(
        [
            "",
            "## 工程解读",
            "",
            "- 对角线若为 0，说明当前最小原型没有显式建模状态自循环，而是把每次状态访问当成独立事件。",
            "- 非零最密集的路径应集中在 `S3 -> S4 -> S5 -> S6`，它对应当前主配置里最热的 oc_group 子循环。",
            "- 若策略为 `reload`，矩阵中不会出现 `S1_PRELOAD_WEIGHTS` 的有效转移；若策略为 `row_resident`，它会成为每条 tile 行起始处的显式前导状态。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = load_json(args.fsm_sim_json)
    matrix_report = build_matrix(report)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(matrix_report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(matrix_report, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
