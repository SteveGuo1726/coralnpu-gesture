"""量化 strategy8 48x48 主体层更贴近 RTL 的最小控制 patch 候选。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tail_candidates_json", required=True, help="宽口径 tail patch 候选 JSON。")
    parser.add_argument("--row_end_json", required=True, help="x2 row-end tail 候选 JSON。")
    parser.add_argument("--hook_coverage_json", required=True, help="trial hook 覆盖范围 JSON。")
    parser.add_argument("--controller_json", required=True, help="conv2_3x3_b row_resident 控制器 JSON。")
    parser.add_argument("--tile_schedule_json", required=True, help="conv2_3x3_b tile schedule JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON 路径。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown 路径。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def find_row(rows: list[dict[str, Any]], layer_name: str) -> dict[str, Any]:
    for row in rows:
        if row["layer_name"] == layer_name:
            return row
    raise KeyError(f"Missing layer row: {layer_name}")


def round_int(value: float) -> int:
    return int(round(value))


def build_candidate(
    *,
    name: str,
    short_label: str,
    description: str,
    anchor_scope: str,
    anchor_lines: list[int],
    trigger_count: int,
    saved_branch_cycles: int,
    saved_writeback_branch_cycles: int,
    official_opt: int,
    sim_total: int,
    target_specificity: str,
    trial_status: str,
    note: str,
    priority_rank: int,
) -> dict[str, Any]:
    branch_ratio = (sim_total - saved_branch_cycles) / sim_total
    wb_ratio = (sim_total - saved_writeback_branch_cycles) / sim_total
    branch_opt = round_int(official_opt * branch_ratio)
    wb_opt = round_int(official_opt * wb_ratio)
    return {
        "name": name,
        "short_label": short_label,
        "description": description,
        "anchor_scope": anchor_scope,
        "anchor_lines": anchor_lines,
        "trigger_count": trigger_count,
        "saved_sim_cycles": {
            "branch_only": saved_branch_cycles,
            "writeback_branch": saved_writeback_branch_cycles,
        },
        "est_from_official_best": {
            "branch_only_opt_cycles": branch_opt,
            "branch_only_delta": branch_opt - official_opt,
            "writeback_branch_opt_cycles": wb_opt,
            "writeback_branch_delta": wb_opt - official_opt,
        },
        "target_specificity": target_specificity,
        "trial_status": trial_status,
        "note": note,
        "priority_rank": priority_rank,
    }


def build_report(
    tail_candidates: dict[str, Any],
    row_end: dict[str, Any],
    hook_coverage: dict[str, Any],
    controller: dict[str, Any],
    tile_schedule: dict[str, Any],
) -> dict[str, Any]:
    target_layer = "conv2_3x3_b"
    tail_row = find_row(tail_candidates["rows"], target_layer)
    row_end_row = find_row(row_end["rows"], target_layer)
    coverage_row = find_row(hook_coverage["rows"], target_layer)

    official_opt = int(tail_row["official_best_opt_cycles"])
    sim_total = int(tail_row["row_resident_sim_cycles"])
    interior_rows = int(coverage_row["interior_rows"])
    x2_tail_total = int(coverage_row["trial_hook_steps"]["x2_tail_total"])
    spatial_sites = int(tile_schedule["grid"]["spatial_sites"])
    tiles_y = int(tile_schedule["grid"]["tiles_y"])
    tiles_x = int(tile_schedule["grid"]["tiles_x"])
    tiles_oc = int(tile_schedule["grid"]["tiles_oc"])
    controller_steps = int(controller["total_steps"])

    branch_cycle = int(round(float(row_end_row["stage_cycles"]["branch"])))
    writeback_cycle = int(round(float(row_end_row["stage_cycles"]["writeback"])))

    next_oc_count = spatial_sites * max(tiles_oc - 1, 0)
    advance_x_count = tiles_y * max(tiles_x - 1, 0)
    advance_row_count = max(tiles_y - 1, 0)
    done_count = 1
    terminal_s6_total = advance_x_count + advance_row_count + done_count

    eligible_layers = [
        row["layer_name"]
        for row in tail_candidates["rows"]
        if "48x48" in row["shape"]
        and int(row["shape"].split("x")[2].split(" ")[0]) == 32
        and row["layer_name"] == target_layer
    ]

    gate_condition = "output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode"

    candidates = [
        build_candidate(
            name="existing_x2_tail_entry",
            short_label="x2 尾块入口",
            description="当前已存在的 x2 尾块入口；位于 right-edge 完成之前，是当前最窄但也最早的 software hook。",
            anchor_scope="conv.cc",
            anchor_lines=[2781, 2784],
            trigger_count=x2_tail_total,
            saved_branch_cycles=branch_cycle * x2_tail_total,
            saved_writeback_branch_cycles=(writeback_cycle + branch_cycle) * x2_tail_total,
            official_opt=official_opt,
            sim_total=sim_total,
            target_specificity=f"可通过 `{gate_condition}` 做到只命中 `{target_layer}`。",
            trial_status="已试；`x2_post direct right-edge` 与 `early-row-end` 均为零收益。",
            note="这是保底基座，不应再作为主动扩 trial 的主要入口。",
            priority_rank=2,
        ),
        build_candidate(
            name="post_right_edge_row_terminal",
            short_label="right-edge 后行尾",
            description="每条 interior row 完成 right-edge 之后、离开当前 row 之前的最小入口；更接近 row pointer handoff。",
            anchor_scope="conv.cc",
            anchor_lines=[3116, 3121],
            trigger_count=interior_rows,
            saved_branch_cycles=branch_cycle * interior_rows,
            saved_writeback_branch_cycles=(writeback_cycle + branch_cycle) * interior_rows,
            official_opt=official_opt,
            sim_total=sim_total,
            target_specificity=f"可通过 `{gate_condition}` 做到只命中 `{target_layer}`。",
            trial_status="未直接试过；这是当前最值得新建零语义 gate 的候选。",
            note="理论量级与 x2 尾块入口相同，但观测点更靠后，更像 RTL 的 row-end / writeback / branch 收口。",
            priority_rank=1,
        ),
        build_candidate(
            name="s6_tile_advance_x",
            short_label="tile 末切列",
            description="RTL 控制器里每个 spatial tile 的末组写回后，切到下一个 out_x_tile 的 S6 分支。",
            anchor_scope="RTL proxy",
            anchor_lines=[],
            trigger_count=advance_x_count,
            saved_branch_cycles=branch_cycle * advance_x_count,
            saved_writeback_branch_cycles=(writeback_cycle + branch_cycle) * advance_x_count,
            official_opt=official_opt,
            sim_total=sim_total,
            target_specificity="若只靠 `width48 && id32 && od32` 门控，仍可限定到目标层；但语义上更靠 tile 调度而非 row-end。",
            trial_status="未试；当前 `conv.cc` 内没有同等干净的现成入口。",
            note="理论空间略大于 row-end，但更容易回到通用 spatial schedule 干扰面。",
            priority_rank=3,
        ),
        build_candidate(
            name="s6_tile_row_advance",
            short_label="tile-row 切行",
            description="RTL 控制器里每条 tile-row 的最后一个 spatial tile 完成后，切到下一条 out_y_tile 的 S6 分支。",
            anchor_scope="RTL proxy",
            anchor_lines=[],
            trigger_count=advance_row_count,
            saved_branch_cycles=branch_cycle * advance_row_count,
            saved_writeback_branch_cycles=(writeback_cycle + branch_cycle) * advance_row_count,
            official_opt=official_opt,
            sim_total=sim_total,
            target_specificity="目标层专属可以做到，但触发太少，更适合作为二次确认而非第一刀。",
            trial_status="未试；更像硬件 tile-row 控制，不是当前 software row loop 的自然入口。",
            note="这类候选太窄，单独收益不够大，不适合作为当前第一刀。",
            priority_rank=4,
        ),
        build_candidate(
            name="oc_block_exit_postprocess_dispatch",
            short_label="oc_block 退出",
            description="单个 oc_block 全部 row 完成后，进入最终 postprocess / helper dispatch 前的退出点。",
            anchor_scope="conv.cc",
            anchor_lines=[3132, 3147],
            trigger_count=done_count,
            saved_branch_cycles=branch_cycle * done_count,
            saved_writeback_branch_cycles=(writeback_cycle + branch_cycle) * done_count,
            official_opt=official_opt,
            sim_total=sim_total,
            target_specificity="层专属可做，但只触发一次。",
            trial_status="helper / row-postprocess 系列已充分证明这里太晚，不值得再扩形状。",
            note="理论收益几乎可忽略，只保留作边界参考。",
            priority_rank=5,
        ),
    ]

    candidates.sort(key=lambda item: item["priority_rank"])

    return {
        "model": tail_candidates["model"],
        "scope": "Strategy8 48x48 main-body minimal control patch candidates closer to RTL row-end / writeback / branch closure",
        "target_layer": {
            "layer_name": target_layer,
            "shape": tail_row["shape"],
            "official_best_opt_cycles": official_opt,
            "row_resident_sim_cycles": sim_total,
            "sim_to_official_scale": official_opt / sim_total,
            "controller_total_steps": controller_steps,
        },
        "counts": {
            "interior_rows": interior_rows,
            "x2_tail_total": x2_tail_total,
            "spatial_sites": spatial_sites,
            "tiles_y": tiles_y,
            "tiles_x": tiles_x,
            "tiles_oc": tiles_oc,
            "s6_next_oc_count": next_oc_count,
            "s6_advance_x_count": advance_x_count,
            "s6_advance_row_count": advance_row_count,
            "s6_done_count": done_count,
            "s6_terminal_total": terminal_s6_total,
        },
        "gate_exclusivity": {
            "gate_condition": gate_condition,
            "eligible_layers": eligible_layers,
            "exclusive_to_conv2_3x3_b": eligible_layers == [target_layer],
        },
        "baseline_references": {
            "existing_row_end_branch_delta": row_end_row["candidates"]["row_end_x2_branch_only"][
                "est_opt_delta_vs_official_best"
            ],
            "existing_row_end_writeback_branch_delta": row_end_row["candidates"][
                "row_end_x2_writeback_branch"
            ]["est_opt_delta_vs_official_best"],
            "wider_inter_oc_delta": tail_row["candidates"]["inter_oc_tail_closure"][
                "est_opt_delta_vs_official_best"
            ],
        },
        "candidate_families": candidates,
        "recommendation": {
            "first_choice": "post_right_edge_row_terminal",
            "why": [
                "触发次数与已量化的 x2 row-end 候选相同，理论量级仍是 `-19,966 ~ -39,932`。",
                "锚点位于 `run_right_edge_point` 完成之后，离 `row pointer handoff` 更近，比现有 x2 hook 更贴近 RTL 行尾收口。",
                "可用 `output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode` 做到仅命中 `conv2_3x3_b`，避免再次把主要收益打到 `conv2_3x3_a`。",
            ],
            "avoid": [
                "不要继续扩 `PostprocessAcc` 切段形状或 inline row-end writeback 模拟。",
                "不要把 `s6_tile_advance_x` 当成第一刀，它虽然理论空间略大，但更容易重新落回通用 spatial schedule。",
            ],
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    target = report["target_layer"]
    counts = report["counts"]
    exclusivity = report["gate_exclusivity"]

    lines = [
        "# strategy8 48x48 主体层最小控制 patch 候选量化",
        "",
        "- 目标：停止继续扩 `PostprocessAcc` 形状试验，把 `conv2_3x3_b` 真正可能值得落刀的最小控制入口统一量化。",
        "- 口径：以 `conv2_3x3_b` 的 current best 与 row-resident 代理为基准，同时保留 current hook、RTL tile 控制和最终退出点三类入口。",
        "",
        "## 目标层与门控专属性",
        "",
        f"- 目标层：`{target['layer_name']}`，形状：`{target['shape']}`",
        f"- current best：`{target['official_best_opt_cycles']:,}`",
        f"- row-resident 代理周期：`{target['row_resident_sim_cycles']}`，映射比例约：`{target['sim_to_official_scale']:.3f}` official cycles / sim cycle",
        f"- 建议门控：`{exclusivity['gate_condition']}`",
        f"- 是否可只命中 `conv2_3x3_b`：`{'是' if exclusivity['exclusive_to_conv2_3x3_b'] else '否'}`",
        "",
        "## 关键计数",
        "",
        "| 计数项 | 数值 | 说明 |",
        "| --- | ---: | --- |",
        f"| interior rows | {counts['interior_rows']} | software row loop 的有效主体行数 |",
        f"| x2 tail total | {counts['x2_tail_total']} | 当前 x2 尾块 hook 命中次数 |",
        f"| spatial sites | {counts['spatial_sites']} | RTL 4x8x8 控制器的空间 tile 总数 |",
        f"| S6 next oc | {counts['s6_next_oc_count']} | tile 内 `oc_group -> next oc_group` 分支次数 |",
        f"| S6 advance x | {counts['s6_advance_x_count']} | tile 末切到下一列 spatial tile 的次数 |",
        f"| S6 advance row | {counts['s6_advance_row_count']} | tile-row 末切到下一条 `out_y_tile` 的次数 |",
        f"| S6 done | {counts['s6_done_count']} | layer 完成次数 |",
        "",
        "## 候选排序",
        "",
        "| 排名 | 候选 | 锚点 | 触发次数 | branch delta | writeback+branch delta | 现状 |",
        "| --- | --- | --- | ---: | ---: | ---: | --- |",
    ]

    for candidate in report["candidate_families"]:
        anchor = (
            f"`{candidate['anchor_scope']}` {candidate['anchor_lines'][0]}-{candidate['anchor_lines'][-1]}"
            if candidate["anchor_lines"]
            else f"`{candidate['anchor_scope']}`"
        )
        lines.append(
            "| {rank} | `{label}` | {anchor} | {count} | {branch:+,} | {wb:+,} | {status} |".format(
                rank=candidate["priority_rank"],
                label=candidate["short_label"],
                anchor=anchor,
                count=candidate["trigger_count"],
                branch=candidate["est_from_official_best"]["branch_only_delta"],
                wb=candidate["est_from_official_best"]["writeback_branch_delta"],
                status=candidate["trial_status"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛判断",
            "",
            "- `x2 尾块入口` 与 `right-edge 后行尾` 的理论量级相同，都是 `46` 次触发，对 `conv2_3x3_b` 的 current best 仍约对应 `-19,966 ~ -39,932`。",
            "- 但 `right-edge 后行尾` 更靠近 `run_right_edge_point` 完成后的 row terminal，因此比当前 x2 hook 更像真实 `writeback / branch / row handoff` 观测点。",
            "- `tile 末切列` 的理论空间略大，但它已经更偏向通用 tile 调度，不适合作为“先证明目标层专属性”的第一刀。",
            "- `tile-row 切行` 与 `oc_block 退出` 太窄，收益量级不足，不应先做。",
            "",
            "## 下一步建议",
            "",
            "- 如果要继续回 official `conv.cc` 做最小控制 patch，第一刀应新建一个 compile-time disabled 的 `post_right_edge_row_terminal` 零语义 gate，位置放在 `run_right_edge_point(...)` 之后、任何 `PostprocessAcc` 之前。",
            "- 该 gate 应明确限制在 `output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode`，先保证只命中 `conv2_3x3_b`。",
            "- 如果这个新 gate 仍然零显影，再考虑更 RTL 化的 `tile 末切列` 族；在此之前不要回到 `split* / tailrows* / tailcols* / ocblock32* / inline rowpost`。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        tail_candidates=load_json(args.tail_candidates_json),
        row_end=load_json(args.row_end_json),
        hook_coverage=load_json(args.hook_coverage_json),
        controller=load_json(args.controller_json),
        tile_schedule=load_json(args.tile_schedule_json),
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
