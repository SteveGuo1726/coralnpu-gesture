"""Generate FSM-oriented state table for conv2_3x3_b 4x8x8 main configuration."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="Input tile schedule JSON.")
    parser.add_argument("--out_json", required=True, help="Output FSM JSON.")
    parser.add_argument("--out_md", required=True, help="Output FSM Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_states(report: dict[str, Any]) -> list[dict[str, Any]]:
    x_shift = report["x_shift"]
    y_advance = report["y_advance"]
    line_fill = report["line_fill"]
    weight = report["weight_schedule"]
    writeback = report["writeback"]
    grid = report["grid"]

    return [
        {
            "state": "S0_IDLE",
            "role": "等待新 layer 或新 tile-row 任务",
            "enter_when": "收到 conv2_3x3_b layer start 或新 out_y_tile 请求",
            "updates": "清零 out_x_tile / oc_group 计数器；决定 weight 策略",
            "outputs": "控制信号准备 line buffer、weight buffer、accumulator bank",
            "next_default": "S1_PRELOAD_WEIGHTS or S2_FILL_FIRST_TILE",
        },
        {
            "state": "S1_PRELOAD_WEIGHTS",
            "role": "同一 out_y_tile 行常驻策略下预装 weight",
            "enter_when": "启用 row-resident weight 策略",
            "updates": f"装入 4 组 oc_tile weights，总量 {weight['weights_per_spatial_site']:,} B",
            "outputs": "weight buffer 进入 row-resident 模式",
            "next_default": "S2_FILL_FIRST_TILE",
        },
        {
            "state": "S2_FILL_FIRST_TILE",
            "role": "装入当前 out_y_tile 的首个空间 tile 输入",
            "enter_when": "新 out_y_tile 开始，或从 IDLE 进入",
            "updates": f"填充 6 行 line buffer，建立 6x10x32 window，输入 {line_fill['first_spatial_site_bytes']:,} B",
            "outputs": "line buffer valid, window buffer valid",
            "next_default": "S3_LOAD_WEIGHT_GROUP",
        },
        {
            "state": "S3_LOAD_WEIGHT_GROUP",
            "role": "为当前 oc_group 装入 3x3x32x8 weight tile",
            "enter_when": "每个空间 tile 的 oc_group 开始，且 weight 非常驻或需要切换",
            "updates": f"若按最保守策略，每次装入 {weight['weight_tile_bytes']:,} B weight tile",
            "outputs": "当前 oc_group weight valid",
            "next_default": "S4_COMPUTE_ACC",
        },
        {
            "state": "S4_COMPUTE_ACC",
            "role": "计算当前 4x8x8 tile 的 int32 accumulators",
            "enter_when": "window valid 且 current weight valid",
            "updates": f"更新 tile accumulator bank，容量 {writeback['tile_acc_bytes']:,} B",
            "outputs": "accumulator bank valid",
            "next_default": "S5_QUANTIZE_WRITEBACK",
        },
        {
            "state": "S5_QUANTIZE_WRITEBACK",
            "role": "在 tile 内完成 quantize 并写回 int8 输出",
            "enter_when": "当前 oc_group accumulators 完成",
            "updates": f"写出 {writeback['tile_output_bytes']:,} B output tile，oc_group 计数器 +1",
            "outputs": "int8 output tile commit",
            "next_default": "S6_NEXT_OC_OR_SHIFT",
        },
        {
            "state": "S6_NEXT_OC_OR_SHIFT",
            "role": "判断继续下一个 oc_group 还是转入下一个空间 tile",
            "enter_when": "单个 oc_group 写回完成",
            "updates": f"若 oc_group < {grid['tiles_oc'] - 1} 则继续；否则 out_x_tile 判断推进",
            "outputs": "更新 oc_group / out_x_tile 分支控制",
            "next_default": "S3_LOAD_WEIGHT_GROUP or S7_WINDOW_SHIFT or S8_ADVANCE_ROW",
        },
        {
            "state": "S7_WINDOW_SHIFT",
            "role": "横向推进到下一个 out_x_tile",
            "enter_when": "当前 out_y_tile 内，仍有后续 out_x_tile",
            "updates": (
                f"保留左侧 2 列历史窗口 {x_shift['reused_bytes_per_shift']:,} B，"
                f"仅新增右侧 8 列输入 {x_shift['new_bytes_per_shift']:,} B"
            ),
            "outputs": "window buffer shifted",
            "next_default": "S3_LOAD_WEIGHT_GROUP",
        },
        {
            "state": "S8_ADVANCE_ROW",
            "role": "纵向推进到下一个 out_y_tile",
            "enter_when": "当前 out_x_tile 行结束，且仍有后续 out_y_tile",
            "updates": (
                f"保留旧 2 行输入 {y_advance['reused_bytes_per_advance']:,} B，"
                f"新增 4 行输入 {y_advance['new_bytes_per_advance']:,} B，"
                "重建该行首个 window"
            ),
            "outputs": "line buffer row-advanced",
            "next_default": "S1_PRELOAD_WEIGHTS or S3_LOAD_WEIGHT_GROUP",
        },
        {
            "state": "S9_DONE",
            "role": "完成整个 conv2_3x3_b layer",
            "enter_when": "最后一个 out_y_tile / out_x_tile / oc_group 完成",
            "updates": "发出 layer done，等待下一个 layer 或 block",
            "outputs": "done pulse",
            "next_default": "S0_IDLE",
        },
    ]


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 状态机阶段表",
        "",
        "- 对象：`conv2_3x3_b`",
        "- 主配置：`row_tile=4, col_tile=8, oc_tile=8`",
        "- 说明：本表用于把当前 RTL 草案进一步压成状态机级别的阶段定义。",
        "",
        "## 状态表",
        "",
        "| 状态 | 作用 | 进入条件 | 主要更新 | 主要输出 | 默认下一状态 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]

    for state in report["states"]:
        lines.append(
            "| `{state}` | {role} | {enter} | {updates} | {outputs} | `{next_}` |".format(
                state=state["state"],
                role=state["role"],
                enter=state["enter_when"],
                updates=state["updates"],
                outputs=state["outputs"],
                next_=state["next_default"],
            )
        )

    lines.extend(
        [
            "",
            "## 控制分叉点",
            "",
            "- `S0_IDLE -> S1_PRELOAD_WEIGHTS`：仅在采用“同一 out_y_tile 行常驻”策略时进入。",
            "- `S6_NEXT_OC_OR_SHIFT`：这是当前主配置里最核心的分叉状态，决定继续 `oc_group`，还是切到横向/纵向下一个空间 tile。",
            "- `S8_ADVANCE_ROW` 之后是否回到 `S1_PRELOAD_WEIGHTS`，取决于 weight 是否按 tile 行常驻。",
            "",
            "## 当前工程解读",
            "",
            "- 如果先做第一版最保守实现，可以直接去掉 `S1_PRELOAD_WEIGHTS`，让 `S3_LOAD_WEIGHT_GROUP` 在每个空间 tile 中都执行。",
            "- 如果希望尽快验证更像 RTL 的第二阶段收益，则应保留 `S1_PRELOAD_WEIGHTS`，并在 tile 行内复用同一组 weight。",
            "- `S7_WINDOW_SHIFT` 和 `S8_ADVANCE_ROW` 被单独抽成状态，意味着输入复用已经不再只是注释里的愿望，而是控制路径上的显式阶段。",
            "- `S5_QUANTIZE_WRITEBACK` 独立成状态，也对应了“tile 内量化写回、避免整图 accs_buf”的核心目标。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    report = {
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "config": schedule["config"],
        "states": build_states(schedule),
    }

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
