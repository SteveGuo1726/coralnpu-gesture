"""Quantify narrow row-end spatial tail candidates for strategy-8 current best."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tail_candidates_json", required=True, help="Tail patch candidates JSON.")
    parser.add_argument("--hook_coverage_json", required=True, help="Trial hook coverage JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def round_int(value: float) -> int:
    return int(round(value))


def build_candidate(
    name: str,
    description: str,
    saved_cycles: float,
    sim_total: int,
    official_opt: int,
) -> dict[str, Any]:
    candidate_total = sim_total - saved_cycles
    ratio = candidate_total / sim_total
    official_est = round_int(official_opt * ratio)
    return {
        "name": name,
        "description": description,
        "saved_cycles_vs_serial": round_int(saved_cycles),
        "sim_cycles": round_int(candidate_total),
        "cycle_ratio_vs_serial": ratio,
        "est_opt_cycles_from_official_best": official_est,
        "est_opt_delta_vs_official_best": official_est - official_opt,
    }


def build_row(
    tail_row: dict[str, Any],
    coverage_row: dict[str, Any],
) -> dict[str, Any]:
    official_opt = int(tail_row["official_best_opt_cycles"])
    sim_total = int(tail_row["row_resident_sim_cycles"])
    stage_cycles = tail_row["stage_cycles"]
    trial_steps = coverage_row["trial_hook_steps"]

    x2_tail_total = int(trial_steps["x2_tail_total"])
    branch = float(stage_cycles["branch"])
    writeback = float(stage_cycles["writeback"])

    candidates = {
        "row_end_x2_branch_only": build_candidate(
            name="row_end_x2_branch_only",
            description="只在每条 interior row 的 x2 尾块入口压缩 branch，不假设写回或 oc 切换被吞掉。",
            saved_cycles=branch * x2_tail_total,
            sim_total=sim_total,
            official_opt=official_opt,
        ),
        "row_end_x2_writeback_branch": build_candidate(
            name="row_end_x2_writeback_branch",
            description="只在每条 interior row 的 x2 尾块入口压缩 writeback + branch，不假设命中 inter-oc 切换。",
            saved_cycles=(writeback + branch) * x2_tail_total,
            sim_total=sim_total,
            official_opt=official_opt,
        ),
    }

    branch_only_delta = int(tail_row["candidates"]["branch_only"]["est_opt_delta_vs_official_best"])
    writeback_branch_delta = int(
        tail_row["candidates"]["writeback_branch"]["est_opt_delta_vs_official_best"]
    )

    return {
        "layer_name": tail_row["layer_name"],
        "shape": tail_row["shape"],
        "official_best_opt_cycles": official_opt,
        "row_resident_sim_cycles": sim_total,
        "x2_tail_total": x2_tail_total,
        "stage_cycles": {
            "writeback": writeback,
            "branch": branch,
        },
        "current_trial_hook_eligible": bool(
            int(coverage_row["out_w"]) == 48 and int(coverage_row["in_d"]) == 32
        ),
        "wider_reference_deltas": {
            "branch_only": branch_only_delta,
            "writeback_branch": writeback_branch_delta,
        },
        "candidates": candidates,
        "narrow_vs_wider_ratio": {
            "row_end_x2_branch_vs_branch_only": (
                candidates["row_end_x2_branch_only"]["est_opt_delta_vs_official_best"] / branch_only_delta
                if branch_only_delta
                else None
            ),
            "row_end_x2_writeback_branch_vs_writeback_branch": (
                candidates["row_end_x2_writeback_branch"]["est_opt_delta_vs_official_best"]
                / writeback_branch_delta
                if writeback_branch_delta
                else None
            ),
        },
    }


def build_report(tail_candidates: dict[str, Any], hook_coverage: dict[str, Any]) -> dict[str, Any]:
    coverage_map = {item["layer_name"]: item for item in hook_coverage["rows"]}
    rows = [
        build_row(item, coverage_map[item["layer_name"]])
        for item in tail_candidates["rows"]
        if item["layer_name"] in coverage_map
    ]

    totals = {
        "official_best_opt_cycles": sum(item["official_best_opt_cycles"] for item in rows),
        "row_end_x2_branch_only": {
            "est_opt_cycles_from_official_best": sum(
                item["candidates"]["row_end_x2_branch_only"]["est_opt_cycles_from_official_best"]
                for item in rows
            ),
            "est_opt_delta_vs_official_best": sum(
                item["candidates"]["row_end_x2_branch_only"]["est_opt_delta_vs_official_best"]
                for item in rows
            ),
        },
        "row_end_x2_writeback_branch": {
            "est_opt_cycles_from_official_best": sum(
                item["candidates"]["row_end_x2_writeback_branch"]["est_opt_cycles_from_official_best"]
                for item in rows
            ),
            "est_opt_delta_vs_official_best": sum(
                item["candidates"]["row_end_x2_writeback_branch"]["est_opt_delta_vs_official_best"]
                for item in rows
            ),
        },
    }

    return {
        "model": tail_candidates["model"],
        "scope": "Narrow row-end spatial tail candidates on top of strategy-8 current best",
        "rows": rows,
        "totals": totals,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# strategy8 row-end spatial tail 候选量化",
        "",
        "- 口径：只围绕每条 interior row 的 `x2` 尾块入口，量化更窄的 `row-end spatial tail-control` 空间。",
        "- 目的：给当前 `x2_post` trial hook 一个与 `inter_oc_tail_closure` 区分开的、更贴近真实入口的剩余空间估计。",
        "",
        "## 总量",
        "",
        "| 候选 | current best 估算 opt | current best delta |",
        "| --- | ---: | ---: |",
    ]

    for name, label in (
        ("row_end_x2_branch_only", "每行 x2 尾块只压 branch"),
        ("row_end_x2_writeback_branch", "每行 x2 尾块压 writeback + branch"),
    ):
        item = report["totals"][name]
        lines.append(
            "| {label} | {opt:,} | {delta:+,} |".format(
                label=label,
                opt=item["est_opt_cycles_from_official_best"],
                delta=item["est_opt_delta_vs_official_best"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 主体层重点",
            "",
            "| 层名 | current best opt | x2 次数 | row-end branch delta | row-end writeback+branch delta | 当前 hook 可直接承载 |",
            "| --- | ---: | ---: | ---: | ---: | --- |",
        ]
    )

    for row in report["rows"]:
        if not row["shape"].startswith("48x48"):
            continue
        lines.append(
            "| `{layer}` | {official:,} | {x2_total} | {branch_delta:+,} | {wb_delta:+,} | {eligible} |".format(
                layer=row["layer_name"],
                official=row["official_best_opt_cycles"],
                x2_total=row["x2_tail_total"],
                branch_delta=row["candidates"]["row_end_x2_branch_only"]["est_opt_delta_vs_official_best"],
                wb_delta=row["candidates"]["row_end_x2_writeback_branch"]["est_opt_delta_vs_official_best"],
                eligible="是" if row["current_trial_hook_eligible"] else "否",
            )
        )

    lines.extend(
        [
            "",
            "## 逐层明细",
            "",
            "| 层名 | x2 次数 | row-end branch delta | 对 branch-only 比例 | row-end writeback+branch delta | 对 writeback+branch 比例 |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for row in report["rows"]:
        lines.append(
            "| `{layer}` | {x2_total} | {branch_delta:+,} | {branch_ratio:.3f} | {wb_delta:+,} | {wb_ratio:.3f} |".format(
                layer=row["layer_name"],
                x2_total=row["x2_tail_total"],
                branch_delta=row["candidates"]["row_end_x2_branch_only"]["est_opt_delta_vs_official_best"],
                branch_ratio=row["narrow_vs_wider_ratio"]["row_end_x2_branch_vs_branch_only"],
                wb_delta=row["candidates"]["row_end_x2_writeback_branch"]["est_opt_delta_vs_official_best"],
                wb_ratio=row["narrow_vs_wider_ratio"]["row_end_x2_writeback_branch_vs_writeback_branch"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛结论",
            "",
            "- 这份量化回答的是一个更窄的问题：如果只在每条 interior row 的 `x2` 尾块入口做控制收口，current best 之上还能剩多少。",
            "- 对 `48x48 + id32` 的 `conv2_3x3_b`，这档空间明显小于宽口径 `branch_only / writeback_branch`，但它和当前 `x2_post` hook 的真实覆盖范围是一致的。",
            "- 因此如果下一刀继续坚持“最小、不破坏 current best、贴近现有 hook”，更合理的目标应写成 `row-end spatial tail-control`，而不是直接写成 `inter-oc tail closure`。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(load_json(args.tail_candidates_json), load_json(args.hook_coverage_json))

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
