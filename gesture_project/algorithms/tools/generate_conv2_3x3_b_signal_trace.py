"""Generate signal-level trace from controller prototype output."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


STATE_TO_SIGNALS = {
    "S1_PRELOAD_WEIGHTS": ["weight_preload_req"],
    "S2_FILL_FIRST_TILE": ["line_fill_req"],
    "S3_LOAD_WEIGHT_GROUP": ["weight_group_load_req"],
    "S4_COMPUTE_ACC": ["compute_req"],
    "S5_QUANTIZE_WRITEBACK": ["quant_write_req"],
    "S7_WINDOW_SHIFT": ["window_shift_req"],
    "S8_ADVANCE_ROW": ["row_advance_req"],
    "S9_DONE": ["done_pulse"],
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller_json", required=True, help="Input controller prototype JSON.")
    parser.add_argument("--out_json", required=True, help="Output signal trace JSON.")
    parser.add_argument("--out_md", required=True, help="Output signal trace Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_signal_trace(report: dict[str, Any]) -> dict[str, Any]:
    signal_events: list[dict[str, Any]] = []
    signal_counts: dict[str, int] = {}

    for event in report["trace"]:
        signals = STATE_TO_SIGNALS.get(event["state"], [])
        for signal in signals:
            signal_events.append(
                {
                    "cycle": event["cycle"],
                    "signal": signal,
                    "state": event["state"],
                    "out_y_tile": event["out_y_tile"],
                    "out_x_tile": event["out_x_tile"],
                    "oc_group": event["oc_group"],
                    "detail": event["detail"],
                }
            )
            signal_counts[signal] = signal_counts.get(signal, 0) + 1

    return {
        "strategy": report["strategy"],
        "row_resident_weights": report["row_resident_weights"],
        "signal_counts": signal_counts,
        "signal_events": signal_events,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 控制信号 Trace",
        "",
        f"- 策略：`{report['strategy']}`",
        "",
        "## 信号次数",
        "",
        "| 信号 | 次数 |",
        "| --- | ---: |",
    ]

    for signal, count in sorted(report["signal_counts"].items()):
        lines.append(f"| `{signal}` | {count:,} |")

    lines.extend(
        [
            "",
            "## 信号事件片段",
            "",
            "| cycle | signal | state | out_y_tile | out_x_tile | oc_group | detail |",
            "| --- | --- | --- | ---: | ---: | ---: | --- |",
        ]
    )

    for event in report["signal_events"][:160]:
        lines.append(
            "| {cycle} | `{signal}` | `{state}` | {out_y_tile} | {out_x_tile} | {oc_group} | {detail} |".format(
                **event
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    controller = load_json(args.controller_json)
    trace = build_signal_trace(controller)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(trace, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(trace, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
