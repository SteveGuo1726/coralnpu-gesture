"""Map strategy-8 tail-patch candidates to concrete official conv.cc entry anchors."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--conv_cc", required=True, help="Official worktree conv.cc path.")
    parser.add_argument("--tail_candidates_json", required=True, help="Tail patch candidate report JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown path.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def find_line(lines: list[str], pattern: str, start: int = 0) -> int | None:
    for index in range(start, len(lines)):
        if pattern in lines[index]:
            return index + 1
    return None


def find_block_anchors(
    lines: list[str], input_depth: int, start_line: int, end_line: int
) -> dict[str, int | None]:
    start = max(start_line - 1, 0)
    end = min(end_line, len(lines))

    def scoped_find(pattern: str, local_start: int | None = None) -> int | None:
        search_start = start if local_start is None else max(local_start - 1, start)
        for index in range(search_start, end):
            if pattern in lines[index]:
                return index + 1
        return None

    if input_depth == 32:
        dispatch_anchor = scoped_find("} else if (enable_interior_x4_id32) {")
        x4_macro_anchor = scoped_find("#define CONV3X3_RUN_X4_ID32_BLOCK()", dispatch_anchor)
        x2_macro_anchor = scoped_find("#define CONV3X3_RUN_X2_ID32_BLOCK()", dispatch_anchor)
        width48_anchor = scoped_find("} else if (output_width == 48) {", dispatch_anchor)
        x4_call_anchor = scoped_find("CONV3X3_RUN_X4_ID32_BLOCK();", width48_anchor)
        x2_call_anchor = scoped_find("CONV3X3_RUN_X2_ID32_BLOCK();", width48_anchor)
    elif input_depth == 64:
        dispatch_anchor = scoped_find("if (enable_interior_x4_id64) {")
        x4_macro_anchor = scoped_find("#define CONV3X3_RUN_X4_ID64_BLOCK()", dispatch_anchor)
        x2_macro_anchor = scoped_find("#define CONV3X3_RUN_X2_ID64_BLOCK()", dispatch_anchor)
        width48_anchor = scoped_find("} else if (output_width == 48) {", dispatch_anchor)
        x4_call_anchor = scoped_find("CONV3X3_RUN_X4_ID64_BLOCK();", width48_anchor)
        x2_call_anchor = scoped_find("CONV3X3_RUN_X2_ID64_BLOCK();", width48_anchor)
    else:
        dispatch_anchor = None
        x4_macro_anchor = None
        x2_macro_anchor = None
        width48_anchor = None
        x4_call_anchor = None
        x2_call_anchor = None

    return {
        "dispatch_anchor_line": dispatch_anchor,
        "x4_macro_anchor_line": x4_macro_anchor,
        "x2_macro_anchor_line": x2_macro_anchor,
        "width48_static_schedule_anchor_line": width48_anchor,
        "width48_x4_call_anchor_line": x4_call_anchor,
        "width48_x2_tail_anchor_line": x2_call_anchor,
    }


def build_layer_entry(
    layer: dict[str, Any], lines: list[str], kernel_start_line: int, kernel_end_line: int
) -> dict[str, Any]:
    shape = str(layer["shape"])
    lhs, _, rhs = shape.partition(" -> 3x3 -> ")
    in_h, in_w, in_d = [int(part) for part in lhs.split("x")]
    out_h, out_w, out_d = [int(part) for part in rhs.split("x")]
    if out_w == 48:
        static_x4_blocks = 11
        static_x2_tail = 1
    elif out_w == 24:
        static_x4_blocks = 5
        static_x2_tail = 1
    else:
        static_x4_blocks = max((out_w - 2) // 4, 0)
        static_x2_tail = 1 if (out_w - 2 - static_x4_blocks * 4) >= 2 else 0

    anchors = find_block_anchors(lines, in_d, kernel_start_line, kernel_end_line)
    left_edge_anchor = find_line(lines, "run_left_edge_point();", kernel_start_line - 1)
    right_edge_anchor = find_line(
        lines, "run_right_edge_point(row0_ptr, row1_ptr, row2_ptr);", kernel_start_line - 1
    )
    postprocess_anchor = find_line(
        lines, "PostprocessAcc(accs_buf, bias_data, shift_left, output_multiplier,", kernel_start_line - 1
    )

    branch_delta = layer["candidates"]["branch_only"]["est_opt_delta_vs_official_best"]
    tail_delta = layer["candidates"]["writeback_branch"]["est_opt_delta_vs_official_best"]
    closure_delta = layer["candidates"]["inter_oc_tail_closure"]["est_opt_delta_vs_official_best"]

    if out_w == 48 and in_d in (32, 64):
        recommended_patch_stage = "tail_closure_trial"
        recommended_patch_anchor = anchors["width48_x4_call_anchor_line"]
    elif out_w == 48:
        recommended_patch_stage = "trace_only"
        recommended_patch_anchor = kernel_start_line
    else:
        recommended_patch_stage = "trace_only"
        recommended_patch_anchor = anchors["dispatch_anchor_line"] or kernel_start_line

    return {
        "layer_name": layer["layer_name"],
        "shape": shape,
        "input_depth": in_d,
        "output_depth": out_d,
        "output_width": out_w,
        "official_best_opt_cycles": int(layer["official_best_opt_cycles"]),
        "tail_candidate_deltas_vs_official_best": {
            "branch_only": int(branch_delta),
            "writeback_branch": int(tail_delta),
            "inter_oc_tail_closure": int(closure_delta),
        },
        "static_schedule": {
            "static_x4_blocks_per_interior_row": static_x4_blocks,
            "static_x2_tail_blocks_per_interior_row": static_x2_tail,
            "interior_points_per_row": out_w - 2,
            "interior_rows": out_h - 2,
        },
        "proxy_counts": {
            "spatial_tiles": int(layer["counts"]["spatial_tiles"]),
            "oc_groups_per_tile": int(layer["counts"]["oc_groups_per_tile"]),
            "oc_groups_total": int(layer["counts"]["oc_groups_total"]),
            "inter_oc_transitions": int(layer["counts"]["inter_oc_transitions"]),
        },
        "official_anchor_lines": {
            **anchors,
            "left_edge_anchor_line": left_edge_anchor,
            "right_edge_anchor_line": right_edge_anchor,
            "postprocess_anchor_line": postprocess_anchor,
        },
        "patch_mapping": {
            "branch_only": "优先映射到主体块调用后的轻量分支/指针推进/循环收口观察点，不触碰 top/bottom rowband 与 PostprocessAcc。",
            "writeback_branch": "优先映射到 x4/x2 块内 `__riscv_vse32_v_i32m4(...)` 及其紧随的主体块推进位置，视作局部输出写回尾部。",
            "inter_oc_tail_closure": "优先映射到 width=48 的静态 x4 主体块调用点与其后的指针推进骨架，把最小试验限制在主体区 inter-block 收口，不动边界 4/6tap 分带。",
        },
        "recommended_first_patch": {
            "stage": recommended_patch_stage,
            "anchor_line": recommended_patch_anchor,
            "why": (
                "48x48 + id32/id64 主体区拥有最稳定的静态块骨架，最适合先做 compile-time disabled trace/gate，"
                "确认不破坏 current best 后再尝试极小尾部收口。"
            ),
        },
    }


def build_report(conv_cc: str, tail_candidates: dict[str, Any]) -> dict[str, Any]:
    conv_path = Path(conv_cc)
    lines = conv_path.read_text(encoding="utf-8").splitlines()
    kernel_start = find_line(lines, "void Conv_3x3_OCBlockResident_InteriorRegionSplit(") or 1
    kernel_end = find_line(lines, "void Conv_3x3_OCBlockResident_X2(", kernel_start - 1)
    if kernel_end is None:
        kernel_end = len(lines)
    rows = [build_layer_entry(layer, lines, kernel_start, kernel_end) for layer in tail_candidates["rows"]]
    return {
        "model": tail_candidates["model"],
        "scope": "Official conv.cc entry mapping for strategy-8 minimal tail-patch trials",
        "conv_cc": str(conv_path.resolve()),
        "global_anchors": {
            "region_split_dispatch_line": find_line(lines, "if (strategy == Conv3x3DispatchStrategy::kForceOCBlockResidentInteriorRegionSplit) {"),
            "region_split_kernel_line": kernel_start,
            "postprocess_line": find_line(
                lines,
                "PostprocessAcc(accs_buf, bias_data, shift_left, output_multiplier,",
                kernel_start - 1,
            ),
        },
        "rows": rows,
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# strategy8 official 最小 patch 入口映射",
        "",
        "- 目标：把 `gesture_project` 侧已经量化出的尾部 patch 候选，映射回 `conv.cc` 当前 current best 的最小落点。",
        "- 原则：不碰主体区大骨架，不回旧失败方向，优先找 compile-time disabled trace/gate 入口。",
        "",
        "## 全局锚点",
        "",
        "| 锚点 | 行号 | 说明 |",
        "| --- | ---: | --- |",
        "| `RegionSplit dispatch` | {dispatch} | strategy=8 选择 `Conv_3x3_OCBlockResident_InteriorRegionSplit` 的入口 |".format(
            dispatch=report["global_anchors"]["region_split_dispatch_line"] or -1
        ),
        "| `RegionSplit kernel` | {kernel} | current best 主体实现入口 |".format(
            kernel=report["global_anchors"]["region_split_kernel_line"] or -1
        ),
        "| `PostprocessAcc` | {post} | 整层统一量化/写回尾部，不属于当前最小 tail patch 第一刀 |".format(
            post=report["global_anchors"]["postprocess_line"] or -1
        ),
        "",
        "## 48x48 主体层最小入口",
        "",
        "| 层名 | current best opt | inter-oc tail-closure delta | 路径 | width=48 主体 x4 锚点 | x2 尾块锚点 | 建议第一刀 |",
        "| --- | ---: | ---: | --- | ---: | ---: | --- |",
    ]

    for row in report["rows"]:
        if row["output_width"] != 48:
            continue
        if row["input_depth"] in (32, 64):
            path_name = f"`id{row['input_depth']}` static schedule"
        else:
            path_name = "`generic interior`"
        lines.append(
            "| `{layer}` | {official:,} | {closure:+,} | {path_name} | {x4_line} | {x2_line} | `{stage}` |".format(
                layer=row["layer_name"],
                official=row["official_best_opt_cycles"],
                closure=row["tail_candidate_deltas_vs_official_best"]["inter_oc_tail_closure"],
                path_name=path_name,
                x4_line=row["official_anchor_lines"]["width48_x4_call_anchor_line"] or -1,
                x2_line=row["official_anchor_lines"]["width48_x2_tail_anchor_line"] or -1,
                stage=row["recommended_first_patch"]["stage"],
            )
        )

    lines.extend(
        [
            "",
            "## 逐层入口明细",
            "",
            "| 层名 | dispatch 入口 | width=48 调度锚点 | 左/右边界锚点 | Postprocess 锚点 | patch 建议 |",
            "| --- | ---: | ---: | --- | ---: | --- |",
        ]
    )

    for row in report["rows"]:
        left_line = row["official_anchor_lines"]["left_edge_anchor_line"] or -1
        right_line = row["official_anchor_lines"]["right_edge_anchor_line"] or -1
        lines.append(
            "| `{layer}` | {dispatch_line} | {width48_line} | `{left}/{right}` | {post_line} | `{stage}` |".format(
                layer=row["layer_name"],
                dispatch_line=row["official_anchor_lines"]["dispatch_anchor_line"] or -1,
                width48_line=row["official_anchor_lines"]["width48_static_schedule_anchor_line"] or -1,
                left=left_line,
                right=right_line,
                post_line=row["official_anchor_lines"]["postprocess_anchor_line"] or -1,
                stage=row["recommended_first_patch"]["stage"],
            )
        )

    lines.extend(
        [
            "",
            "## 收敛建议",
            "",
            "- 第一刀只建议做 `trace_only / gate_only`：把 `width=48 && input_depth in {32,64}` 的主体块调用点变成可观测锚点，但默认行为保持不变。",
            "- 若要继续到 `tail_closure_trial`，优先限制在 `width48_x4_call_anchor_line` 对应的主体 x4 调度点与其紧随的指针推进，不碰 `run_left_edge_point / run_right_edge_point / PostprocessAcc`。",
            "- `inter_oc_tail_closure` 在这里是“代理到 official 主体块收口入口”的映射，不是宣称当前 `conv.cc` 已经显式存在同名状态机。",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(args.conv_cc, load_json(args.tail_candidates_json))

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
