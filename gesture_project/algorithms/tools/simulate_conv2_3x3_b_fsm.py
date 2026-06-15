"""Simulate FSM-level state/transition counts for conv2_3x3_b 4x8x8 flow."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="Input tile schedule JSON.")
    parser.add_argument("--out_json", required=True, help="Output simulation JSON.")
    parser.add_argument("--out_md", required=True, help="Output simulation Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def transition_key(src: str, dst: str) -> str:
    return f"{src}->{dst}"


def build_strategy(
    schedule: dict[str, Any],
    strategy_name: str,
    use_row_resident_weights: bool,
) -> dict[str, Any]:
    tiles_y = int(schedule["grid"]["tiles_y"])
    tiles_x = int(schedule["grid"]["tiles_x"])
    tiles_oc = int(schedule["grid"]["tiles_oc"])

    first_fill_bytes = int(schedule["line_fill"]["first_spatial_site_bytes"])
    x_shift_bytes = int(schedule["x_shift"]["new_bytes_per_shift"])
    y_advance_bytes = int(schedule["y_advance"]["new_bytes_per_advance"])
    weight_tile_bytes = int(schedule["weight_schedule"]["weight_tile_bytes"])
    weight_row_bytes = int(schedule["weight_schedule"]["weights_per_spatial_site"])
    output_tile_bytes = int(schedule["writeback"]["tile_output_bytes"])
    acc_tile_bytes = int(schedule["writeback"]["tile_acc_bytes"])

    state_visits: Counter[str] = Counter()
    transition_counts: Counter[str] = Counter()
    state_bytes: dict[str, dict[str, int]] = {
        state: {"input_bytes": 0, "weight_bytes": 0, "output_bytes": 0}
        for state in (
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
        )
    }

    def visit(state: str) -> None:
        state_visits[state] += 1

    def transition(src: str, dst: str) -> None:
        transition_counts[transition_key(src, dst)] += 1

    visit("S0_IDLE")

    for y in range(tiles_y):
        if use_row_resident_weights:
            transition("S0_IDLE" if y == 0 else "S8_ADVANCE_ROW", "S1_PRELOAD_WEIGHTS")
            visit("S1_PRELOAD_WEIGHTS")
            state_bytes["S1_PRELOAD_WEIGHTS"]["weight_bytes"] += weight_row_bytes
            transition("S1_PRELOAD_WEIGHTS", "S2_FILL_FIRST_TILE")
        else:
            transition("S0_IDLE" if y == 0 else "S8_ADVANCE_ROW", "S2_FILL_FIRST_TILE")

        visit("S2_FILL_FIRST_TILE")
        state_bytes["S2_FILL_FIRST_TILE"]["input_bytes"] += first_fill_bytes
        transition("S2_FILL_FIRST_TILE", "S3_LOAD_WEIGHT_GROUP")

        for x in range(tiles_x):
            for oc in range(tiles_oc):
                visit("S3_LOAD_WEIGHT_GROUP")
                if not use_row_resident_weights:
                    state_bytes["S3_LOAD_WEIGHT_GROUP"]["weight_bytes"] += weight_tile_bytes

                transition("S3_LOAD_WEIGHT_GROUP", "S4_COMPUTE_ACC")
                visit("S4_COMPUTE_ACC")
                state_bytes["S4_COMPUTE_ACC"]["output_bytes"] += acc_tile_bytes

                transition("S4_COMPUTE_ACC", "S5_QUANTIZE_WRITEBACK")
                visit("S5_QUANTIZE_WRITEBACK")
                state_bytes["S5_QUANTIZE_WRITEBACK"]["output_bytes"] += output_tile_bytes

                transition("S5_QUANTIZE_WRITEBACK", "S6_NEXT_OC_OR_SHIFT")
                visit("S6_NEXT_OC_OR_SHIFT")

                if oc < tiles_oc - 1:
                    transition("S6_NEXT_OC_OR_SHIFT", "S3_LOAD_WEIGHT_GROUP")
                    continue

                if x < tiles_x - 1:
                    transition("S6_NEXT_OC_OR_SHIFT", "S7_WINDOW_SHIFT")
                    visit("S7_WINDOW_SHIFT")
                    state_bytes["S7_WINDOW_SHIFT"]["input_bytes"] += x_shift_bytes
                    transition("S7_WINDOW_SHIFT", "S3_LOAD_WEIGHT_GROUP")
                elif y < tiles_y - 1:
                    transition("S6_NEXT_OC_OR_SHIFT", "S8_ADVANCE_ROW")
                    visit("S8_ADVANCE_ROW")
                    state_bytes["S8_ADVANCE_ROW"]["input_bytes"] += y_advance_bytes
                else:
                    transition("S6_NEXT_OC_OR_SHIFT", "S9_DONE")
                    visit("S9_DONE")

    totals = {
        key: sum(bucket[key] for bucket in state_bytes.values())
        for key in ("input_bytes", "weight_bytes", "output_bytes")
    }

    return {
        "strategy": strategy_name,
        "row_resident_weights": use_row_resident_weights,
        "state_visits": dict(state_visits),
        "transition_counts": dict(sorted(transition_counts.items())),
        "state_bytes": state_bytes,
        "totals": totals,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 FSM 代理仿真",
        "",
        "- 对象：`conv2_3x3_b`",
        "- 配置：`row_tile=4, col_tile=8, oc_tile=8`",
        "- 目的：比较“每空间 tile 重载 weight”和“同一 tile 行常驻 weight”两种控制策略下的状态访问与转移口径。",
    ]

    for strategy in report["strategies"]:
        totals = strategy["totals"]
        lines.extend(
            [
                "",
                f"## 策略：`{strategy['strategy']}`",
                "",
                f"- 输入流量：`{totals['input_bytes']:,} B`",
                f"- Weight 流量：`{totals['weight_bytes']:,} B`",
                f"- 输出相关写入：`{totals['output_bytes']:,} B`",
                "",
                "| 状态 | 访问次数 | input bytes | weight bytes | output bytes |",
                "| --- | ---: | ---: | ---: | ---: |",
            ]
        )

        for state, visits in strategy["state_visits"].items():
            bucket = strategy["state_bytes"][state]
            lines.append(
                "| `{state}` | {visits:,} | {input_bytes:,} | {weight_bytes:,} | {output_bytes:,} |".format(
                    state=state,
                    visits=visits,
                    input_bytes=bucket["input_bytes"],
                    weight_bytes=bucket["weight_bytes"],
                    output_bytes=bucket["output_bytes"],
                )
            )

        lines.extend(
            [
                "",
                "| 转移 | 次数 |",
                "| --- | ---: |",
            ]
        )
        for key, count in strategy["transition_counts"].items():
            lines.append(f"| `{key}` | {count:,} |")

    if len(report["strategies"]) == 2:
        baseline = report["strategies"][0]
        resident = report["strategies"][1]
        weight_gain = baseline["totals"]["weight_bytes"] / resident["totals"]["weight_bytes"]
        lines.extend(
            [
                "",
                "## 对比结论",
                "",
                f"- 两种策略的输入流量相同，说明当前阶段收益差异主要来自 weight 调度，而不是 line/window 侧。",
                f"- row-resident 策略把 weight 流量从 `{baseline['totals']['weight_bytes']:,} B` 压到 `{resident['totals']['weight_bytes']:,} B`，约为 `{weight_gain:.2f}x` 缩减。",
                "- `S6_NEXT_OC_OR_SHIFT` 在两种策略下访问次数相同，说明它仍然是最核心的控制交汇点。",
                "- 若先做第一版最小闭环，可以先采用保守重载策略；若第二阶段追求更高收益，则最自然的增强点就是把 `S1_PRELOAD_WEIGHTS` 真正接入控制路径。",
            ]
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    strategies = [
        build_strategy(schedule, "per_spatial_tile_reload", use_row_resident_weights=False),
        build_strategy(schedule, "row_resident_weights", use_row_resident_weights=True),
    ]
    report = {
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "config": schedule["config"],
        "strategies": strategies,
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
