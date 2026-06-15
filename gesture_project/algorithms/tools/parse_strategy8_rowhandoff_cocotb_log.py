"""解析 rowhandoff cocotb 日志，并可导出边界事件写流 JSON。"""

from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INPUT_LOG = (
    PROJECT_ROOT
    / "reports"
    / "core_3x3_strategy8_rowhandoff_cocotb_log_sample_2026-06-11.log"
)
DEFAULT_EVENT_ADDR = 0x30840
ROWHANDOFF_EVENT_OFFSET_MASK = 0xFFF

COUNTER_LINE_PATTERNS = {
    "host_counters": re.compile(r"^host_counters=(\{.*\})$"),
    "workload_counters": re.compile(r"^workload_counters=(\{.*\})$"),
    "probe_counters": re.compile(r"^probe_counters=(\{.*\})$"),
    "snapshot_counters": re.compile(r"^snapshot_counters=(\{.*\})$"),
    "dm_snapshot_counters": re.compile(r"^dm_snapshot_counters=(\{.*\})$"),
    "poll_snapshot_start_counters": re.compile(r"^poll_snapshot_start_counters=(\{.*\})$"),
    "poll_snapshot_counters": re.compile(r"^poll_snapshot_counters=(\{.*\})$"),
    "smoke_counters": re.compile(r"^smoke_counters=(\{.*\})$"),
}

SCALAR_LINE_PATTERNS = {
    "halt_cycles": re.compile(r"^halt_cycles=(\d+)$"),
    "probe_halt_cycles": re.compile(r"^probe_halt_cycles=(\d+)$"),
    "snapshot_cycles": re.compile(r"^snapshot_cycles=(\d+)$"),
    "dm_snapshot_run_cycles": re.compile(r"^dm_snapshot_run_cycles=(\d+)$"),
    "dm_snapshot_cycles": re.compile(r"^dm_snapshot_cycles=(\d+)$"),
    "poll_snapshot_warmup_cycles": re.compile(r"^poll_snapshot_warmup_cycles=(\d+)$"),
    "poll_snapshot_cycles": re.compile(r"^poll_snapshot_cycles=(\d+)$"),
    "smoke_halt_cycles": re.compile(r"^smoke_halt_cycles=(\d+)$"),
}

EVENT_WRITE_PATTERN = re.compile(
    r"^rowhandoff_event_write"
    r"(?:\s+cycle=(?P<cycle>\d+))?"
    r"\s+addr=(?P<addr>0x[0-9a-fA-F]+|\d+)"
    r"\s+wdata=(?P<wdata>0x[0-9a-fA-F]+|\d+)"
    r"(?:\s+out_y=(?P<out_y>\d+))?"
    r"(?:\s+events=(?P<events>[A-Za-z0-9_,.-]+))?"
    r"(?:\s+row_gate_active=(?P<row_gate_active>[Tt]rue|[Ff]alse))?"
    r"(?:\s+current_row=(?P<current_row>\d+))?"
    r"(?:\s+valid_state=(?P<valid_state>[Tt]rue|[Ff]alse))?"
    r"(?:\s+consume_valid=(?P<consume_valid>[Tt]rue|[Ff]alse))?"
    r"(?:\s+consume_hit=(?P<consume_hit>[Tt]rue|[Ff]alse))?"
    r"(?:\s+tail_seen=(?P<tail_seen>[Tt]rue|[Ff]alse))?"
    r"(?:\s+last_produced=(?P<last_produced>\d+))?"
    r"(?:\s+last_invalidated=(?P<last_invalidated>\d+))?"
    r"(?:\s+row_enter_pulse=(?P<row_enter_pulse>[Tt]rue|[Ff]alse))?"
    r"(?:\s+row_terminal_done_pulse=(?P<row_terminal_done_pulse>[Tt]rue|[Ff]alse))?"
    r"(?:\s+row_advance_done_pulse=(?P<row_advance_done_pulse>[Tt]rue|[Ff]alse))?"
    r"(?:\s+note=(?P<note>.+))?$"
)

