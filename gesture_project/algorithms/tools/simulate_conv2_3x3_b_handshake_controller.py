"""conv2_3x3_b 4x8x8 握手级控制器仿真。

目标不是替代 RTL，而是在不改动已验证 conv.cc baseline 的前提下，
把当前 48x48 主体层控制流推进到 req/ready/done、资源占用、valid bit
和 stall 统计这一层，便于后续映射到模块端口和状态机实现。
"""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


STATE_TO_SIGNAL = {
    "S1_PRELOAD_WEIGHTS": "weight_preload_req",
    "S2_FILL_FIRST_TILE": "line_fill_req",
    "S3_LOAD_WEIGHT_GROUP": "weight_group_load_req",
    "S4_COMPUTE_ACC": "compute_req",
    "S5_QUANTIZE_WRITEBACK": "quant_write_req",
    "S7_WINDOW_SHIFT": "window_shift_req",
    "S8_ADVANCE_ROW": "row_advance_req",
    "S9_DONE": "done_pulse",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="输入 tile schedule JSON。")
    parser.add_argument("--strategy", choices=["reload", "row_resident"], default="reload")
    parser.add_argument("--input_bw", type=int, default=512, help="输入端口带宽，单位 B/cycle。")
    parser.add_argument("--weight_bw", type=int, default=512, help="weight 端口带宽，单位 B/cycle。")
    parser.add_argument("--output_bw", type=int, default=256, help="输出端口带宽，单位 B/cycle。")
    parser.add_argument(
        "--compute_cycles",
        type=int,
        default=32,
        help="单个 4x8x8 oc_group 的计算延迟，单位 cycle。",
    )
    parser.add_argument(
        "--local_weight_select_cycles",
        type=int,
        default=1,
        help="row-resident 策略下从本地 weight bank 选中当前 oc_group 的延迟。",
    )
    parser.add_argument(
        "--max_trace_cycles",
        type=int,
        default=240,
        help="最多保留多少个周期级 trace 片段。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def ceil_div(numer: int, denom: int) -> int:
    return int(math.ceil(numer / denom))


def op_latency(
    state: str,
    schedule: dict[str, Any],
    strategy: str,
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
) -> tuple[str, int, int]:
    if state == "S1_PRELOAD_WEIGHTS":
        bytes_ = int(schedule["weight_schedule"]["weights_per_spatial_site"])
        return ("weight_port", ceil_div(bytes_, weight_bw), bytes_)
    if state == "S2_FILL_FIRST_TILE":
        bytes_ = int(schedule["line_fill"]["first_spatial_site_bytes"])
        return ("input_port", ceil_div(bytes_, input_bw), bytes_)
    if state == "S3_LOAD_WEIGHT_GROUP":
        if strategy == "row_resident":
            return ("weight_bank", local_weight_select_cycles, 0)
        bytes_ = int(schedule["weight_schedule"]["weight_tile_bytes"])
        return ("weight_port", ceil_div(bytes_, weight_bw), bytes_)
    if state == "S4_COMPUTE_ACC":
        return ("compute_array", compute_cycles, 0)
    if state == "S5_QUANTIZE_WRITEBACK":
        bytes_ = int(schedule["writeback"]["tile_output_bytes"])
        return ("output_port", ceil_div(bytes_, output_bw), bytes_)
    if state == "S7_WINDOW_SHIFT":
        bytes_ = int(schedule["x_shift"]["new_bytes_per_shift"])
        return ("input_port", ceil_div(bytes_, input_bw), bytes_)
    if state == "S8_ADVANCE_ROW":
        bytes_ = int(schedule["y_advance"]["new_bytes_per_advance"])
        return ("input_port", ceil_div(bytes_, input_bw), bytes_)
    raise ValueError(f"Unexpected state for op latency: {state}")


def next_state_after_done(
    state: str,
    strategy: str,
    need_first_fill: bool,
    y: int,
    x: int,
    oc: int,
    tiles_y: int,
    tiles_x: int,
    tiles_oc: int,
) -> tuple[str, int, int, int]:
    if state == "S1_PRELOAD_WEIGHTS":
        return ("S2_FILL_FIRST_TILE" if need_first_fill else "S3_LOAD_WEIGHT_GROUP", y, x, oc)
    if state == "S2_FILL_FIRST_TILE":
        return ("S3_LOAD_WEIGHT_GROUP", y, x, oc)
    if state == "S3_LOAD_WEIGHT_GROUP":
        return ("S4_COMPUTE_ACC", y, x, oc)
    if state == "S4_COMPUTE_ACC":
        return ("S5_QUANTIZE_WRITEBACK", y, x, oc)
    if state == "S5_QUANTIZE_WRITEBACK":
        return ("S6_NEXT_OC_OR_SHIFT", y, x, oc)
    if state == "S7_WINDOW_SHIFT":
        return ("S3_LOAD_WEIGHT_GROUP", y, x, oc)
    if state == "S8_ADVANCE_ROW":
        if strategy == "row_resident":
            return ("S1_PRELOAD_WEIGHTS", y, x, oc)
        return ("S3_LOAD_WEIGHT_GROUP", y, x, oc)
    if state == "S9_DONE":
        return ("S0_IDLE", y, x, oc)
    if state != "S6_NEXT_OC_OR_SHIFT":
        raise ValueError(f"Unexpected completed state: {state}")

    if oc < tiles_oc - 1:
        return ("S3_LOAD_WEIGHT_GROUP", y, x, oc + 1)
    if x < tiles_x - 1:
        return ("S7_WINDOW_SHIFT", y, x + 1, 0)
    if y < tiles_y - 1:
        return ("S8_ADVANCE_ROW", y + 1, 0, 0)
    return ("S9_DONE", y, x, oc)


def initialize_valids(strategy: str) -> dict[str, bool]:
    return {
        "line_buffer_valid": False,
        "window_valid": False,
        "weight_row_valid": strategy == "reload",
        "weight_group_valid": False,
        "acc_valid": False,
        "output_valid": False,
    }


def dependency_ready(state: str, valids: dict[str, bool], strategy: str) -> tuple[bool, str]:
    if state == "S4_COMPUTE_ACC":
        if not valids["window_valid"]:
            return (False, "window_invalid")
        if strategy == "row_resident" and not valids["weight_row_valid"]:
            return (False, "weight_row_invalid")
        if not valids["weight_group_valid"]:
            return (False, "weight_group_invalid")
    elif state == "S5_QUANTIZE_WRITEBACK":
        if not valids["acc_valid"]:
            return (False, "acc_invalid")
    return (True, "deps_ready")


def update_valids_after_done(state: str, valids: dict[str, bool], strategy: str) -> None:
    if state == "S1_PRELOAD_WEIGHTS":
        valids["weight_row_valid"] = True
        valids["weight_group_valid"] = False
    elif state == "S2_FILL_FIRST_TILE":
        valids["line_buffer_valid"] = True
        valids["window_valid"] = True
        valids["weight_group_valid"] = False
        valids["acc_valid"] = False
    elif state == "S3_LOAD_WEIGHT_GROUP":
        valids["weight_group_valid"] = True
    elif state == "S4_COMPUTE_ACC":
        valids["acc_valid"] = True
    elif state == "S5_QUANTIZE_WRITEBACK":
        valids["acc_valid"] = False
        valids["output_valid"] = True
        if strategy == "reload":
            valids["weight_group_valid"] = False
    elif state == "S7_WINDOW_SHIFT":
        valids["window_valid"] = True
        valids["weight_group_valid"] = False
        valids["acc_valid"] = False
    elif state == "S8_ADVANCE_ROW":
        valids["line_buffer_valid"] = True
        valids["window_valid"] = True
        valids["weight_group_valid"] = False
        valids["acc_valid"] = False
        if strategy == "row_resident":
            valids["weight_row_valid"] = False


def build_comparison(summary_reload: dict[str, Any], summary_row_resident: dict[str, Any]) -> dict[str, Any]:
    reload_total = int(summary_reload["total_cycles"])
    resident_total = int(summary_row_resident["total_cycles"])
    reload_weight = int(summary_reload["bytes_summary"]["weight_bytes"])
    resident_weight = int(summary_row_resident["bytes_summary"]["weight_bytes"])
    return {
        "total_cycle_delta": resident_total - reload_total,
        "total_cycle_ratio": round(resident_total / reload_total, 4),
        "weight_byte_delta": resident_weight - reload_weight,
        "weight_byte_ratio": round(resident_weight / reload_weight, 4),
    }


def run_simulation(
    schedule: dict[str, Any],
    strategy: str,
    input_bw: int,
    weight_bw: int,
    output_bw: int,
    compute_cycles: int,
    local_weight_select_cycles: int,
    max_trace_cycles: int,
) -> dict[str, Any]:
    tiles_y = int(schedule["grid"]["tiles_y"])
    tiles_x = int(schedule["grid"]["tiles_x"])
    tiles_oc = int(schedule["grid"]["tiles_oc"])

    state = "S1_PRELOAD_WEIGHTS" if strategy == "row_resident" else "S2_FILL_FIRST_TILE"
    y = 0
    x = 0
    oc = 0
    cycle = 0
    valids = initialize_valids(strategy)
    need_first_fill = strategy == "row_resident"

    inflight: dict[str, Any] | None = None
    state_cycles: Counter[str] = Counter()
    op_counts: Counter[str] = Counter()
    stall_cycles: Counter[str] = Counter()
    wait_cycles_by_state: Counter[str] = Counter()
    resource_busy_cycles: Counter[str] = Counter()
    bytes_summary = {"input_bytes": 0, "weight_bytes": 0, "output_bytes": 0}
    operation_cycles: Counter[str] = Counter()
    transitions: Counter[str] = Counter()
    trace: list[dict[str, Any]] = []

    while True:
        if inflight is not None and cycle >= int(inflight["done_cycle"]):
            completed_state = str(inflight["state"])
            completed_resource = str(inflight["resource"])
            operation_cycles[completed_state] += int(inflight["latency"])
            update_valids_after_done(completed_state, valids, strategy)
            if completed_state == "S2_FILL_FIRST_TILE":
                need_first_fill = False
            state, y, x, oc = next_state_after_done(
                completed_state,
                strategy,
                need_first_fill,
                y,
                x,
                oc,
                tiles_y,
                tiles_x,
                tiles_oc,
            )
            transitions[f"{completed_state}->{state}"] += 1
            inflight = None
            if completed_state == "S9_DONE":
                break

        state_cycles[state] += 1

        req_signal = STATE_TO_SIGNAL.get(state)
        deps_ok, dep_reason = dependency_ready(state, valids, strategy)
        ready = False
        grant = False
        done = False
        resource = "-"
        latency = 0
        bytes_ = 0
        wait_reason = ""

        if state == "S0_IDLE":
            done = True
        elif state == "S6_NEXT_OC_OR_SHIFT":
            next_state, next_y, next_x, next_oc = next_state_after_done(
                state,
                strategy,
                need_first_fill,
                y,
                x,
                oc,
                tiles_y,
                tiles_x,
                tiles_oc,
            )
            transitions[f"S6_NEXT_OC_OR_SHIFT->{next_state}"] += 1
            state, y, x, oc = next_state, next_y, next_x, next_oc
            done = True
        elif state == "S9_DONE":
            req_signal = "done_pulse"
            done = True
            inflight = {
                "state": "S9_DONE",
                "resource": "control",
                "latency": 1,
                "done_cycle": cycle + 1,
            }
        else:
            resource, latency, bytes_ = op_latency(
                state,
                schedule,
                strategy,
                input_bw,
                weight_bw,
                output_bw,
                compute_cycles,
                local_weight_select_cycles,
            )
            ready = inflight is None and deps_ok
            if ready:
                grant = True
                inflight = {
                    "state": state,
                    "resource": resource,
                    "latency": latency,
                    "done_cycle": cycle + latency,
                }
                op_counts[state] += 1
                if resource in {"input_port", "weight_port", "output_port"}:
                    if resource == "input_port":
                        bytes_summary["input_bytes"] += bytes_
                    elif resource == "weight_port":
                        bytes_summary["weight_bytes"] += bytes_
                    else:
                        bytes_summary["output_bytes"] += bytes_
            else:
                wait_cycles_by_state[state] += 1
                wait_reason = dep_reason if not deps_ok else "resource_busy"
                stall_cycles[wait_reason] += 1

        if inflight is not None:
            resource_busy_cycles[str(inflight["resource"])] += 1

        if len(trace) < max_trace_cycles:
            trace.append(
                {
                    "cycle": cycle,
                    "state": state,
                    "out_y_tile": y,
                    "out_x_tile": x,
                    "oc_group": oc,
                    "req": req_signal or "-",
                    "ready": ready,
                    "grant": grant,
                    "done": done,
                    "resource": resource,
                    "latency": latency,
                    "bytes": bytes_,
                    "wait_reason": wait_reason or "-",
                    "valids": {
                        "line_buffer_valid": valids["line_buffer_valid"],
                        "window_valid": valids["window_valid"],
                        "weight_row_valid": valids["weight_row_valid"],
                        "weight_group_valid": valids["weight_group_valid"],
                        "acc_valid": valids["acc_valid"],
                    },
                }
            )

        cycle += 1

    return {
        "strategy": strategy,
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "config": schedule["config"],
        "grid": schedule["grid"],
        "resource_model": {
            "input_bw_bytes_per_cycle": input_bw,
            "weight_bw_bytes_per_cycle": weight_bw,
            "output_bw_bytes_per_cycle": output_bw,
            "compute_cycles_per_oc_group": compute_cycles,
            "local_weight_select_cycles": local_weight_select_cycles,
        },
        "summary": {
            "total_cycles": cycle,
            "state_cycles": dict(state_cycles),
            "op_counts": dict(op_counts),
            "wait_cycles_by_state": dict(wait_cycles_by_state),
            "stall_cycles_by_reason": dict(stall_cycles),
            "resource_busy_cycles": dict(resource_busy_cycles),
            "operation_cycles": dict(operation_cycles),
            "bytes_summary": bytes_summary,
            "transition_counts": dict(transitions),
        },
        "trace_cycle_count": len(trace),
        "trace_truncated": len(trace) >= max_trace_cycles,
        "trace": trace,
    }


def write_compare_markdown(
    reload_report: dict[str, Any],
    row_resident_report: dict[str, Any],
    out_path: Path,
) -> None:
    reload_summary = reload_report["summary"]
    resident_summary = row_resident_report["summary"]
    comparison = build_comparison(reload_summary, resident_summary)
    lines = [
        "# conv2_3x3_b 4x8x8 握手级策略对比",
        "",
        "- 在相同资源约束下比较 `reload` 与 `row_resident` 两种控制策略。",
        "",
        "## 总览",
        "",
        "| 指标 | reload | row_resident | 比值/差值 |",
        "| --- | ---: | ---: | ---: |",
        "| total cycles | {r_cycles:,} | {rr_cycles:,} | {ratio:.4f}x |".format(
            r_cycles=reload_summary["total_cycles"],
            rr_cycles=resident_summary["total_cycles"],
            ratio=comparison["total_cycle_ratio"],
        ),
        "| input bytes | {r_input:,} | {rr_input:,} | {ratio:.4f}x |".format(
            r_input=reload_summary["bytes_summary"]["input_bytes"],
            rr_input=resident_summary["bytes_summary"]["input_bytes"],
            ratio=resident_summary["bytes_summary"]["input_bytes"] / reload_summary["bytes_summary"]["input_bytes"],
        ),
        "| weight bytes | {r_weight:,} | {rr_weight:,} | {ratio:.4f}x |".format(
            r_weight=reload_summary["bytes_summary"]["weight_bytes"],
            rr_weight=resident_summary["bytes_summary"]["weight_bytes"],
            ratio=comparison["weight_byte_ratio"],
        ),
        "| output bytes | {r_output:,} | {rr_output:,} | 1.0000x |".format(
            r_output=reload_summary["bytes_summary"]["output_bytes"],
            rr_output=resident_summary["bytes_summary"]["output_bytes"],
        ),
        "",
        "## 关键观察",
        "",
        f"- `row_resident` 总周期相对 `reload` 变化：`{comparison['total_cycle_delta']:+,}` cycle。",
        f"- `row_resident` 的 weight 流量相对 `reload` 变化：`{comparison['weight_byte_delta']:+,} B`。",
        f"- 两者的主热点都仍然是 `S4_COMPUTE_ACC`，说明当前资源模型下主阵列计算时长仍是绝对主导项。",
        "",
        "## 资源忙周期",
        "",
        "| 资源 | reload | row_resident |",
        "| --- | ---: | ---: |",
    ]

    resources = sorted(
        set(reload_summary["resource_busy_cycles"].keys()) | set(resident_summary["resource_busy_cycles"].keys())
    )
    for resource in resources:
        lines.append(
            "| `{resource}` | {r_busy:,} | {rr_busy:,} |".format(
                resource=resource,
                r_busy=reload_summary["resource_busy_cycles"].get(resource, 0),
                rr_busy=resident_summary["resource_busy_cycles"].get(resource, 0),
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    summary = report["summary"]
    lines = [
        "# conv2_3x3_b 4x8x8 握手级控制器仿真",
        "",
        f"- 策略：`{report['strategy']}`",
        f"- 总周期：`{summary['total_cycles']}`",
        f"- 轨迹采样周期数：`{report['trace_cycle_count']}`",
        f"- 轨迹是否截断：`{report['trace_truncated']}`",
        "",
        "## 资源模型",
        "",
        f"- 输入端口带宽：`{report['resource_model']['input_bw_bytes_per_cycle']} B/cycle`",
        f"- Weight 端口带宽：`{report['resource_model']['weight_bw_bytes_per_cycle']} B/cycle`",
        f"- 输出端口带宽：`{report['resource_model']['output_bw_bytes_per_cycle']} B/cycle`",
        f"- 单个 oc_group 计算延迟：`{report['resource_model']['compute_cycles_per_oc_group']} cycle`",
        f"- row-resident 本地 weight 选通延迟：`{report['resource_model']['local_weight_select_cycles']} cycle`",
        "",
        "## 字节摘要",
        "",
        f"- 输入流量：`{summary['bytes_summary']['input_bytes']:,} B`",
        f"- Weight 流量：`{summary['bytes_summary']['weight_bytes']:,} B`",
        f"- 输出流量：`{summary['bytes_summary']['output_bytes']:,} B`",
        "",
        "## 资源忙周期",
        "",
        "| 资源 | busy cycles |",
        "| --- | ---: |",
    ]

    for resource, busy in sorted(summary["resource_busy_cycles"].items()):
        lines.append(f"| `{resource}` | {busy:,} |")

    lines.extend(
        [
            "",
            "## 状态驻留周期",
            "",
            "| 状态 | cycles | 发起次数 | 等待周期 |",
            "| --- | ---: | ---: | ---: |",
        ]
    )

    for state, cycles in sorted(summary["state_cycles"].items()):
        lines.append(
            "| `{state}` | {cycles:,} | {count:,} | {wait:,} |".format(
                state=state,
                cycles=cycles,
                count=summary["op_counts"].get(state, 0),
                wait=summary["wait_cycles_by_state"].get(state, 0),
            )
        )

    lines.extend(
        [
            "",
            "## Stall 原因",
            "",
            "| 原因 | cycles |",
            "| --- | ---: |",
        ]
    )

    if summary["stall_cycles_by_reason"]:
        for reason, cycles in sorted(summary["stall_cycles_by_reason"].items()):
            lines.append(f"| `{reason}` | {cycles:,} |")
    else:
        lines.append("| `-` | 0 |")

    lines.extend(
        [
            "",
            "## 周期级 Trace 片段",
            "",
            "| cycle | state | y | x | oc | req | ready | grant | done | resource | latency | bytes | wait | valids |",
            "| ---: | --- | ---: | ---: | ---: | --- | --- | --- | --- | --- | ---: | ---: | --- | --- |",
        ]
    )

    for item in report["trace"]:
        valid_bits = ",".join(
            [
                f"lb={int(item['valids']['line_buffer_valid'])}",
                f"win={int(item['valids']['window_valid'])}",
                f"wr={int(item['valids']['weight_row_valid'])}",
                f"wg={int(item['valids']['weight_group_valid'])}",
                f"acc={int(item['valids']['acc_valid'])}",
            ]
        )
        lines.append(
            "| {cycle} | `{state}` | {out_y_tile} | {out_x_tile} | {oc_group} | `{req}` | {ready} | {grant} | {done} | `{resource}` | {latency} | {bytes} | `{wait_reason}` | `{valid_bits}` |".format(
                **item,
                valid_bits=valid_bits,
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    report = run_simulation(
        schedule=schedule,
        strategy=args.strategy,
        input_bw=args.input_bw,
        weight_bw=args.weight_bw,
        output_bw=args.output_bw,
        compute_cycles=args.compute_cycles,
        local_weight_select_cycles=args.local_weight_select_cycles,
        max_trace_cycles=args.max_trace_cycles,
    )

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
