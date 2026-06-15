"""构建 gesture_project -> 官方 worktree 的核心 3x3 最小桥接清单。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases_json", required=True, help="核心 3x3 cases JSON。")
    parser.add_argument("--impact_json", required=True, help="核心 3x3 握手级部署收益 JSON。")
    parser.add_argument("--worktree_root", required=True, help="官方 coralnpu worktree 根目录。")
    parser.add_argument("--out_json", required=True, help="输出桥接 JSON。")
    parser.add_argument("--out_md", required=True, help="输出桥接 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_bridge(cases: dict[str, Any], impact: dict[str, Any], worktree_root: str) -> dict[str, Any]:
    layer_to_impact = {item["layer_name"]: item for item in impact["layers"]}
    cases_path = str(Path(cases["source_path"]).resolve()) if "source_path" in cases else None
    if cases_path is None:
        raise ValueError("cases JSON must include source_path")

    layer_entries = []
    for case in cases["cases"]:
        layer_name = case["layer_name"]
        impact_item = layer_to_impact.get(layer_name)
        if impact_item is None:
            continue

        row_resident_docs = None
        if layer_name == "conv2_3x3_b":
            row_resident_docs = {
                "contract": "gesture_project/reports/conv2_3x3_b_handshake_contract.md",
                "rt_table": "gesture_project/reports/conv2_3x3_b_register_transfer_table.md",
                "pseudo_rtl": "gesture_project/reports/conv2_3x3_b_ctrl_4x8x8_pseudo.sv",
            }
        elif layer_name == "conv3_3x3_b":
            row_resident_docs = {
                "contract": "gesture_project/reports/conv3_3x3_b_handshake_contract.md",
                "rt_table": "gesture_project/reports/conv3_3x3_b_register_transfer_table.md",
                "pseudo_rtl": "gesture_project/reports/conv3_3x3_b_ctrl_4x8x8_pseudo.sv",
            }

        layer_entries.append(
            {
                "layer_name": layer_name,
                "shape": (
                    f"{case['out_h']}x{case['out_w']}x{case['in_d']} -> "
                    f"{case['filter_hw']}x{case['filter_hw']} -> "
                    f"{case['out_h']}x{case['out_w']}x{case['out_d']}"
                ),
                "expected_current_path": case["expected_current_path"],
                "baseline_opt_cycles": impact_item["baseline"]["opt_cycles"],
                "baseline_ref_cycles": impact_item["baseline"]["ref_cycles"],
                "mapped_row_resident_opt_cycles": impact_item["deployment_proxy"]["mapped_row_resident_opt_cycles"],
                "mapped_cycle_delta_vs_baseline_opt": impact_item["deployment_proxy"][
                    "mapped_row_resident_cycle_delta_vs_baseline_opt"
                ],
                "worktree_npuism_command": (
                    "bazel --batch --output_base=/tmp/bazel-coralnpu-gesture-3x3-batch run "
                    "//tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d -- "
                    f"--cases_json={cases_path} "
                    f"--layer_name={layer_name} "
                    f"--json_out=/tmp/{layer_name}_worktree_npusim.json"
                ),
                "row_resident_control_artifacts": row_resident_docs,
            }
        )

    return {
        "model": cases["model"],
        "scope": "Bridge from gesture_project artifacts to official coralnpu worktree NPUSim replay entry",
        "worktree_root": str(Path(worktree_root).resolve()),
        "cases_json": cases_path,
        "worktree_entry": {
            "target": "//tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d",
            "script": "tests/cocotb/tutorial/tfmicro/npusim_static_cnn_conv2d.py",
            "binary": "tests/cocotb/tutorial/tfmicro/conv2d_test.cc",
            "notes": [
                "当前官方 worktree 已内置 cases_json / layer_name / json_out 三个关键桥接参数。",
                "因此本轮最小桥接不需要先改官方脚本接口，只需稳定喂入正式 96x96 核心层配置。",
            ],
        },
        "layers": layer_entries,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# static_cnn_i96 核心 3x3 官方 worktree 最小桥接清单",
        "",
        "- 目标：把 `gesture_project` 侧已经收敛的正式核心 3x3 配置与收益代理，桥接到官方 `coralnpu-3x3-conv` worktree 现有 NPUSim 实验入口。",
        "",
        "## 当前桥接入口",
        "",
        f"- worktree 根目录：`{report['worktree_root']}`",
        f"- Bazel target：`{report['worktree_entry']['target']}`",
        f"- cases_json：`{report['cases_json']}`",
        "",
        "## 为什么这是最小切入点",
        "",
        "- 现有 `npusim_static_cnn_conv2d.py` 已支持 `--cases_json`、`--layer_name`、`--json_out`。",
        "- 因此当前最小实验不必先改官方入口，只需把正式 96x96 核心层案例稳定喂进去。",
        "- 这样能先验证项目侧筛出的层、baseline 周期口径和 worktree 回放入口是否完全打通。",
        "",
        "## 分层桥接表",
        "",
        "| 层名 | baseline opt | 映射后 row_resident opt | 预测节省 | worktree 命令 |",
        "| --- | ---: | ---: | ---: | --- |",
    ]

    for item in report["layers"]:
        lines.append(
            "| `{layer}` | {baseline:,} | {mapped:,} | {delta:+,} | `{cmd}` |".format(
                layer=item["layer_name"],
                baseline=item["baseline_opt_cycles"],
                mapped=item["mapped_row_resident_opt_cycles"],
                delta=item["mapped_cycle_delta_vs_baseline_opt"],
                cmd=item["worktree_npuism_command"],
            )
        )

    lines.extend(
        [
            "",
            "## 和控制器主线的关系",
            "",
            "- `conv2_3x3_b` 与 `conv3_3x3_b` 已各自拥有 handshake contract、寄存器更新表和伪 RTL 骨架。",
            "- 但这些控制器产物当前仍停留在项目侧，不直接写入官方实现。",
            "- 官方 worktree 当前最合适的第一落点，是先用现有 NPUSim 回放入口验证正式核心层配置与 baseline 口径，再决定下一步 patch 应该放在调度/trace 还是 kernel 路径。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    cases = load_json(args.cases_json)
    impact = load_json(args.impact_json)
    cases["source_path"] = args.cases_json
    report = build_bridge(cases, impact, args.worktree_root)

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
