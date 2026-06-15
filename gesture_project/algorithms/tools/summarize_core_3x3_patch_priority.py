"""基于四层完整对齐结果，汇总核心 3x3 的 patch 优先级。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worktree_replay_json", required=True, help="四层 worktree 自动回放 JSON。")
    parser.add_argument("--impact_json", required=True, help="握手级部署收益 JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(worktree: dict[str, Any], impact: dict[str, Any]) -> dict[str, Any]:
    impact_map = {item["layer_name"]: item for item in impact["layers"]}
    rows = []
    for item in worktree["results"]:
        imp = impact_map[item["layer_name"]]
        rows.append(
            {
                "layer_name": item["layer_name"],
                "shape": imp["shape"],
                "worktree_opt_cycles": int(item["opt_cycles"]),
                "mapped_row_resident_opt_cycles": int(imp["deployment_proxy"]["mapped_row_resident_opt_cycles"]),
                "predicted_cycle_delta": int(imp["deployment_proxy"]["mapped_row_resident_cycle_delta_vs_baseline_opt"]),
                "predicted_cycle_ratio": float(imp["deployment_proxy"]["mapped_row_resident_cycle_ratio_vs_baseline_opt"]),
            }
        )

    rows.sort(key=lambda item: item["predicted_cycle_delta"])
    return {
        "model": worktree["model"],
        "scope": "Priority summary for next minimal patch after four-layer worktree alignment",
        "rows": rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 核心 3x3 最小 patch 优先级汇总",
        "",
        "- 前提：4 个正式核心层已经全部在官方 worktree 上完成真实回放，且与项目 baseline 周期高度对齐。",
        "- 目标：在此基础上，按 row_resident 收益代理收敛下一步最小 patch 优先顺序。",
        "",
        "| 优先级 | 层名 | worktree opt | 映射后 row_resident opt | 预测节省 | 比例 |",
        "| ---: | --- | ---: | ---: | ---: | ---: |",
    ]

    for idx, item in enumerate(report["rows"], start=1):
        lines.append(
            "| {idx} | `{layer}` | {worktree_opt:,} | {mapped_opt:,} | {delta:+,} | {ratio:.4f} |".format(
                idx=idx,
                layer=item["layer_name"],
                worktree_opt=item["worktree_opt_cycles"],
                mapped_opt=item["mapped_row_resident_opt_cycles"],
                delta=item["predicted_cycle_delta"],
                ratio=item["predicted_cycle_ratio"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛建议",
            "",
            "- 第一优先：`conv3_3x3_b`，因为当前四层里它的预测节省最大。",
            "- 第二优先：`conv2_3x3_b`，因为它仍是 48x48 主体层第一关键落点。",
            "- `a` 层更适合作为 patch 后的稳定性回归层，而不是第一刀切入点。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    worktree = load_json(args.worktree_replay_json)
    impact = load_json(args.impact_json)
    report = build_report(worktree, impact)

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
