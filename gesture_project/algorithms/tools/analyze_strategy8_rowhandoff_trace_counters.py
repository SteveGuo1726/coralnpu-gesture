"""量化 strategy8 rowhandoff mode=1 家族的 trace/counter 预期值。"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CASES_JSON = PROJECT_ROOT / "configs" / "static_cnn_i96_core_3x3.json"


@dataclass(frozen=True)
class ExperimentSpec:
    name: str
    compare_json: Path
    row_start: int | None
    row_stop: int | None
    note: str


EXPERIMENTS = (
    ExperimentSpec(
        name="mode1_full",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_vs_emptyhooks_48x48.json",
        row_start=None,
        row_stop=None,
        note="原始 mode=1，全 interior row 连续生效。",
    ),
    ExperimentSpec(
        name="mode2_fullgate",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode2_vs_emptyhooks_48x48.json",
        row_start=None,
        row_stop=None,
        note="与 mode=1 同一行带范围，但状态量更小。",
    ),
    ExperimentSpec(
        name="mode3_fullgate",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode3_vs_emptyhooks_48x48.json",
        row_start=None,
        row_stop=None,
        note="与 mode=1 同一行带范围，但状态表达进一步收紧。",
    ),
    ExperimentSpec(
        name="mode4_helper_fullgate",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode4_helper_vs_emptyhooks_48x48.json",
        row_start=None,
        row_stop=None,
        note="与 mode=1 同一行带范围，但 helper 布局扰动更大。",
    ),
    ExperimentSpec(
        name="mode6_terminalptr_fullgate",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode6_terminalptr_vs_emptyhooks_48x48.json",
        row_start=None,
        row_stop=None,
        note="与 mode=1 同一行带范围，但改为 terminal pointer 反推。",
    ),
    ExperimentSpec(
        name="mode1_backhalf",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode1_backhalf_vs_emptyhooks_48x48.json",
        row_start=24,
        row_stop=46,
        note="只在后半段 interior rows 生效。",
    ),
    ExperimentSpec(
        name="mode1_backthird",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode1_backthird_vs_emptyhooks_48x48.json",
        row_start=32,
        row_stop=46,
        note="只在后 1/3 interior rows 生效。",
    ),
    ExperimentSpec(
        name="mode1_window32_40",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode1_window32_40_vs_emptyhooks_48x48.json",
        row_start=32,
        row_stop=40,
        note="只在中后段 window32_40 生效。",
    ),
    ExperimentSpec(
        name="mode1_window40_46",
        compare_json=PROJECT_ROOT
        / "reports"
        / "core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_mode1_window40_46_vs_emptyhooks_48x48.json",
        row_start=40,
        row_stop=46,
        note="只在最末段 window40_46 生效。",
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cases_json",
        default=str(DEFAULT_CASES_JSON),
        help="核心 3x3 层配置 JSON，默认使用 static_cnn_i96_core_3x3.json。",
    )
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def build_case_map(cases_json: Path) -> dict[str, dict[str, Any]]:
    payload = load_json(cases_json)
    return {case["layer_name"]: case for case in payload["cases"]}


def build_row_window(case: dict[str, Any], row_start: int | None, row_stop: int | None) -> dict[str, Any]:
    out_h = int(case["out_h"])
    interior_rows = list(range(1, out_h - 1))
    active_start = 1 if row_start is None else row_start
    active_stop = out_h - 1 if row_stop is None else row_stop
    active_rows = [row for row in interior_rows if active_start <= row < active_stop]

    produce_count = len(active_rows)
    hit_count = max(produce_count - 1, 0)
    miss_count = 1 if produce_count else 0
    invalidate_count = 1 if produce_count else 0
    consume_opportunities = hit_count + miss_count

    return {
        "out_h": out_h,
        "interior_row_count": len(interior_rows),
        "active_row_start": active_start,
        "active_row_stop": active_stop,
        "active_rows": active_rows,
        "active_row_count": produce_count,
        "expected_counters": {
            "produce_count": produce_count,
            "hit_count": hit_count,
            "miss_count": miss_count,
            "invalidate_count": invalidate_count,
            "consume_opportunities": consume_opportunities,
            "hit_rate": (hit_count / consume_opportunities) if consume_opportunities else 0.0,
        },
    }


def build_delta_map(compare_json: Path) -> dict[str, dict[str, Any]]:
    payload = load_json(compare_json)
    return {row["layer_name"]: row for row in payload["rows"]}


def build_layer_metrics(row: dict[str, Any], counters: dict[str, Any]) -> dict[str, Any]:
    rhs_minus_lhs = int(row["rhs_minus_lhs"])
    cycle_gain = -rhs_minus_lhs
    hit_count = int(counters["hit_count"])
    produce_count = int(counters["produce_count"])
    consume_count = int(counters["consume_opportunities"])
    miss_count = int(counters["miss_count"])

    return {
        "lhs_opt_cycles": int(row["lhs_opt_cycles"]),
        "rhs_opt_cycles": int(row["rhs_opt_cycles"]),
        "rhs_minus_lhs": rhs_minus_lhs,
        "cycle_gain": cycle_gain,
        "rhs_over_lhs": float(row["rhs_over_lhs"]),
        "rhs_mismatch_count": int(row["rhs_mismatch_count"]),
        "gain_per_hit": (cycle_gain / hit_count) if hit_count else None,
        "gain_per_produce": (cycle_gain / produce_count) if produce_count else None,
        "gain_per_consume": (cycle_gain / consume_count) if consume_count else None,
        "gain_per_miss": (cycle_gain / miss_count) if miss_count else None,
    }


def build_experiment_report(spec: ExperimentSpec, case_map: dict[str, dict[str, Any]]) -> dict[str, Any]:
    compare_rows = build_delta_map(spec.compare_json)
    counter_window = build_row_window(case_map["conv2_3x3_b"], spec.row_start, spec.row_stop)
    counters = counter_window["expected_counters"]

    layers = {}
    for layer_name in ("conv2_3x3_a", "conv2_3x3_b"):
        layers[layer_name] = build_layer_metrics(compare_rows[layer_name], counters)

    return {
        "name": spec.name,
        "compare_json": str(spec.compare_json.relative_to(PROJECT_ROOT)),
        "note": spec.note,
        "row_window": counter_window,
        "layers": layers,
    }


def build_summary(experiments: list[dict[str, Any]]) -> dict[str, Any]:
    full = next(item for item in experiments if item["name"] == "mode1_full")
    full_gain_per_hit_b = float(full["layers"]["conv2_3x3_b"]["gain_per_hit"])
    full_gain_per_hit_a = float(full["layers"]["conv2_3x3_a"]["gain_per_hit"])

    rows = []
    for item in experiments:
        layer_a = item["layers"]["conv2_3x3_a"]
        layer_b = item["layers"]["conv2_3x3_b"]
        rows.append(
            {
                "name": item["name"],
                "active_row_count": item["row_window"]["active_row_count"],
                "hit_count": item["row_window"]["expected_counters"]["hit_count"],
                "conv2_3x3_a_gain": layer_a["cycle_gain"],
                "conv2_3x3_b_gain": layer_b["cycle_gain"],
                "conv2_3x3_a_gain_per_hit": layer_a["gain_per_hit"],
                "conv2_3x3_b_gain_per_hit": layer_b["gain_per_hit"],
                "conv2_3x3_a_efficiency_vs_mode1_full": (
                    (float(layer_a["gain_per_hit"]) / full_gain_per_hit_a)
                    if layer_a["gain_per_hit"] is not None
                    else None
                ),
                "conv2_3x3_b_efficiency_vs_mode1_full": (
                    (float(layer_b["gain_per_hit"]) / full_gain_per_hit_b)
                    if layer_b["gain_per_hit"] is not None
                    else None
                ),
            }
        )
    return {"rows": rows}


def write_markdown(report: dict[str, Any], out_md: Path) -> None:
    lines = [
        "# strategy8 rowhandoff trace/counter 预期量化",
        "",
        "- 模型：`static_cnn_regularized_3x3_i96_e70_hagrid6_sample`",
        "- 目标：把 `rowhandoff mode=1` 家族已有 replay 净收益，改写成板级 trace/counter 第一阶段可直接对账的命中/失效预期。",
        "- 适用对象：`48x48 + id32 + od32 + single_oc_block_mode`，即当前 `conv2_3x3_a / conv2_3x3_b` 第二层正收益主线。",
        "",
        "## 计数假设",
        "",
        "- interior rows 取 `out_y in [1, out_h - 1)`；对 `48x48` 层即 `1..46`，共 `46` 条。",
        "- 对单个连续 row-window，默认采用同一组 trace/counter 语义：",
        "  - 第一条生效 row 先 miss，再连续 hit。",
        "  - 每条生效 row 行尾 produce 一次 next-row base state。",
        "  - 离开生效窗口或离开 interior 区后 invalidate 一次。",
        "- 因此若连续窗口长度为 `N`，则：`produce=N`，`hit=N-1`，`miss=1`，`invalidate=1`。",
        "",
        "## 各试验的预期计数",
        "",
        "| 试验 | 生效 row 区间 | 生效行数 | produce | hit | miss | invalidate | hit rate | 说明 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]

    for item in report["experiments"]:
        window = item["row_window"]
        counters = window["expected_counters"]
        lines.append(
            "| `{name}` | `[{start}, {stop})` | {count} | {produce} | {hit} | {miss} | {inv} | {rate:.2%} | {note} |".format(
                name=item["name"],
                start=window["active_row_start"],
                stop=window["active_row_stop"],
                count=window["active_row_count"],
                produce=counters["produce_count"],
                hit=counters["hit_count"],
                miss=counters["miss_count"],
                inv=counters["invalidate_count"],
                rate=counters["hit_rate"],
                note=item["note"],
            )
        )

    lines.extend(
        [
            "",
            "## conv2_3x3_b 命中效率",
            "",
            "| 试验 | 净收益 cycles | hit 数 | gain/hit | gain/produce | 相对 mode1_full 每 hit 效率 | mismatch |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for row in report["summary"]["rows"]:
        experiment = next(item for item in report["experiments"] if item["name"] == row["name"])
        layer = experiment["layers"]["conv2_3x3_b"]
        lines.append(
            "| `{name}` | {gain:+,} | {hit} | {gain_per_hit:.2f} | {gain_per_produce:.2f} | {eff:.2f}x | {mismatch} |".format(
                name=row["name"],
                gain=row["conv2_3x3_b_gain"],
                hit=row["hit_count"],
                gain_per_hit=float(layer["gain_per_hit"]) if layer["gain_per_hit"] is not None else 0.0,
                gain_per_produce=float(layer["gain_per_produce"])
                if layer["gain_per_produce"] is not None
                else 0.0,
                eff=float(row["conv2_3x3_b_efficiency_vs_mode1_full"])
                if row["conv2_3x3_b_efficiency_vs_mode1_full"] is not None
                else 0.0,
                mismatch=layer["rhs_mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## conv2_3x3_a 对照",
            "",
            "| 试验 | 净收益 cycles | hit 数 | gain/hit | 相对 mode1_full 每 hit 效率 | mismatch |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for row in report["summary"]["rows"]:
        experiment = next(item for item in report["experiments"] if item["name"] == row["name"])
        layer = experiment["layers"]["conv2_3x3_a"]
        lines.append(
            "| `{name}` | {gain:+,} | {hit} | {gain_per_hit:.2f} | {eff:.2f}x | {mismatch} |".format(
                name=row["name"],
                gain=row["conv2_3x3_a_gain"],
                hit=row["hit_count"],
                gain_per_hit=float(layer["gain_per_hit"]) if layer["gain_per_hit"] is not None else 0.0,
                eff=float(row["conv2_3x3_a_efficiency_vs_mode1_full"])
                if row["conv2_3x3_a_efficiency_vs_mode1_full"] is not None
                else 0.0,
                mismatch=layer["rhs_mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛结论",
            "",
            "- `mode1_full` 对 `conv2_3x3_b` 的板级第一版计数基线应当接近：`produce=46, hit=45, miss=1, invalidate=1`。",
            "- 纯 row-window 虽然总收益弱于 `mode1_full`，但 `conv2_3x3_b` 的 `gain/hit` 从 `204.56` 提升到 `1497.40`，说明后段 row 的单次命中价值显著更高。",
            "- 这意味着板级 trace/counter 不应只收总 hit 数，最好至少增加“后段 row hit bucket”或按 row 区段分桶的命中计数。",
            "- `mode2 / mode3 / mode4_helper / mode6_terminalptr` 与 `mode1_full` 共享几乎同一 hit/miss 外形，但净收益显著变弱，说明真正决定收益的不是 hit 数本身，而是传递的 row-base 语义是否贴近原始 mode=1。",
            "- 因此上板第一阶段最值得对账的不是更多微调 patch，而是：",
            "  - `mode1_full` 的总计数是否对齐 `46/45/1/1`；",
            "  - 后段 row 的命中是否更高效；",
            "  - `terminalptr` 这类同计数、异语义分支为何在目标层退化。",
        ]
    )

    out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    case_map = build_case_map(Path(args.cases_json))
    experiments = [build_experiment_report(spec, case_map) for spec in EXPERIMENTS]
    report = {
        "model": "static_cnn_regularized_3x3_i96_e70_hagrid6_sample",
        "cases_json": str(Path(args.cases_json).resolve()),
        "experiments": experiments,
        "summary": build_summary(experiments),
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
