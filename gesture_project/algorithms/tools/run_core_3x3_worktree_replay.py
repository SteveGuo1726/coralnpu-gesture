"""自动回放核心 3x3 层到官方 worktree，并产出统一 JSON。"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    default_output_base = os.environ.get(
        "CORALNPU_BAZEL_OUTPUT_BASE", "/tmp/bazel-coralnpu-gesture-3x3-batch"
    )
    parser.add_argument("--worktree_root", required=True, help="官方 coralnpu worktree 根目录。")
    parser.add_argument("--cases_json", required=True, help="核心 3x3 cases JSON。")
    parser.add_argument(
        "--layer_names",
        default="conv2_3x3_a,conv2_3x3_b,conv3_3x3_a,conv3_3x3_b",
        help="逗号分隔的 layer_name 列表。",
    )
    parser.add_argument(
        "--output_base",
        default=default_output_base,
        help="Bazel output_base，默认读 CORALNPU_BAZEL_OUTPUT_BASE，否则落到共享基座。",
    )
    parser.add_argument(
        "--npusim_target",
        default="//tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d",
        help="执行回放的 Bazel py_binary 目标；可切到更轻的 active 版本以减少 runfiles/bazel 膨胀。",
    )
    parser.add_argument(
        "--runner_mode",
        choices=["auto", "direct", "bazel_run"],
        default="auto",
        help="auto=先 build 再优先直跑 bazel-bin 可执行程序，direct=强制直跑已构建程序，bazel_run=每层继续走 bazel run。",
    )
    parser.add_argument(
        "--conv3x3_dispatch_strategy",
        type=int,
        default=0,
        choices=[0, 1, 2, 3, 4, 5, 6, 7, 8],
        help="官方 worktree 3x3 实验分派策略：0=auto，1=prefer_3_3_16，2=force_oc_strided，3=force_oc_strided_x2，4=force_oc_block_resident，5=force_oc_block_resident_x2，6=force_oc_block_resident_interior_fast，7=force_oc_block_resident_interior_ptrfast，8=force_oc_block_resident_interior_regionsplit。",
    )
    parser.add_argument(
        "--elf_label",
        default="coralnpu_hw/tests/cocotb/tutorial/tfmicro/conv2d_test.elf",
        help="NPUSim replay 使用的 runfiles ELF 标签。",
    )
    parser.add_argument("--tmp_dir", default="/tmp", help="临时 JSON 输出目录。")
    parser.add_argument("--out_json", required=True, help="输出汇总 JSON。")
    parser.add_argument("--out_md", required=True, help="输出汇总 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def target_to_binary_relpath(npusim_target: str) -> str:
    if not npusim_target.startswith("//") or ":" not in npusim_target:
        raise ValueError(f"unsupported Bazel target label: {npusim_target}")
    pkg, name = npusim_target[2:].split(":", 1)
    return str(Path("bazel-bin") / pkg / name)


def locate_built_runner(*, worktree_root: str, npusim_target: str) -> Path:
    runner_path = Path(worktree_root) / target_to_binary_relpath(npusim_target)
    if not runner_path.exists():
        raise FileNotFoundError(
            f"built runner not found: {runner_path}; run with --runner_mode auto first"
        )
    return runner_path


def ensure_bazel_build(
    *,
    worktree_root: str,
    output_base: str,
    npusim_target: str,
) -> Path:
    subprocess.run(
        [
            "bazel",
            "--batch",
            f"--output_base={output_base}",
            "build",
            npusim_target,
        ],
        cwd=worktree_root,
        check=True,
    )
    return locate_built_runner(worktree_root=worktree_root, npusim_target=npusim_target)


def run_with_bazel_run(
    *,
    worktree_root: str,
    output_base: str,
    npusim_target: str,
    cases_json: str,
    layer_name: str,
    out_path: Path,
    conv3x3_dispatch_strategy: int,
    elf_label: str,
) -> None:
    cmd = [
        "bazel",
        "--batch",
        f"--output_base={output_base}",
        "run",
        npusim_target,
        "--",
        f"--cases_json={Path(cases_json).resolve()}",
        f"--layer_name={layer_name}",
        f"--conv3x3_dispatch_strategy={conv3x3_dispatch_strategy}",
        f"--elf_label={elf_label}",
        f"--json_out={out_path}",
    ]
    subprocess.run(cmd, cwd=worktree_root, check=True)


def run_with_direct_runner(
    *,
    runner_path: Path,
    cases_json: str,
    layer_name: str,
    out_path: Path,
    conv3x3_dispatch_strategy: int,
    elf_label: str,
) -> None:
    subprocess.run(
        [
            str(runner_path),
            f"--cases_json={Path(cases_json).resolve()}",
            f"--layer_name={layer_name}",
            f"--conv3x3_dispatch_strategy={conv3x3_dispatch_strategy}",
            f"--elf_label={elf_label}",
            f"--json_out={out_path}",
        ],
        check=True,
    )


def run_one(
    worktree_root: str,
    output_base: str,
    npusim_target: str,
    cases_json: str,
    layer_name: str,
    tmp_dir: str,
    conv3x3_dispatch_strategy: int,
    elf_label: str,
    runner_mode: str,
    direct_runner_path: Path | None,
) -> dict[str, Any]:
    out_path = Path(tmp_dir) / f"{layer_name}_worktree_npusim_s{conv3x3_dispatch_strategy}.json"
    if runner_mode == "bazel_run":
        run_with_bazel_run(
            worktree_root=worktree_root,
            output_base=output_base,
            npusim_target=npusim_target,
            cases_json=cases_json,
            layer_name=layer_name,
            out_path=out_path,
            conv3x3_dispatch_strategy=conv3x3_dispatch_strategy,
            elf_label=elf_label,
        )
    elif direct_runner_path is not None:
        run_with_direct_runner(
            runner_path=direct_runner_path,
            cases_json=cases_json,
            layer_name=layer_name,
            out_path=out_path,
            conv3x3_dispatch_strategy=conv3x3_dispatch_strategy,
            elf_label=elf_label,
        )
    else:
        raise ValueError("direct runner path is required for direct/auto direct execution")
    return load_json(str(out_path))


def build_report(
    results: list[dict[str, Any]],
    worktree_root: str,
    cases_json: str,
    npusim_target: str,
    conv3x3_dispatch_strategy: int,
    elf_label: str,
) -> dict[str, Any]:
    flat_results = [item["results"][0] for item in results]
    return {
        "model": results[0]["model"] if results else "unknown",
        "scope": "Automated official worktree replay for four verified core 3x3 layers",
        "worktree_root": str(Path(worktree_root).resolve()),
        "cases_json": str(Path(cases_json).resolve()),
        "npusim_target": npusim_target,
        "conv3x3_dispatch_strategy": int(conv3x3_dispatch_strategy),
        "elf_label": elf_label,
        "results": flat_results,
        "totals": {
            "layer_count": len(flat_results),
            "opt_cycles": sum(int(item["opt_cycles"]) for item in flat_results),
            "ref_cycles": sum(int(item["ref_cycles"]) for item in flat_results),
            "total_mismatch_count": sum(int(item["mismatch_count"]) for item in flat_results),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# 核心 3x3 官方 worktree 自动回放汇总",
        "",
        f"- worktree：`{report['worktree_root']}`",
        f"- cases_json：`{report['cases_json']}`",
        f"- npusim_target：`{report['npusim_target']}`",
        f"- conv3x3_dispatch_strategy：`{report['conv3x3_dispatch_strategy']}`",
        f"- elf_label：`{report['elf_label']}`",
        "",
        "| 层名 | ref_cycles | opt_cycles | mismatch | speedup |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]

    for item in report["results"]:
        lines.append(
            "| `{layer}` | {ref_cycles:,} | {opt_cycles:,} | {mismatch} | {speedup:.5f} |".format(
                layer=item["layer_name"],
                ref_cycles=item["ref_cycles"],
                opt_cycles=item["opt_cycles"],
                mismatch=item["mismatch_count"],
                speedup=float(item["speedup"]),
            )
        )

    lines.extend(
        [
            "",
            f"- 总层数：`{report['totals']['layer_count']}`",
            f"- 总 opt_cycles：`{report['totals']['opt_cycles']:,}`",
            f"- 总 ref_cycles：`{report['totals']['ref_cycles']:,}`",
            f"- 总 mismatch_count：`{report['totals']['total_mismatch_count']}`",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    layer_names = [item.strip() for item in args.layer_names.split(",") if item.strip()]
    direct_runner_path: Path | None = None
    if args.runner_mode == "auto":
        direct_runner_path = ensure_bazel_build(
            worktree_root=args.worktree_root,
            output_base=args.output_base,
            npusim_target=args.npusim_target,
        )
    elif args.runner_mode == "direct":
        direct_runner_path = locate_built_runner(
            worktree_root=args.worktree_root,
            npusim_target=args.npusim_target,
        )
    results = [
        run_one(
            worktree_root=args.worktree_root,
            output_base=args.output_base,
            npusim_target=args.npusim_target,
            cases_json=args.cases_json,
            layer_name=layer_name,
            tmp_dir=args.tmp_dir,
            conv3x3_dispatch_strategy=args.conv3x3_dispatch_strategy,
            elf_label=args.elf_label,
            runner_mode=args.runner_mode,
            direct_runner_path=direct_runner_path,
        )
        for layer_name in layer_names
    ]
    report = build_report(
        results,
        args.worktree_root,
        args.cases_json,
        args.npusim_target,
        args.conv3x3_dispatch_strategy,
        args.elf_label,
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
