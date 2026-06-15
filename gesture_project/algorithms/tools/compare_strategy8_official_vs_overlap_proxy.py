"""Compare official strategy-8 best replay against overlap proxy envelopes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline_json", required=True, help="Official worktree baseline replay JSON.")
    parser.add_argument("--official_best_json", required=True, help="Official best strategy-8 replay JSON.")
    parser.add_argument("--overlap_json", required=True, help="Pipeline-overlap proxy JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON.")
    parser.add_argument("--out_md", required=True, help="Output Markdown.")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def pick_row_resident_dual(layer: dict[str, Any]) -> dict[str, Any]:
    return layer["strategies"]["row_resident"]["overlap_models"]["dual_port_full_pipeline"]


def build_report(
    baseline: dict[str, Any],
    official_best: dict[str, Any],
    overlap: dict[str, Any],
) -> dict[str, Any]:
    baseline_map = {item["layer_name"]: item for item in baseline["results"]}
    official_map = {item["layer_name"]: item for item in official_best["results"]}
    overlap_map = {item["layer_name"]: item for item in overlap["layers"]}

    rows = []
    total_official_saving = 0
    total_proxy_saving = 0
    for layer_name in sorted(official_map):
        base_opt = int(baseline_map[layer_name]["opt_cycles"])
        official_opt = int(official_map[layer_name]["opt_cycles"])
        official_saving = base_opt - official_opt

        dual = pick_row_resident_dual(overlap_map[layer_name])
        proxy_opt = int(dual["mapped_opt_cycles_from_baseline"])
        proxy_saving = base_opt - proxy_opt

        remaining_gap = official_opt - proxy_opt
        proxy_capture = (official_saving / proxy_saving) if proxy_saving > 0 else None

        rows.append(
            {
                "layer_name": layer_name,
                "baseline_opt_cycles": base_opt,
                "official_best_opt_cycles": official_opt,
                "official_best_saving": official_saving,
                "overlap_proxy_opt_cycles": proxy_opt,
                "overlap_proxy_saving": proxy_saving,
                "official_capture_ratio_vs_proxy": proxy_capture,
                "remaining_gap_to_proxy": remaining_gap,
                "mismatch_count": int(official_map[layer_name]["mismatch_count"]),
            }
        )
        total_official_saving += official_saving
        total_proxy_saving += proxy_saving

    return {
        "model": baseline.get("model", "unknown"),
        "scope": "Official strategy-8 best replay vs dual-port overlap proxy",
        "rows": rows,
        "totals": {
            "official_best_saving": total_official_saving,
            "overlap_proxy_saving": total_proxy_saving,
            "official_capture_ratio_vs_proxy": (
                total_official_saving / total_proxy_saving if total_proxy_saving > 0 else None
            ),
            "remaining_gap_to_proxy": sum(item["remaining_gap_to_proxy"] for item in rows),
            "total_mismatch_count": sum(item["mismatch_count"] for item in rows),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# official strategy-8 最优回放与 overlap 代理对照",
        "",
        "| 层名 | baseline opt | official best | official 节省 | overlap 代理 opt | 代理节省 | official/代理 | 剩余缺口 | mismatch |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in report["rows"]:
        ratio = row["official_capture_ratio_vs_proxy"] if row["official_capture_ratio_vs_proxy"] is not None else 0.0
        lines.append(
            "| `{layer}` | {base:,} | {official:,} | {official_save:,} | {proxy:,} | {proxy_save:,} | {ratio:.5f} | {gap:,} | {mismatch} |".format(
                layer=row["layer_name"],
                base=row["baseline_opt_cycles"],
                official=row["official_best_opt_cycles"],
                official_save=row["official_best_saving"],
                proxy=row["overlap_proxy_opt_cycles"],
                proxy_save=row["overlap_proxy_saving"],
                ratio=ratio,
                gap=row["remaining_gap_to_proxy"],
                mismatch=row["mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## 总量",
            "",
            f"- official 最优总节省：`{report['totals']['official_best_saving']:,}`",
            f"- overlap 代理总节省：`{report['totals']['overlap_proxy_saving']:,}`",
            f"- official 吃到代理比例：`{report['totals']['official_capture_ratio_vs_proxy']:.5f}`",
            f"- 剩余缺口：`{report['totals']['remaining_gap_to_proxy']:,}`",
            f"- total_mismatch_count：`{report['totals']['total_mismatch_count']}`",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        baseline=load_json(args.baseline_json),
        official_best=load_json(args.official_best_json),
        overlap=load_json(args.overlap_json),
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
