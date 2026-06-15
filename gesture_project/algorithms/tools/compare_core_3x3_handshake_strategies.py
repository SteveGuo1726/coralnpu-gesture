"""对比任意核心 3x3 层握手级控制器的 reload / row_resident 策略。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reload_json", required=True, help="reload 策略 JSON。")
    parser.add_argument("--row_resident_json", required=True, help="row_resident 策略 JSON。")
    parser.add_argument("--out_json", required=True, help="输出对比 JSON。")
    parser.add_argument("--out_md", required=True, help="输出对比 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_compare(reload_report: dict[str, Any], row_report: dict[str, Any]) -> dict[str, Any]:
    reload_summary = reload_report["summary"]
    row_summary = row_report["summary"]
    return {
        "layer_name": reload_report["layer_name"],
        "shape": reload_report["shape"],
        "resource_model": reload_report["resource_model"],
        "reload": reload_summary,
        "row_resident": row_summary,
        "comparison": {
            "total_cycle_delta": int(row_summary["total_cycles"]) - int(reload_summary["total_cycles"]),
            "total_cycle_ratio": round(int(row_summary["total_cycles"]) / int(reload_summary["total_cycles"]), 4),
            "input_byte_delta": int(row_summary["bytes_summary"]["input_bytes"])
            - int(reload_summary["bytes_summary"]["input_bytes"]),
            "input_byte_ratio": round(
                int(row_summary["bytes_summary"]["input_bytes"])
                / int(reload_summary["bytes_summary"]["input_bytes"]),
                4,
            ),
            "weight_byte_delta": int(row_summary["bytes_summary"]["weight_bytes"])
            - int(reload_summary["bytes_summary"]["weight_bytes"]),
            "weight_byte_ratio": round(
                int(row_summary["bytes_summary"]["weight_bytes"])
                / int(reload_summary["bytes_summary"]["weight_bytes"]),
                4,
            ),
            "output_byte_delta": int(row_summary["bytes_summary"]["output_bytes"])
            - int(reload_summary["bytes_summary"]["output_bytes"]),
            "output_byte_ratio": round(
                int(row_summary["bytes_summary"]["output_bytes"])
                / int(reload_summary["bytes_summary"]["output_bytes"]),
                4,
            ),
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    reload_summary = report["reload"]
    row_summary = report["row_resident"]
    comparison = report["comparison"]
    layer_name = report["layer_name"]
    shape = report["shape"]
    lines = [
        f"# {layer_name} 握手级策略对比",
        "",
        f"- 层：`{layer_name}`",
        f"- 形状：`{shape}`",
        "- 在相同输入/weight/输出带宽与计算延迟约束下，对比 `reload` 与 `row_resident`。",
        "",
        "## 核心指标",
        "",
        "| 指标 | reload | row_resident | 对比 |",
        "| --- | ---: | ---: | ---: |",
        "| total cycles | {reload_cycles:,} | {row_cycles:,} | {ratio:.4f}x |".format(
            reload_cycles=reload_summary["total_cycles"],
            row_cycles=row_summary["total_cycles"],
            ratio=comparison["total_cycle_ratio"],
        ),
        "| input bytes | {reload_input:,} | {row_input:,} | {ratio:.4f}x |".format(
            reload_input=reload_summary["bytes_summary"]["input_bytes"],
            row_input=row_summary["bytes_summary"]["input_bytes"],
            ratio=comparison["input_byte_ratio"],
        ),
        "| weight bytes | {reload_weight:,} | {row_weight:,} | {ratio:.4f}x |".format(
            reload_weight=reload_summary["bytes_summary"]["weight_bytes"],
            row_weight=row_summary["bytes_summary"]["weight_bytes"],
            ratio=comparison["weight_byte_ratio"],
        ),
        "| output bytes | {reload_output:,} | {row_output:,} | {ratio:.4f}x |".format(
            reload_output=reload_summary["bytes_summary"]["output_bytes"],
            row_output=row_summary["bytes_summary"]["output_bytes"],
            ratio=comparison["output_byte_ratio"],
        ),
        "",
        "## 观察",
        "",
        f"- `row_resident` 相比 `reload` 总周期变化：`{comparison['total_cycle_delta']:+,}` cycle。",
        f"- `row_resident` 相比 `reload` 输入流量变化：`{comparison['input_byte_delta']:+,} B`。",
        f"- `row_resident` 相比 `reload` weight 流量变化：`{comparison['weight_byte_delta']:+,} B`。",
        f"- `row_resident` 相比 `reload` 输出流量变化：`{comparison['output_byte_delta']:+,} B`。",
        "",
        "## 资源 busy cycles",
        "",
        "| 资源 | reload | row_resident |",
        "| --- | ---: | ---: |",
    ]

    resources = sorted(
        set(reload_summary["resource_busy_cycles"].keys()) | set(row_summary["resource_busy_cycles"].keys())
    )
    for resource in resources:
        lines.append(
            "| `{resource}` | {reload_busy:,} | {row_busy:,} |".format(
                resource=resource,
                reload_busy=reload_summary["resource_busy_cycles"].get(resource, 0),
                row_busy=row_summary["resource_busy_cycles"].get(resource, 0),
            )
        )

    lines.extend(
        [
            "",
            "## 关键 stall",
            "",
            "| 原因 | reload | row_resident |",
            "| --- | ---: | ---: |",
        ]
    )

    stall_reasons = sorted(
        set(reload_summary["stall_cycles_by_reason"].keys()) | set(row_summary["stall_cycles_by_reason"].keys())
    )
    for reason in stall_reasons:
        lines.append(
            "| `{reason}` | {reload_stall:,} | {row_stall:,} |".format(
                reason=reason,
                reload_stall=reload_summary["stall_cycles_by_reason"].get(reason, 0),
                row_stall=row_summary["stall_cycles_by_reason"].get(reason, 0),
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    reload_report = load_json(args.reload_json)
    row_report = load_json(args.row_resident_json)
    report = build_compare(reload_report, row_report)

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