EXPECTED_COUNTER_PROFILES = {
    "host_preflight": {
        "hit": 1,
        "miss": 1,
        "invalidate": 1,
        "produce": 1,
        "tail_hit": 1,
        "interior_row_enter": 1,
        "right_edge_done": 1,
        "row_out_y_last": 18,
    },
    "mode1_full": {
        "hit": 45,
        "miss": 1,
        "invalidate": 1,
        "produce": 46,
        "tail_hit": 22,
        "interior_row_enter": 46,
        "right_edge_done": 46,
        "row_out_y_last": 46,
    },
    "mode1_backhalf": {
        "hit": 21,
        "miss": 1,
        "invalidate": 1,
        "produce": 22,
        "tail_hit": 21,
        "interior_row_enter": 22,
        "right_edge_done": 22,
        "row_out_y_last": 45,
    },
    "mode1_backhalf_rowloop_probe": {
        "hit": 21,
        "miss": 1,
        "invalidate": 1,
        "produce": 22,
        "tail_hit": 21,
        "interior_row_enter": 22,
        "right_edge_done": 22,
        "row_out_y_last": 46,
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input_log",
        default=str(DEFAULT_INPUT_LOG),
        help="待解析的 cocotb 日志。",
    )
    parser.add_argument(
        "--rowhandoff_event_addr",
        default=hex(DEFAULT_EVENT_ADDR),
        help="rowhandoff 事件写地址，支持十进制或十六进制。",
    )
    parser.add_argument(
        "--expected_profile",
        choices=sorted(EXPECTED_COUNTER_PROFILES),
        help="若提供，则对 workload/probe/poll/dm snapshot 计数做配置化对账。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    parser.add_argument(
        "--out_trace_json",
        help="若日志中存在 rowhandoff_event_write 行，则输出给重建脚本使用的 trace JSON。",
    )
    return parser.parse_args()


def parse_int(value: str | int) -> int:
    if isinstance(value, int):
        return value
    return int(value, 0)


def addr_matches_event_addr(addr: int, event_addr: int) -> bool:
    return addr == event_addr or (
        (addr & ROWHANDOFF_EVENT_OFFSET_MASK)
        == (event_addr & ROWHANDOFF_EVENT_OFFSET_MASK)
    )


def parse_optional_bool(value: str | None) -> bool | None:
    if value is None:
        return None
    return value.lower() == "true"


def parse_counter_dict(text: str) -> dict[str, int]:
    raw = ast.literal_eval(text)
    return {str(key): int(value) for key, value in raw.items()}


def load_lines(path: str | Path) -> list[str]:
    return Path(path).read_text(encoding="utf-8", errors="replace").splitlines()


def parse_log(lines: list[str], event_addr: int) -> dict[str, Any]:
    snapshots: list[dict[str, Any]] = []
    scalar_events: list[dict[str, Any]] = []
    event_writes: list[dict[str, Any]] = []

    for line_no, line in enumerate(lines, start=1):
        matched = False

        for name, pattern in COUNTER_LINE_PATTERNS.items():
            match = pattern.search(line)
            if match:
                snapshots.append(
                    {
                        "line_no": line_no,
                        "kind": name,
                        "counters": parse_counter_dict(match.group(1)),
                    }
                )
                matched = True
                break
        if matched:
            continue

        for name, pattern in SCALAR_LINE_PATTERNS.items():
            match = pattern.search(line)
            if match:
                scalar_events.append(
                    {
                        "line_no": line_no,
                        "kind": name,
                        "value": int(match.group(1)),
                    }
                )
                matched = True
                break
        if matched:
            continue

        match = EVENT_WRITE_PATTERN.search(line)
        if match:
            addr = parse_int(match.group("addr"))
            events_text = match.group("events")
            tracker_state = {
                "row_gate_active": parse_optional_bool(match.group("row_gate_active")),
                "current_row": int(match.group("current_row")) if match.group("current_row") else None,
                "valid_state": parse_optional_bool(match.group("valid_state")),
                "consume_valid": parse_optional_bool(match.group("consume_valid")),
                "consume_hit": parse_optional_bool(match.group("consume_hit")),
                "tail_seen": parse_optional_bool(match.group("tail_seen")),
                "last_produced": int(match.group("last_produced")) if match.group("last_produced") else None,
                "last_invalidated": int(match.group("last_invalidated")) if match.group("last_invalidated") else None,
                "row_enter_pulse": parse_optional_bool(match.group("row_enter_pulse")),
                "row_terminal_done_pulse": parse_optional_bool(match.group("row_terminal_done_pulse")),
                "row_advance_done_pulse": parse_optional_bool(match.group("row_advance_done_pulse")),
            }
            event_writes.append(
                {
                    "line_no": line_no,
                    "cycle": int(match.group("cycle")) if match.group("cycle") else None,
                    "addr": addr,
                    "wdata": parse_int(match.group("wdata")),
                    "out_y": int(match.group("out_y")) if match.group("out_y") else None,
                    "events": events_text.split(",") if events_text else [],
                    "tracker_state": tracker_state,
                    "note": match.group("note").strip() if match.group("note") else None,
                    "event_write_pulse": addr_matches_event_addr(addr, event_addr),
                }
            )

    return {
        "snapshots": snapshots,
        "scalar_events": scalar_events,
        "event_writes": event_writes,
    }


def compare_counters(actual: dict[str, int], expected: dict[str, int]) -> dict[str, Any]:
    mismatches = []
    for key, expected_value in expected.items():
        actual_value = actual.get(key)
        if actual_value != expected_value:
            mismatches.append(
                {
                    "counter": key,
                    "expected": expected_value,
                    "actual": actual_value,
                }
            )
    return {"pass": not mismatches, "mismatches": mismatches}


def build_trace_json(
    event_writes: list[dict[str, Any]],
    input_log: Path,
    event_addr: int,
) -> dict[str, Any]:
    try:
        source_log = str(input_log.relative_to(PROJECT_ROOT.parent))
    except ValueError:
        source_log = str(input_log)

    samples = []
    for item in event_writes:
        samples.append(
            {
                "cycle": item["cycle"],
                "valid": True,
                "internal": True,
                "write": True,
                "addr": hex(item["addr"]),
                "wdata": hex(item["wdata"]),
                "note": item["note"],
            }
        )
    return {
        "project_stage": "strategy8 rowhandoff cocotb log extracted event trace",
        "source_log": source_log,
        "rowhandoff_event_addr": hex(event_addr),
        "samples": samples,
    }


def build_report(
    parsed: dict[str, Any],
    input_log: Path,
    expected_profile: str | None,
    event_addr: int,
) -> dict[str, Any]:
    try:
        display_input_log = str(input_log.relative_to(PROJECT_ROOT.parent))
    except ValueError:
        display_input_log = str(input_log)

    expected = (
        EXPECTED_COUNTER_PROFILES[expected_profile] if expected_profile is not None else None
    )

    comparison = None
    if expected is not None:
        candidate = None
        for preferred_kind in (
            "workload_counters",
            "probe_counters",
            "poll_snapshot_counters",
            "dm_snapshot_counters",
            "snapshot_counters",
        ):
            for item in parsed["snapshots"]:
                if item["kind"] == preferred_kind:
                    candidate = item
                    break
            if candidate is not None:
                break
        if candidate is not None:
            comparison = {
                "profile": expected_profile,
                "target_kind": candidate["kind"],
                **compare_counters(candidate["counters"], expected),
            }

    host_preflight = next(
        (item for item in parsed["snapshots"] if item["kind"] == "host_counters"),
        None,
    )
    host_preflight_check = None
    if host_preflight is not None:
        host_preflight_check = compare_counters(
            host_preflight["counters"], EXPECTED_COUNTER_PROFILES["host_preflight"]
        )

    return {
        "project_stage": "strategy8 rowhandoff cocotb log parsing",
        "input_log": display_input_log,
        "rowhandoff_event_addr": hex(event_addr),
        "snapshot_count": len(parsed["snapshots"]),
        "scalar_event_count": len(parsed["scalar_events"]),
        "event_write_count": len(parsed["event_writes"]),
        "host_preflight_check": host_preflight_check,
        "expected_profile_check": comparison,
        "snapshots": parsed["snapshots"],
        "scalar_events": parsed["scalar_events"],
        "event_writes": parsed["event_writes"],
    }


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff cocotb 日志解析结果",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        f"- 输入日志：`{report['input_log']}`",
        f"- 事件地址：`{report['rowhandoff_event_addr']}`",
        f"- 计数快照条数：`{report['snapshot_count']}`",
        f"- 标量事件条数：`{report['scalar_event_count']}`",
        f"- 显式 `rowhandoff_event_write` 条数：`{report['event_write_count']}`",
        "",
        "## Host 预检",
        "",
    ]

    host_check = report["host_preflight_check"]
    if host_check is None:
        lines.append("- 日志里未发现 `host_counters=` 行。")
    else:
        lines.append(
            "- 结果：`{}`".format("PASS" if host_check["pass"] else "FAIL")
        )
        for mismatch in host_check["mismatches"]:
            lines.append(
                "- `{counter}` 期望 {expected}，实际 {actual}".format(**mismatch)
            )

    lines.extend(["", "## 目标 profile 对账", ""])
    profile_check = report["expected_profile_check"]
    if profile_check is None:
        lines.append("- 未执行 profile 对账，或日志里没有对应 workload/probe/poll 快照。")
    else:
        lines.append(
            "- profile：`{profile}`，目标快照：`{target_kind}`，结果：`{result}`".format(
                profile=profile_check["profile"],
                target_kind=profile_check["target_kind"],
                result="PASS" if profile_check["pass"] else "FAIL",
            )
        )
        for mismatch in profile_check["mismatches"]:
            lines.append(
                "- `{counter}` 期望 {expected}，实际 {actual}".format(**mismatch)
            )

    lines.extend(
        [
            "",
            "## 计数快照",
            "",
            "| 行号 | 类型 | 计数 |",
            "| --- | --- | --- |",
        ]
    )
    for item in report["snapshots"]:
        lines.append(
            "| {line_no} | `{kind}` | `{counters}` |".format(
                line_no=item["line_no"],
                kind=item["kind"],
                counters=item["counters"],
            )
        )

    lines.extend(
        [
            "",
            "## 标量事件",
            "",
            "| 行号 | 类型 | 值 |",
            "| --- | --- | ---: |",
        ]
    )
    for item in report["scalar_events"]:
        lines.append(
            "| {line_no} | `{kind}` | {value} |".format(
                line_no=item["line_no"],
                kind=item["kind"],
                value=item["value"],
            )
        )

    lines.extend(
        [
            "",
            "## 显式事件写",
            "",
            "| 行号 | cycle | addr | wdata | 是否命中事件口 | 备注 |",
            "| --- | ---: | --- | --- | --- | --- |",
        ]
    )
    for item in report["event_writes"]:
        lines.append(
            "| {line_no} | {cycle} | `{addr}` | `{wdata}` | {pulse} | {note} |".format(
                line_no=item["line_no"],
                cycle=item["cycle"] if item["cycle"] is not None else -1,
                addr=hex(item["addr"]),
                wdata=hex(item["wdata"]),
                pulse="Y" if item["event_write_pulse"] else "N",
                note=item["note"] or "-",
            )
        )

    lines.extend(
        [
            "",
            "## 当前结论",
            "",
            "- 当前脚本已经能直接消费现有 cocotb 的计数日志格式，不必再手工抄 `host_counters/workload_counters/poll_snapshot_counters`。",
            "- 如果后续 cocotb 只额外打印一行 `rowhandoff_event_write cycle=... addr=... wdata=... note=...`，项目侧就能直接导出给 `reconstruct_strategy8_rowhandoff_event_trace.py` 使用的 trace JSON。",
            "- 这样第二层主线从 cocotb 到项目报告之间，就只差最小日志打印，不差分析工具。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    input_log = Path(args.input_log).resolve()
    event_addr = parse_int(args.rowhandoff_event_addr)
    parsed = parse_log(load_lines(input_log), event_addr)
    report = build_report(parsed, input_log, args.expected_profile, event_addr)

    Path(args.out_json).write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(report, Path(args.out_md))

    if args.out_trace_json and parsed["event_writes"]:
        trace_payload = build_trace_json(parsed["event_writes"], input_log, event_addr)
        Path(args.out_trace_json).write_text(
            json.dumps(trace_payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
