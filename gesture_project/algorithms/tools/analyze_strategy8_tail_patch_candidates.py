"""Quantify minimal tail-patch candidates on top of strategy-8 current best."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--row_templates_json", required=True, help="Row-template analysis JSON.")
    parser.add_argument("--pipeline_overlap_json", required=True, help="Pipeline-overlap proxy JSON.")
    parser.add_argument("--official_best_json", required=True, help="Official current-best replay JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def round_int(value: float) -> int:
    return int(round(value))


def fmt_signed_int(value: int) -> str:
    return f"{value:+,}"


def build_candidate(
    name: str,
    description: str,
    saved_cycles: float,
    sim_total: int,
    baseline_opt: int,
    official_opt: int,
) -> dict[str, Any]:
    candidate_total = sim_total - saved_cycles
    ratio = candidate_total / sim_total
    baseline_mapped = round_int(baseline_opt * ratio)
    official_est = round_int(official_opt * ratio)
    return {
        "name": name,
        "description": description,
        "saved_cycles_vs_serial": round_int(saved_cycles),
        "sim_cycles": round_int(candidate_total),
        "cycle_ratio_vs_serial": ratio,
        "mapped_opt_cycles_from_baseline": baseline_mapped,
        "mapped_opt_delta_vs_baseline": baseline_mapped - baseline_opt,
        "est_opt_cycles_from_official_best": official_est,
        "est_opt_delta_vs_official_best": official_est - official_opt,
    }


def build_layer_row(
    layer: dict[str, Any],
    overlap_layer: dict[str, Any],
    official_item: dict[str, Any],
) -> dict[str, Any]:
    row = layer["strategies"]["row_resident"]
    counts = row["counts"]
    avg = row["average_state_cycles"]
    sim_total = int(row["simulation_summary"]["total_cycles"])
    baseline_opt = int(layer["baseline_opt_cycles"])
    official_opt = int(official_item["opt_cycles"])

    oc_groups_total = int(counts["oc_groups_total"])
    oc_groups_per_tile = int(counts["oc_groups_per_tile"])
    spatial_tiles = int(counts["spatial_tiles"])
    inter_oc_transitions = spatial_tiles * max(oc_groups_per_tile - 1, 0)

    weight_group = float(avg["weight_group"])
    writeback = float(avg["writeback"])
    branch = float(avg["branch"])

    branch_saved = branch * oc_groups_total
    writeback_branch_saved = (writeback + branch) * oc_groups_total
    inter_oc_tail_closure_saved = (weight_group + writeback + branch) * inter_oc_transitions

    candidates = {
        "branch_only": build_candidate(
            name="branch_only",
            description="只压缩 S6_NEXT_OC_OR_SHIFT 的状态成本，不动 S5 和下一次 S3。",
            saved_cycles=branch_saved,
            sim_total=sim_total,
            baseline_opt=baseline_opt,
            official_opt=official_opt,
        ),
        "writeback_branch": build_candidate(
            name="writeback_branch",
            description="同时压缩 S5_QUANTIZE_WRITEBACK 与 S6_NEXT_OC_OR_SHIFT，不假设下一次 S3 被吞掉。",
            saved_cycles=writeback_branch_saved,
            sim_total=sim_total,
            baseline_opt=baseline_opt,
            official_opt=official_opt,
        ),
        "inter_oc_tail_closure": build_candidate(
            name="inter_oc_tail_closure",
            description="只在同一空间 tile 的 oc_group 交界处吞掉 S5 + S6 + next S3，保留首组装填和末组收尾。",
            saved_cycles=inter_oc_tail_closure_saved,
            sim_total=sim_total,
            baseline_opt=baseline_opt,
            official_opt=official_opt,
        ),
    }

    full_pipeline_total = int(
        overlap_layer["strategies"]["row_resident"]["overlap_models"]["full_pipeline"]["total_cycles"]
    )
    candidates["inter_oc_tail_closure"]["full_pipeline_total_cycles"] = full_pipeline_total
    candidates["inter_oc_tail_closure"]["consistency_delta_vs_full_pipeline"] = (
        candidates["inter_oc_tail_closure"]["sim_cycles"] - full_pipeline_total
    )

    return {
        "layer_name": layer["layer_name"],
        "shape": layer["shape"],
        "baseline_opt_cycles": baseline_opt,
        "official_best_opt_cycles": official_opt,
        "row_resident_sim_cycles": sim_total,
        "counts": {
            "tile_rows": int(counts["tile_rows"]),
            "tiles_per_row": int(counts["tiles_per_row"]),
            "spatial_tiles": spatial_tiles,
            "oc_groups_per_tile": oc_groups_per_tile,
            "oc_groups_total": oc_groups_total,
            "inter_oc_transitions": inter_oc_transitions,
        },
        "stage_cycles": {
            "weight_group": weight_group,
            "compute": float(avg["compute"]),
            "writeback": writeback,
            "branch": branch,
        },
        "candidates": candidates,
    }


def build_totals(rows: list[dict[str, Any]]) -> dict[str, Any]:
    totals: dict[str, Any] = {
        "baseline_opt_cycles": sum(item["baseline_opt_cycles"] for item in rows),
        "official_best_opt_cycles": sum(item["official_best_opt_cycles"] for item in rows),
    }
    for candidate_name in ("branch_only", "writeback_branch", "inter_oc_tail_closure"):
        totals[candidate_name] = {
            "saved_cycles_vs_serial": sum(
                item["candidates"][candidate_name]["saved_cycles_vs_serial"] for item in rows
            ),
            "mapped_opt_cycles_from_baseline": sum(
                item["candidates"][candidate_name]["mapped_opt_cycles_from_baseline"] for item in rows
            ),
            "mapped_opt_delta_vs_baseline": sum(
                item["candidates"][candidate_name]["mapped_opt_delta_vs_baseline"] for item in rows
            ),
            "est_opt_cycles_from_official_best": sum(
                item["candidates"][candidate_name]["est_opt_cycles_from_official_best"] for item in rows
            ),
            "est_opt_delta_vs_official_best": sum(
                item["candidates"][candidate_name]["est_opt_delta_vs_official_best"] for item in rows
            ),
        }
    return totals


def build_rankings(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    rankings: dict[str, list[dict[str, Any]]] = {}
    for candidate_name in ("branch_only", "writeback_branch", "inter_oc_tail_closure"):
        ordered = sorted(
            rows,
            key=lambda item: item["candidates"][candidate_name]["est_opt_delta_vs_official_best"],
        )
        rankings[candidate_name] = [
            {
                "layer_name": item["layer_name"],
                "shape": item["shape"],
                "est_opt_delta_vs_official_best": item["candidates"][candidate_name][
                    "est_opt_delta_vs_official_best"
                ],
            }
            for item in ordered
        ]
    return rankings


def build_report(
    row_templates: dict[str, Any],
    pipeline_overlap: dict[str, Any],
    official_best: dict[str, Any],
) -> dict[str, Any]:
    overlap_map = {item["layer_name"]: item for item in pipeline_overlap["layers"]}
    official_map = {item["layer_name"]: item for item in official_best["results"]}

    rows = [
        build_layer_row(layer, overlap_map[layer["layer_name"]], official_map[layer["layer_name"]])
        for layer in row_templates["layers"]
        if layer["layer_name"] in overlap_map and layer["layer_name"] in official_map
    ]

    return {
        "model": row_templates["model"],
        "scope": "Minimal tail-patch candidates on top of strategy-8 current best",
        "definitions": {
            "branch_only": "只压缩 S6_NEXT_OC_OR_SHIFT。",
            "writeback_branch": "同时压缩 S5_QUANTIZE_WRITEBACK 与 S6_NEXT_OC_OR_SHIFT。",
            "inter_oc_tail_closure": "只在同一空间 tile 的 oc_group 交界处吞掉 S5 + S6 + next S3，保留首组装填和末组收尾。",
        },
        "rows": rows,
        "totals": build_totals(rows),
        "rankings": build_rankings(rows),
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    totals = report["totals"]
    lines = [
        "# strategy8 当前最优主线的尾部 patch 候选量化",
        "",
        "- 口径：不改 `conv.cc` 当前 current best 主体区，只把 `row_resident` 里的 `S5 -> S6 -> next S3` 尾部收口拆成三档最小 patch 代理。",
        "- 对齐方式：同时给出 `baseline` 映射收益与 `official current best` 之上的剩余空间估算，避免把两种口径混在一起。",
        "",
        "## 三档候选总量",
        "",
        "| 候选 | baseline 映射 opt | baseline delta | current best 估算 opt | current best delta |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]

    for candidate_name, label in (
        ("branch_only", "只消掉 branch"),
        ("writeback_branch", "消掉 writeback + branch"),
        ("inter_oc_tail_closure", "消掉 inter-oc 的 writeback + branch + next weight/select"),
    ):
        item = totals[candidate_name]
        lines.append(
            "| {label} | {baseline_opt:,} | {baseline_delta:+,} | {official_opt:,} | {official_delta:+,} |".format(
                label=label,
                baseline_opt=item["mapped_opt_cycles_from_baseline"],
                baseline_delta=item["mapped_opt_delta_vs_baseline"],
                official_opt=item["est_opt_cycles_from_official_best"],
                official_delta=item["est_opt_delta_vs_official_best"],
            )
        )

    lines.extend(
        [
            "",
            "## 48x48 主体层优先观察",
            "",
            "| 层名 | current best opt | branch-only delta | writeback+branch delta | inter-oc tail-closure delta |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )

    for row in report["rows"]:
        if not row["shape"].startswith("48x48"):
            continue
        lines.append(
            "| `{layer}` | {official:,} | {branch_delta:+,} | {tail_delta:+,} | {closure_delta:+,} |".format(
                layer=row["layer_name"],
                official=row["official_best_opt_cycles"],
                branch_delta=row["candidates"]["branch_only"]["est_opt_delta_vs_official_best"],
                tail_delta=row["candidates"]["writeback_branch"]["est_opt_delta_vs_official_best"],
                closure_delta=row["candidates"]["inter_oc_tail_closure"]["est_opt_delta_vs_official_best"],
            )
        )

    lines.extend(
        [
            "",
            "## 四层逐层明细",
            "",
            "| 层名 | row_resident 周期 | oc_group 总数 | inter-oc 次数 | branch-only delta | writeback+branch delta | inter-oc tail-closure delta |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
    )

    for row in report["rows"]:
        lines.append(
            "| `{layer}` | {sim:,} | {oc_total:,} | {inter_oc:,} | {branch_delta:+,} | {tail_delta:+,} | {closure_delta:+,} |".format(
                layer=row["layer_name"],
                sim=row["row_resident_sim_cycles"],
                oc_total=row["counts"]["oc_groups_total"],
                inter_oc=row["counts"]["inter_oc_transitions"],
                branch_delta=row["candidates"]["branch_only"]["est_opt_delta_vs_official_best"],
                tail_delta=row["candidates"]["writeback_branch"]["est_opt_delta_vs_official_best"],
                closure_delta=row["candidates"]["inter_oc_tail_closure"]["est_opt_delta_vs_official_best"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛结论",
            "",
            "- `branch_only` 是最保守、最像组合控制整理的 patch，上界约为 current best 之上再省 `{}` cycle。".format(
                fmt_signed_int(totals["branch_only"]["est_opt_delta_vs_official_best"])
            ),
            "- `writeback_branch` 对应更紧的输出驻留/写回握手，上界约为 `{}` cycle。".format(
                fmt_signed_int(totals["writeback_branch"]["est_opt_delta_vs_official_best"])
            ),
            "- `inter_oc_tail_closure` 最贴近 `S5 -> S6 -> next S3` 收口，总体上界约为 `{}` cycle。".format(
                fmt_signed_int(totals["inter_oc_tail_closure"]["est_opt_delta_vs_official_best"])
            ),
            "- 这三档里，真正最接近回 official worktree 做最小 patch 的，是 `inter_oc_tail_closure` 的 48x48 主体层落点，而不是再重写主体计算骨架。",
            "- 该候选与现有 `full_pipeline` 口径应严格对齐；若逐层 `consistency_delta_vs_full_pipeline = 0`，说明这份新量化和旧代理没有口径漂移。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        row_templates=load_json(args.row_templates_json),
        pipeline_overlap=load_json(args.pipeline_overlap_json),
        official_best=load_json(args.official_best_json),
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
