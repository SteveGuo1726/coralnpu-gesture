"""Executable controller prototype for conv2_3x3_b 4x8x8 FSM flow."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="Input tile schedule JSON.")
    parser.add_argument("--strategy", choices=["reload", "row_resident"], default="reload")
    parser.add_argument("--max_events", type=int, default=160, help="Max events kept in trace output.")
    parser.add_argument("--out_json", required=True, help="Output JSON trace.")
    parser.add_argument("--out_md", required=True, help="Output Markdown trace summary.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def log_event(
    trace: list[dict[str, Any]],
    max_events: int,
    cycle: int,
    state: str,
    out_y_tile: int,
    out_x_tile: int,
    oc_group: int,
    detail: str,
) -> None:
    if len(trace) < max_events:
        trace.append(
            {
                "cycle": cycle,
                "state": state,
                "out_y_tile": out_y_tile,
                "out_x_tile": out_x_tile,
                "oc_group": oc_group,
                "detail": detail,
            }
        )


def run_controller(schedule: dict[str, Any], strategy: str, max_events: int) -> dict[str, Any]:
    tiles_y = int(schedule["grid"]["tiles_y"])
    tiles_x = int(schedule["grid"]["tiles_x"])
    tiles_oc = int(schedule["grid"]["tiles_oc"])

    x_shift_bytes = int(schedule["x_shift"]["new_bytes_per_shift"])
    y_advance_bytes = int(schedule["y_advance"]["new_bytes_per_advance"])
    first_fill_bytes = int(schedule["line_fill"]["first_spatial_site_bytes"])
    weight_tile_bytes = int(schedule["weight_schedule"]["weight_tile_bytes"])
    weight_row_bytes = int(schedule["weight_schedule"]["weights_per_spatial_site"])
    output_tile_bytes = int(schedule["writeback"]["tile_output_bytes"])

    row_resident = strategy == "row_resident"
    trace: list[dict[str, Any]] = []
    state_visits: Counter[str] = Counter()
    counters = {
        "line_fill_count": 0,
        "window_shift_count": 0,
        "row_advance_count": 0,
        "weight_group_load_count": 0,
        "weight_row_preload_count": 0,
        "quant_write_count": 0,
    }
    bytes_summary = {
        "input_bytes": 0,
        "weight_bytes": 0,
        "output_bytes": 0,
    }

    cycle = 0
    state_visits["S0_IDLE"] += 1
    log_event(trace, max_events, cycle, "S0_IDLE", 0, 0, 0, f"strategy={strategy}")

    for y in range(tiles_y):
        if row_resident:
            cycle += 1
            state_visits["S1_PRELOAD_WEIGHTS"] += 1
            counters["weight_row_preload_count"] += 1
            bytes_summary["weight_bytes"] += weight_row_bytes
            log_event(
                trace,
                max_events,
                cycle,
                "S1_PRELOAD_WEIGHTS",
                y,
                0,
                0,
                f"preload row weights {weight_row_bytes} B",
            )

        cycle += 1
        state_visits["S2_FILL_FIRST_TILE"] += 1
        counters["line_fill_count"] += 1
        bytes_summary["input_bytes"] += first_fill_bytes
        log_event(
            trace,
            max_events,
            cycle,
            "S2_FILL_FIRST_TILE",
            y,
            0,
            0,
            f"fill first tile {first_fill_bytes} B",
        )

        for x in range(tiles_x):
            for oc in range(tiles_oc):
                cycle += 1
                state_visits["S3_LOAD_WEIGHT_GROUP"] += 1
                counters["weight_group_load_count"] += 1
                if not row_resident:
                    bytes_summary["weight_bytes"] += weight_tile_bytes
                log_event(
                    trace,
                    max_events,
                    cycle,
                    "S3_LOAD_WEIGHT_GROUP",
                    y,
                    x,
                    oc,
                    "reuse preloaded row weights" if row_resident else f"load weight tile {weight_tile_bytes} B",
                )

                cycle += 1
                state_visits["S4_COMPUTE_ACC"] += 1
                log_event(
                    trace,
                    max_events,
                    cycle,
                    "S4_COMPUTE_ACC",
                    y,
                    x,
                    oc,
                    "compute 4x8x8 accumulators",
                )

                cycle += 1
                state_visits["S5_QUANTIZE_WRITEBACK"] += 1
                counters["quant_write_count"] += 1
                bytes_summary["output_bytes"] += output_tile_bytes
                log_event(
                    trace,
                    max_events,
                    cycle,
                    "S5_QUANTIZE_WRITEBACK",
                    y,
                    x,
                    oc,
                    f"write output tile {output_tile_bytes} B",
                )

                cycle += 1
                state_visits["S6_NEXT_OC_OR_SHIFT"] += 1
                if oc < tiles_oc - 1:
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S6_NEXT_OC_OR_SHIFT",
                        y,
                        x,
                        oc,
                        "next oc_group",
                    )
                    continue

                if x < tiles_x - 1:
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S6_NEXT_OC_OR_SHIFT",
                        y,
                        x,
                        oc,
                        "advance out_x_tile",
                    )
                    cycle += 1
                    state_visits["S7_WINDOW_SHIFT"] += 1
                    counters["window_shift_count"] += 1
                    bytes_summary["input_bytes"] += x_shift_bytes
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S7_WINDOW_SHIFT",
                        y,
                        x + 1,
                        0,
                        f"window shift +{x_shift_bytes} B",
                    )
                elif y < tiles_y - 1:
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S6_NEXT_OC_OR_SHIFT",
                        y,
                        x,
                        oc,
                        "advance out_y_tile",
                    )
                    cycle += 1
                    state_visits["S8_ADVANCE_ROW"] += 1
                    counters["row_advance_count"] += 1
                    bytes_summary["input_bytes"] += y_advance_bytes
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S8_ADVANCE_ROW",
                        y + 1,
                        0,
                        0,
                        f"advance row +{y_advance_bytes} B",
                    )
                else:
                    log_event(
                        trace,
                        max_events,
                        cycle,
                        "S6_NEXT_OC_OR_SHIFT",
                        y,
                        x,
                        oc,
                        "done",
                    )

    cycle += 1
    state_visits["S9_DONE"] += 1
    log_event(trace, max_events, cycle, "S9_DONE", tiles_y - 1, tiles_x - 1, tiles_oc - 1, "layer done")

    return {
        "strategy": strategy,
        "row_resident_weights": row_resident,
        "trace_event_count": len(trace),
        "trace_truncated": len(trace) >= max_events,
        "trace": trace,
        "state_visits": dict(state_visits),
        "counters": counters,
        "bytes_summary": bytes_summary,
        "total_steps": cycle,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 最小控制器原型",
        "",
        f"- 策略：`{report['strategy']}`",
        f"- 总状态步数：`{report['total_steps']}`",
        f"- 事件轨迹条数：`{report['trace_event_count']}`",
        f"- 轨迹是否截断：`{report['trace_truncated']}`",
        "",
        "## 计数摘要",
        "",
        f"- line fill 次数：`{report['counters']['line_fill_count']}`",
        f"- window shift 次数：`{report['counters']['window_shift_count']}`",
        f"- row advance 次数：`{report['counters']['row_advance_count']}`",
        f"- weight group load 次数：`{report['counters']['weight_group_load_count']}`",
        f"- weight row preload 次数：`{report['counters']['weight_row_preload_count']}`",
        f"- quant write 次数：`{report['counters']['quant_write_count']}`",
        "",
        "## 字节摘要",
        "",
        f"- 输入流量：`{report['bytes_summary']['input_bytes']:,} B`",
        f"- Weight 流量：`{report['bytes_summary']['weight_bytes']:,} B`",
        f"- 输出流量：`{report['bytes_summary']['output_bytes']:,} B`",
        "",
        "## 状态访问次数",
        "",
        "| 状态 | 次数 |",
        "| --- | ---: |",
    ]

    for state, count in report["state_visits"].items():
        lines.append(f"| `{state}` | {count:,} |")

    lines.extend(
        [
            "",
            "## 轨迹片段",
            "",
            "| step | state | out_y_tile | out_x_tile | oc_group | detail |",
            "| --- | --- | ---: | ---: | ---: | --- |",
        ]
    )

    for event in report["trace"]:
        lines.append(
            "| {cycle} | `{state}` | {out_y_tile} | {out_x_tile} | {oc_group} | {detail} |".format(
                **event
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    report = run_controller(schedule, args.strategy, args.max_events)

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
