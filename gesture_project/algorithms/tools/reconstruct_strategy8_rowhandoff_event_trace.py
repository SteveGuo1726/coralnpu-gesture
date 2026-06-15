"""从 rowhandoff 边界事件写流重建 source-style row 生命周期状态。"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INPUT_JSON = (
    PROJECT_ROOT
    / "reports"
    / "core_3x3_strategy8_rowhandoff_boundary_event_trace_sample_2026-06-11.json"
)
DEFAULT_EVENT_ADDR = 0x30840
ROWHANDOFF_EVENT_OFFSET_MASK = 0xFFF

EVENT_BITS = (
    ("layer_start", 0),
    ("hit", 1),
    ("tail_hit", 2),
    ("miss", 3),
    ("invalidate", 4),
    ("produce", 5),
    ("interior_row_enter", 6),
    ("right_edge_done", 7),
    ("row_out_y_write", 8),
)


@dataclass
class TrackerState:
    row_gate_active: bool = False
    current_row_index: int = 0
    rowhandoff_valid_state: bool = False
    consume_decision_valid: bool = False
    consume_decision_hit: bool = False
    tail_hit_seen: bool = False
    last_produced_row: int = 0
    last_invalidated_row: int = 0

    def snapshot(
        self,
        *,
        row_enter_pulse: bool,
        row_terminal_done_pulse: bool,
        row_advance_done_pulse: bool,
    ) -> dict[str, Any]:
        payload = asdict(self)
        payload["row_enter_pulse"] = row_enter_pulse
        payload["row_terminal_done_pulse"] = row_terminal_done_pulse
        payload["row_advance_done_pulse"] = row_advance_done_pulse
        return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input_json",
        default=str(DEFAULT_INPUT_JSON),
        help="输入的边界写流 JSON。",
    )
    parser.add_argument(
        "--rowhandoff_event_addr",
        default=hex(DEFAULT_EVENT_ADDR),
        help="rowhandoff 事件写地址，支持十进制或十六进制。",
    )
    parser.add_argument("--out_json", required=True, help="输出重建 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown 报告。")
    return parser.parse_args()


def parse_int(value: Any) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise TypeError(f"Unsupported int value: {value!r}")


def addr_matches_event_addr(addr: int, event_addr: int) -> bool:
    return addr == event_addr or (
        (addr & ROWHANDOFF_EVENT_OFFSET_MASK)
        == (event_addr & ROWHANDOFF_EVENT_OFFSET_MASK)
    )


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def decode_event_bits(word: int) -> dict[str, bool]:
    return {name: bool(word & (1 << bit)) for name, bit in EVENT_BITS}


def decode_row_out_y(word: int) -> int:
    return (word >> 16) & 0x3F


def event_names(bits: dict[str, bool]) -> list[str]:
    return [name for name, enabled in bits.items() if enabled]


def event_write_pulse(sample: dict[str, Any], event_addr: int) -> bool:
    return (
        bool(sample.get("valid", False))
        and bool(sample.get("internal", False))
        and bool(sample.get("write", False))
        and addr_matches_event_addr(parse_int(sample.get("addr", 0)), event_addr)
    )


def apply_event(state: TrackerState, bits: dict[str, bool], row_out_y: int) -> dict[str, Any]:
    row_enter_pulse = bits["interior_row_enter"]
    row_terminal_done_pulse = bits["right_edge_done"]
    row_advance_done_pulse = bits["invalidate"]

    if bits["layer_start"]:
        state.row_gate_active = False
        state.current_row_index = 0
        state.rowhandoff_valid_state = False
        state.consume_decision_valid = False
        state.consume_decision_hit = False
        state.tail_hit_seen = False
        state.last_produced_row = 0
        state.last_invalidated_row = 0
    else:
        if bits["interior_row_enter"]:
            state.row_gate_active = True
            state.current_row_index = row_out_y
            state.consume_decision_valid = False
            state.tail_hit_seen = False
        if bits["hit"]:
            state.current_row_index = row_out_y
            state.consume_decision_valid = True
            state.consume_decision_hit = True
        if bits["miss"]:
            state.current_row_index = row_out_y
            state.consume_decision_valid = True
            state.consume_decision_hit = False
        if bits["tail_hit"]:
            state.current_row_index = row_out_y
            state.tail_hit_seen = True
        if bits["right_edge_done"]:
            state.current_row_index = row_out_y
            state.row_gate_active = False
        if bits["produce"]:
            state.current_row_index = row_out_y
            state.rowhandoff_valid_state = True
            state.last_produced_row = row_out_y
            state.row_gate_active = False
        if bits["invalidate"]:
            state.current_row_index = row_out_y
            state.rowhandoff_valid_state = False
            state.last_invalidated_row = row_out_y
            state.row_gate_active = False

    return state.snapshot(
        row_enter_pulse=row_enter_pulse,
        row_terminal_done_pulse=row_terminal_done_pulse,
        row_advance_done_pulse=row_advance_done_pulse,
    )


def build_summary(accepted_events: list[dict[str, Any]]) -> dict[str, Any]:
    counters = {
        "layer_start": 0,
        "interior_row_enter": 0,
        "hit": 0,
        "tail_hit": 0,
        "miss": 0,
        "right_edge_done": 0,
        "produce": 0,
        "invalidate": 0,
        "row_out_y_write": 0,
    }
    produced_rows: list[int] = []
    invalidated_rows: list[int] = []

    for item in accepted_events:
        bits = item["decoded_bits"]
        for name in counters:
            counters[name] += int(bits[name])
        if bits["produce"]:
            produced_rows.append(item["row_out_y"])
        if bits["invalidate"]:
            invalidated_rows.append(item["row_out_y"])

    return {
        "accepted_event_count": len(accepted_events),
        "counters": counters,
        "produced_rows": produced_rows,
        "invalidated_rows": invalidated_rows,
        "consistency_checks": {
            "produce_ge_invalidate": counters["produce"] >= counters["invalidate"],
            "right_edge_done_le_produce": counters["right_edge_done"] <= counters["produce"],
            "tail_hit_le_hit_plus_miss": counters["tail_hit"] <= (counters["hit"] + counters["miss"]),
        },
        "last_trace_state": accepted_events[-1]["state_after"] if accepted_events else None,
    }


def reconstruct(payload: dict[str, Any], event_addr: int) -> dict[str, Any]:
    state = TrackerState()
    samples = payload["samples"]
    accepted_events: list[dict[str, Any]] = []
    ignored_samples: list[dict[str, Any]] = []

    for index, sample in enumerate(samples):
        pulse = event_write_pulse(sample, event_addr)
        base = {
            "sample_index": index,
            "cycle": sample.get("cycle"),
            "note": sample.get("note"),
            "addr": hex(parse_int(sample.get("addr", 0))),
            "event_write_pulse": pulse,
        }
        if not pulse:
            ignored_samples.append(base)
            continue

        word = parse_int(sample["wdata"])
        bits = decode_event_bits(word)
        row_out_y = decode_row_out_y(word)
        accepted_events.append(
            {
                **base,
                "wdata": hex(word),
                "row_out_y": row_out_y,
                "decoded_bits": bits,
                "decoded_event_names": event_names(bits),
                "state_after": apply_event(state, bits, row_out_y),
            }
        )

    return {
        "project_stage": "strategy8 rowhandoff boundary event trace reconstruction",
        "input_json": payload.get("input_json"),
        "rowhandoff_event_addr": hex(event_addr),
        "sample_count": len(samples),
        "accepted_events": accepted_events,
        "ignored_samples": ignored_samples,
        "summary": build_summary(accepted_events),
    }


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    summary = report["summary"]
    lines = [
        "# strategy8 rowhandoff 边界事件流重建结果",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        f"- 输入样例：`{report['input_json']}`",
        f"- 事件地址：`{report['rowhandoff_event_addr']}`",
        f"- 样本总数：`{report['sample_count']}`",
        f"- 被识别为 rowhandoff event write 的条数：`{summary['accepted_event_count']}`",
        "",
        "## 计数汇总",
        "",
        "| 事件 | 次数 |",
        "| --- | ---: |",
    ]

    for name, count in summary["counters"].items():
        lines.append(f"| `{name}` | {count} |")

    lines.extend(
        [
            "",
            "## 一致性检查",
            "",
            "| 检查项 | 结果 | 说明 |",
            "| --- | --- | --- |",
            "| `produce >= invalidate` | {a} | 失效不应多于已生成的有效 rowhandoff state。 |".format(
                a="PASS" if summary["consistency_checks"]["produce_ge_invalidate"] else "FAIL"
            ),
            "| `right_edge_done <= produce` | {a} | 一般 `produce` 不应少于显式 row terminal 收口次数。 |".format(
                a="PASS" if summary["consistency_checks"]["right_edge_done_le_produce"] else "FAIL"
            ),
            "| `tail_hit <= hit + miss` | {a} | tail_hit 只能附着在已进入 consume 判定的 row 上。 |".format(
                a="PASS" if summary["consistency_checks"]["tail_hit_le_hit_plus_miss"] else "FAIL"
            ),
        ]
    )

    lines.extend(
        [
            "",
            "## 接受的事件流",
            "",
            "| idx | cycle | row_out_y | 事件 | 状态摘要 | 备注 |",
            "| --- | ---: | ---: | --- | --- | --- |",
        ]
    )

    for item in report["accepted_events"]:
        trace = item["state_after"]
        if trace["consume_decision_valid"]:
            consume_brief = f"({int(trace['consume_decision_valid'])},{int(trace['consume_decision_hit'])})"
        else:
            consume_brief = "(0,-)"
        state_brief = (
            f"gate={int(trace['row_gate_active'])}, "
            f"cur={trace['current_row_index']}, "
            f"valid={int(trace['rowhandoff_valid_state'])}, "
            f"consume={consume_brief}, "
            f"tail={int(trace['tail_hit_seen'])}, "
            f"prod={trace['last_produced_row']}, "
            f"inv={trace['last_invalidated_row']}"
        )
        lines.append(
            "| {idx} | {cycle} | {row} | `{events}` | `{state}` | {note} |".format(
                idx=item["sample_index"],
                cycle=item["cycle"] if item["cycle"] is not None else "-",
                row=item["row_out_y"],
                events=",".join(item["decoded_event_names"]) or "-",
                state=state_brief,
                note=item["note"] or "-",
            )
        )

    lines.extend(
        [
            "",
            "## 被忽略的边界写样本",
            "",
            "- 这些样本不满足 `valid && internal && write && addr==rowhandoff_event_addr`，因此不会被当成 rowhandoff 事件流的一部分。",
        ]
    )

    for item in report["ignored_samples"]:
        lines.append(
            "- idx={idx}, cycle={cycle}, addr={addr}, note={note}".format(
                idx=item["sample_index"],
                cycle=item["cycle"] if item["cycle"] is not None else "-",
                addr=item["addr"],
                note=item["note"] or "-",
            )
        )

    lines.extend(
        [
            "",
            "## 当前结论",
            "",
            "- 只要边界上能抓到 `valid/internal/write/addr/wdata`，就能在项目侧离线恢复一版 source-style row 生命周期。",
            "- 当前恢复语义与 `RowhandoffEventStreamTracker` 一致，可直接用于 cocotb 日志、板上 MMIO 记录或回放对账。",
            "- `consumeDecisionHit` 只有在 `consumeDecisionValid=1` 时才有意义；当新一条 row 刚 `interior_row_enter`、但尚未 hit/miss 判定时，不应单独解读这个位。",
            "- 这条链当前更适合先做“事件与状态对账”，而不是替代所有更深层内部时序观测。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    input_json = Path(args.input_json).resolve()
    payload = load_json(input_json)
    try:
        payload["input_json"] = str(input_json.relative_to(PROJECT_ROOT.parent))
    except ValueError:
        payload["input_json"] = str(input_json)
    report = reconstruct(payload, parse_int(args.rowhandoff_event_addr))
    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(report, out_md)


if __name__ == "__main__":
    main()
