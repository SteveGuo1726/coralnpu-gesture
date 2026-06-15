"""导出 rowhandoff mode=1 的板级 counter/CSR 契约与单层对账清单。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
TRACE_COUNTERS_JSON = PROJECT_ROOT / "reports" / "core_3x3_strategy8_rowhandoff_trace_counters.json"
CONV2_HANDSHAKE_COMPARE_JSON = PROJECT_ROOT / "reports" / "conv2_3x3_b_handshake_compare.json"
CONV3_HANDSHAKE_COMPARE_JSON = PROJECT_ROOT / "reports" / "conv3_3x3_b_handshake_compare.json"
CORE_CASES_JSON = PROJECT_ROOT / "configs" / "static_cnn_i96_core_3x3.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--trace_counters_json",
        default=str(TRACE_COUNTERS_JSON),
        help="rowhandoff trace/counter 量化 JSON。",
    )
    parser.add_argument(
        "--conv2_handshake_compare_json",
        default=str(CONV2_HANDSHAKE_COMPARE_JSON),
        help="conv2_3x3_b reload vs row_resident 对照 JSON。",
    )
    parser.add_argument(
        "--conv3_handshake_compare_json",
        default=str(CONV3_HANDSHAKE_COMPARE_JSON),
        help="conv3_3x3_b reload vs row_resident 对照 JSON。",
    )
    parser.add_argument(
        "--cases_json",
        default=str(CORE_CASES_JSON),
        help="核心 3x3 层配置 JSON。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def find_experiment(payload: dict[str, Any], name: str) -> dict[str, Any]:
    for item in payload["experiments"]:
        if item["name"] == name:
            return item
    raise KeyError(f"Experiment not found: {name}")


def case_map(cases_payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["layer_name"]: item for item in cases_payload["cases"]}


def build_counter_contract(mode1: dict[str, Any], backhalf: dict[str, Any]) -> list[dict[str, Any]]:
    full_ctr = mode1["row_window"]["expected_counters"]
    backhalf_ctr = backhalf["row_window"]["expected_counters"]
    mode1_b = mode1["layers"]["conv2_3x3_b"]
    backhalf_b = backhalf["layers"]["conv2_3x3_b"]

    return [
        {
            "name": "rowhandoff_hit_count",
            "width_bits": 16,
            "type": "counter",
            "description": "命中连续 next-row base state 的总次数。",
            "expected_mode1_full": int(full_ctr["hit_count"]),
            "expected_mode1_backhalf": int(backhalf_ctr["hit_count"]),
            "why": "板级第一优先计数，直接对应 mode=1 主线的 consume 次数。",
        },
        {
            "name": "rowhandoff_miss_count",
            "width_bits": 16,
            "type": "counter",
            "description": "进入 gate 但没有可复用 handoff state 的次数。",
            "expected_mode1_full": int(full_ctr["miss_count"]),
            "expected_mode1_backhalf": int(backhalf_ctr["miss_count"]),
            "why": "用于确认第一条生效 row 是否按预期先 miss 一次。",
        },
        {
            "name": "rowhandoff_invalidate_count",
            "width_bits": 16,
            "type": "counter",
            "description": "离开生效窗口、离开 interior 或层切换时丢弃 state 的次数。",
            "expected_mode1_full": int(full_ctr["invalidate_count"]),
            "expected_mode1_backhalf": int(backhalf_ctr["invalidate_count"]),
            "why": "用于确认 row window 尾部失效是否按预期只发生一次。",
        },
        {
            "name": "rowhandoff_produce_count",
            "width_bits": 16,
            "type": "counter",
            "description": "行尾生成下一条 row base state 的次数。",
            "expected_mode1_full": int(full_ctr["produce_count"]),
            "expected_mode1_backhalf": int(backhalf_ctr["produce_count"]),
            "why": "用于对齐每条生效 row 是否都在 right-edge 之后 produce。",
        },
        {
            "name": "rowhandoff_tail_hit_count",
            "width_bits": 16,
            "type": "counter",
            "description": "后段 row bucket 的命中次数，建议对 out_y>=24 或更后段单独分桶。",
            "expected_mode1_full": int(backhalf_ctr["hit_count"]),
            "expected_mode1_backhalf": int(backhalf_ctr["hit_count"]),
            "why": (
                "trace/counter 量化已经证明后段 row 的单次命中价值更高："
                f"mode1_full gain/hit={mode1_b['gain_per_hit']:.2f}, "
                f"backhalf gain/hit={backhalf_b['gain_per_hit']:.2f}。"
            ),
        },
        {
            "name": "interior_row_enter_count",
            "width_bits": 16,
            "type": "counter",
            "description": "进入目标 interior row gate 的次数。",
            "expected_mode1_full": int(mode1["row_window"]["active_row_count"]),
            "expected_mode1_backhalf": int(backhalf["row_window"]["active_row_count"]),
            "why": "用于与 produce/miss/hit 做简单守恒检查。",
        },
        {
            "name": "right_edge_done_count",
            "width_bits": 16,
            "type": "counter",
            "description": "完成 right-edge 并到达 row terminal 的次数。",
            "expected_mode1_full": int(mode1["row_window"]["active_row_count"]),
            "expected_mode1_backhalf": int(backhalf["row_window"]["active_row_count"]),
            "why": "这是 produce 条件的板级锚点，应该与 produce_count 对齐。",
        },
        {
            "name": "rowhandoff_row_out_y_last",
            "width_bits": 6,
            "type": "snapshot",
            "description": "最后一次 produce 的 row_out_y 快照。",
            "expected_mode1_full": 46,
            "expected_mode1_backhalf": 45,
            "why": "帮助确认最终有效 row window 是否落在预期末端。",
        },
    ]


def build_layer_expectation(
    case: dict[str, Any],
    mode1: dict[str, Any],
    handshake: dict[str, Any] | None,
) -> dict[str, Any]:
    out_h = int(case["out_h"])
    out_w = int(case["out_w"])
    in_d = int(case["in_d"])
    out_d = int(case["out_d"])
    layer_name = case["layer_name"]

    if layer_name == "conv2_3x3_b":
        cycle_gain = int(mode1["layers"]["conv2_3x3_b"]["cycle_gain"])
        gain_per_hit = float(mode1["layers"]["conv2_3x3_b"]["gain_per_hit"])
    else:
        cycle_gain = None
        gain_per_hit = None

    if handshake is not None:
        handshake_row = int(handshake["row_resident"]["total_cycles"])
        handshake_reload = int(handshake["reload"]["total_cycles"])
    else:
        handshake_row = None
        handshake_reload = None

    return {
        "layer_name": layer_name,
        "shape": f"{out_h}x{out_w}x{in_d} -> 3x3 -> {out_h}x{out_w}x{out_d}",
        "gate_assumption": "output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode"
        if layer_name == "conv2_3x3_b"
        else "rowhandoff 板级复用验证的第二优先对照层",
        "board_run_priority": 1 if layer_name == "conv2_3x3_b" else 2,
        "expected_mode1_cycle_gain_vs_emptyhooks": cycle_gain,
        "expected_mode1_gain_per_hit": gain_per_hit,
        "handshake_row_resident_cycles": handshake_row,
        "handshake_reload_cycles": handshake_reload,
    }


def build_contract_report(
    trace_payload: dict[str, Any],
    conv2_handshake_payload: dict[str, Any],
    conv3_handshake_payload: dict[str, Any],
    cases_payload: dict[str, Any],
) -> dict[str, Any]:
    mode1 = find_experiment(trace_payload, "mode1_full")
    backhalf = find_experiment(trace_payload, "mode1_backhalf")
    cases = case_map(cases_payload)

    layers = [
        build_layer_expectation(cases["conv2_3x3_b"], mode1, conv2_handshake_payload),
        build_layer_expectation(cases["conv3_3x3_b"], mode1, conv3_handshake_payload),
    ]

    return {
        "project_stage": "strategy8 rowhandoff mode=1 board trace/counter first closure",
        "reference_reports": {
            "trace_counters": str(Path(trace_payload["cases_json"]).relative_to(PROJECT_ROOT.parent))
            if str(trace_payload.get("cases_json", "")).startswith(str(PROJECT_ROOT.parent))
            else str(TRACE_COUNTERS_JSON.relative_to(PROJECT_ROOT)),
            "mode1_vs_emptyhooks": "gesture_project/reports/core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_vs_emptyhooks_48x48.md",
            "backhalf_vs_emptyhooks": "gesture_project/reports/core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode1_backhalf_vs_emptyhooks_48x48.md",
            "conv2_handshake_compare": "gesture_project/reports/conv2_3x3_b_handshake_compare.json",
            "conv3_handshake_compare": "gesture_project/reports/conv3_3x3_b_handshake_compare.json",
        },
        "counter_contract": build_counter_contract(mode1, backhalf),
        "layers": layers,
        "board_sequence": [
            {
                "step": 1,
                "name": "trace_counter_only_conv2_3x3_b",
                "goal": "先不改 datapath，只确认 mode1_full 的计数是否接近 46/45/1/1。",
            },
            {
                "step": 2,
                "name": "tail_bucket_check_conv2_3x3_b",
                "goal": "确认后段 row bucket 是否能显著区分 mode1_full 与 backhalf。",
            },
            {
                "step": 3,
                "name": "sanity_check_conv3_3x3_b",
                "goal": "确认这套计数语义是否能平移到第二个单层对照对象。",
            },
        ],
    }


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff 板级 counter/CSR 契约",
        "",
        f"- 阶段定位：`{report['project_stage']}`",
        "- 目标：把 `rowhandoff mode=1` 的板级第一阶段从“应该加哪些计数点”推进到“每个计数点预期读到什么”。",
        "- 当前不改 current best，也不直接改 datapath，只服务于 trace/counter 版与单层板级最小闭环。",
        "",
        "## 建议计数点 / CSR",
        "",
        "| 名称 | 类型 | 位宽 | mode1_full 预期 | backhalf 预期 | 作用 |",
        "| --- | --- | ---: | ---: | ---: | --- |",
    ]

    for item in report["counter_contract"]:
        lines.append(
            "| `{name}` | `{kind}` | {width} | {full} | {backhalf} | {why} |".format(
                name=item["name"],
                kind=item["type"],
                width=item["width_bits"],
                full=item["expected_mode1_full"],
                backhalf=item["expected_mode1_backhalf"],
                why=item["why"],
            )
        )

    lines.extend(
        [
            "",
            "## 单层板级对账对象",
            "",
            "| 层 | 优先级 | 形状 | gate 说明 | mode1 预期净收益 | mode1 预期 gain/hit | handshake 对照 |",
            "| --- | ---: | --- | --- | ---: | ---: | --- |",
        ]
    )

    for item in report["layers"]:
        handshake = (
            f"`{item['handshake_reload_cycles']} -> {item['handshake_row_resident_cycles']}`"
            if item["handshake_reload_cycles"] is not None
            else "`待补`"
        )
        gain = item["expected_mode1_cycle_gain_vs_emptyhooks"]
        gain_text = f"{gain:+,}" if gain is not None else "-"
        gph = item["expected_mode1_gain_per_hit"]
        gph_text = f"{gph:.2f}" if gph is not None else "-"
        lines.append(
            "| `{layer}` | {prio} | `{shape}` | {gate} | {gain} | {gph} | {handshake} |".format(
                layer=item["layer_name"],
                prio=item["board_run_priority"],
                shape=item["shape"],
                gate=item["gate_assumption"],
                gain=gain_text,
                gph=gph_text,
                handshake=handshake,
            )
        )

    lines.extend(
        [
            "",
            "## 建议板级执行顺序",
            "",
            "| 步骤 | 名称 | 目标 |",
            "| ---: | --- | --- |",
        ]
    )

    for item in report["board_sequence"]:
        lines.append(
            "| {step} | `{name}` | {goal} |".format(
                step=item["step"],
                name=item["name"],
                goal=item["goal"],
            )
        )

    lines.extend(
        [
            "",
            "## 当前收敛点",
            "",
            "- 第一阶段板级验证不应只读一个总 `hit_count`，而应至少补一个后段 row bucket。",
            "- `conv2_3x3_b` 仍是第一优先对象，因为当前 `mode1` 相对 emptyhooks 的净收益就是在这里被正式保住的。",
            "- `conv3_3x3_b` 当前已经补齐单层 handshake 对账：`6350 -> 5630`，可作为第二优先的语义平移对照层。",
            "- 这份契约已经把“下一轮 RTL trace/counter 版要补哪些 CSR、每个 CSR 预期读多少”定死，后面可以直接对账而不是再猜。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    trace_payload = load_json(args.trace_counters_json)
    conv2_handshake_payload = load_json(args.conv2_handshake_compare_json)
    conv3_handshake_payload = load_json(args.conv3_handshake_compare_json)
    cases_payload = load_json(args.cases_json)
    report = build_contract_report(
        trace_payload,
        conv2_handshake_payload,
        conv3_handshake_payload,
        cases_payload,
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
