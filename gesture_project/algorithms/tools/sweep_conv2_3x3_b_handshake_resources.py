"""扫面 conv2_3x3_b 握手级控制器的资源参数。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from simulate_conv2_3x3_b_handshake_controller import run_simulation


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="输入 tile schedule JSON。")
    parser.add_argument(
        "--compute_cycles_list",
        default="16,24,32,40,48",
        help="逗号分隔的 compute_cycles 列表。",
    )
    parser.add_argument(
        "--weight_bw_list",
        default="256,384,512,768,1024",
        help="逗号分隔的 weight_bw 列表，单位 B/cycle。",
    )
    parser.add_argument("--input_bw", type=int, default=512, help="输入带宽。")
    parser.add_argument("--output_bw", type=int, default=256, help="输出带宽。")
    parser.add_argument("--local_weight_select_cycles", type=int, default=1, help="本地 weight 选通延迟。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def parse_int_list(text: str) -> list[int]:
    return [int(item.strip()) for item in text.split(",") if item.strip()]


def build_sweep(
    schedule: dict[str, Any],
    compute_cycles_list: list[int],
    weight_bw_list: list[int],
    input_bw: int,
    output_bw: int,
    local_weight_select_cycles: int,
) -> dict[str, Any]:
    cases: list[dict[str, Any]] = []
    best_case: dict[str, Any] | None = None

    for compute_cycles in compute_cycles_list:
        for weight_bw in weight_bw_list:
            reload_report = run_simulation(
                schedule=schedule,
                strategy="reload",
                input_bw=input_bw,
                weight_bw=weight_bw,
                output_bw=output_bw,
                compute_cycles=compute_cycles,
                local_weight_select_cycles=local_weight_select_cycles,
                max_trace_cycles=0,
            )
            row_report = run_simulation(
                schedule=schedule,
                strategy="row_resident",
                input_bw=input_bw,
                weight_bw=weight_bw,
                output_bw=output_bw,
                compute_cycles=compute_cycles,
                local_weight_select_cycles=local_weight_select_cycles,
                max_trace_cycles=0,
            )

            reload_cycles = int(reload_report["summary"]["total_cycles"])
            row_cycles = int(row_report["summary"]["total_cycles"])
            cycle_ratio = row_cycles / reload_cycles
            cycle_delta = row_cycles - reload_cycles

            case = {
                "compute_cycles": compute_cycles,
                "weight_bw": weight_bw,
                "reload_total_cycles": reload_cycles,
                "row_resident_total_cycles": row_cycles,
                "cycle_delta": cycle_delta,
                "cycle_ratio": round(cycle_ratio, 4),
                "reload_weight_bytes": int(reload_report["summary"]["bytes_summary"]["weight_bytes"]),
                "row_resident_weight_bytes": int(row_report["summary"]["bytes_summary"]["weight_bytes"]),
            }
            cases.append(case)

            if best_case is None or cycle_ratio < best_case["cycle_ratio"]:
                best_case = case

    return {
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "fixed_resource_model": {
            "input_bw": input_bw,
            "output_bw": output_bw,
            "local_weight_select_cycles": local_weight_select_cycles,
        },
        "compute_cycles_list": compute_cycles_list,
        "weight_bw_list": weight_bw_list,
        "cases": cases,
        "best_case": best_case,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# conv2_3x3_b 4x8x8 握手级资源参数扫面",
        "",
        "- 固定输入/输出带宽，仅扫 `compute_cycles` 与 `weight_bw` 对 `reload` / `row_resident` 的影响。",
        "",
        "## 最优案例",
        "",
    ]

    best_case = report["best_case"]
    if best_case is not None:
        lines.extend(
            [
                f"- `compute_cycles={best_case['compute_cycles']}`",
                f"- `weight_bw={best_case['weight_bw']} B/cycle`",
                f"- 周期比 `row_resident / reload = {best_case['cycle_ratio']:.4f}`",
                f"- 周期差 `row_resident - reload = {best_case['cycle_delta']:+,}`",
                "",
            ]
        )

    lines.extend(
        [
            "## 全量结果",
            "",
            "| compute_cycles | weight_bw | reload cycles | row_resident cycles | delta | ratio |",
            "| ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for case in report["cases"]:
        lines.append(
            "| {compute_cycles} | {weight_bw} | {reload_total_cycles:,} | {row_resident_total_cycles:,} | {cycle_delta:+,} | {cycle_ratio:.4f} |".format(
                **case
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    report = build_sweep(
        schedule=schedule,
        compute_cycles_list=parse_int_list(args.compute_cycles_list),
        weight_bw_list=parse_int_list(args.weight_bw_list),
        input_bw=args.input_bw,
        output_bw=args.output_bw,
        local_weight_select_cycles=args.local_weight_select_cycles,
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
