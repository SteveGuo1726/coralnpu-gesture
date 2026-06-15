"""比较 refined strategy-8 的真实回放收益与 row_resident 代理收益。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline_json", required=True, help="官方 worktree baseline 四层 JSON。")
    parser.add_argument("--candidate_json", required=True, help="refined strategy-8 四层 JSON。")
    parser.add_argument("--proxy_json", required=True, help="row_resident 代理收益 JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_report(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    proxy: dict[str, Any],
) -> dict[str, Any]:
    baseline_map = {item["layer_name"]: item for item in baseline["results"]}
    candidate_map = {item["layer_name"]: item for item in candidate["results"]}
    proxy_map = {item["layer_name"]: item for item in proxy["layers"]}

    rows = []
    total_actual_saving = 0
    total_proxy_saving = 0
    for layer_name in sorted(baseline_map):
        base_opt = int(baseline_map[layer_name]["opt_cycles"])
        cand_opt = int(candidate_map[layer_name]["opt_cycles"])
        actual_delta = cand_opt - base_opt
        actual_saving = -actual_delta

        proxy_delta = int(
            proxy_map[layer_name]["deployment_proxy"][
                "mapped_row_resident_cycle_delta_vs_baseline_opt"
            ]
        )
        proxy_saving = -proxy_delta
        uncovered_gap = proxy_saving - actual_saving
        capture_ratio = (actual_saving / proxy_saving) if proxy_saving > 0 else None

        rows.append(
            {
                "layer_name": layer_name,
                "baseline_opt_cycles": base_opt,
                "candidate_opt_cycles": cand_opt,
                "actual_cycle_delta": actual_delta,
                "actual_saving": actual_saving,
                "proxy_cycle_delta": proxy_delta,
                "proxy_saving": proxy_saving,
                "capture_ratio_vs_proxy": capture_ratio,
                "remaining_gap_vs_proxy": uncovered_gap,
                "mismatch_count": int(candidate_map[layer_name]["mismatch_count"]),
            }
        )
        total_actual_saving += actual_saving
        total_proxy_saving += proxy_saving

    total_gap = total_proxy_saving - total_actual_saving
    return {
        "model": baseline.get("model", "unknown"),
        "scope": "Refined strategy-8 vs row_resident deployment proxy",
        "rows": rows,
        "totals": {
            "actual_saving": total_actual_saving,
            "proxy_saving": total_proxy_saving,
            "capture_ratio_vs_proxy": (
                total_actual_saving / total_proxy_saving if total_proxy_saving > 0 else None
            ),
            "remaining_gap_vs_proxy": total_gap,
            "total_mismatch_count": sum(item["mismatch_count"] for item in rows),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    lines = [
        "# refined strategy-8 与 row_resident 代理收益对照",
        "",
        "| 层名 | baseline opt | strategy-8 opt | 真实节省 | 代理节省 | 吃到代理比例 | 剩余缺口 | mismatch |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in report["rows"]:
        lines.append(
            "| `{layer}` | {base:,} | {cand:,} | {actual:,} | {proxy:,} | {ratio:.5f} | {gap:,} | {mismatch} |".format(
                layer=item["layer_name"],
                base=item["baseline_opt_cycles"],
                cand=item["candidate_opt_cycles"],
                actual=item["actual_saving"],
                proxy=item["proxy_saving"],
                ratio=item["capture_ratio_vs_proxy"] if item["capture_ratio_vs_proxy"] is not None else 0.0,
                gap=item["remaining_gap_vs_proxy"],
                mismatch=item["mismatch_count"],
            )
        )

    lines.extend(
        [
            "",
            "## 总量",
            "",
            f"- 真实总节省：`{report['totals']['actual_saving']:,}`",
            f"- 代理总节省：`{report['totals']['proxy_saving']:,}`",
            f"- 吃到代理比例：`{report['totals']['capture_ratio_vs_proxy']:.5f}`",
            f"- 剩余缺口：`{report['totals']['remaining_gap_vs_proxy']:,}`",
            f"- total_mismatch_count：`{report['totals']['total_mismatch_count']}`",
        ]
    )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    report = build_report(
        load_json(args.baseline_json),
        load_json(args.candidate_json),
        load_json(args.proxy_json),
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
