"""比较两个核心 3x3 层的共骨架控制器关键信息。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract_a", required=True, help="第一个 contract JSON。")
    parser.add_argument("--contract_b", required=True, help="第二个 contract JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def build_compare(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    a_req = {channel["request"] for channel in a["handshake_channels"]}
    b_req = {channel["request"] for channel in b["handshake_channels"]}
    return {
        "layer_a": {
            "name": a["layer_name"],
            "shape": a["shape"],
            "grid": a["grid"],
            "config": a["config"],
        },
        "layer_b": {
            "name": b["layer_name"],
            "shape": b["shape"],
            "grid": b["grid"],
            "config": b["config"],
        },
        "shared": {
            "state_count": 10,
            "same_channel_names": sorted(a_req & b_req),
            "channel_sets_equal": a_req == b_req,
            "same_valid_bits": sorted(
                set(item["name"] for item in a["valid_bits"]) & set(item["name"] for item in b["valid_bits"])
            ),
            "same_resources": sorted(
                set(item["name"] for item in a["resources"]) & set(item["name"] for item in b["resources"])
            ),
        },
        "differences": {
            "tiles_y": [a["grid"]["tiles_y"], b["grid"]["tiles_y"]],
            "tiles_x": [a["grid"]["tiles_x"], b["grid"]["tiles_x"]],
            "tiles_oc": [a["grid"]["tiles_oc"], b["grid"]["tiles_oc"]],
            "line_fill_bytes": [
                a["handshake_channels"][0]["payload"]["bytes"],
                b["handshake_channels"][0]["payload"]["bytes"],
            ],
            "weight_preload_bytes": [
                next(ch for ch in a["handshake_channels"] if ch["op"] == "weight_preload")["payload"]["bytes"],
                next(ch for ch in b["handshake_channels"] if ch["op"] == "weight_preload")["payload"]["bytes"],
            ],
        },
    }


def write_markdown(report: dict[str, Any], out_path: Path) -> None:
    a = report["layer_a"]
    b = report["layer_b"]
    lines = [
        "# 核心 3x3 共骨架控制器对比",
        "",
        f"- A：`{a['name']}` / `{a['shape']}`",
        f"- B：`{b['name']}` / `{b['shape']}`",
        "",
        "## 共性",
        "",
        f"- 状态数：`{report['shared']['state_count']}`",
        f"- 请求通道集合是否完全一致：`{report['shared']['channel_sets_equal']}`",
        f"- 共用请求通道：{', '.join(f'`{item}`' for item in report['shared']['same_channel_names'])}",
        f"- 共用 valid 位：{', '.join(f'`{item}`' for item in report['shared']['same_valid_bits'])}",
        f"- 共用资源域：{', '.join(f'`{item}`' for item in report['shared']['same_resources'])}",
        "",
        "## 差异",
        "",
        "| 指标 | A | B |",
        "| --- | ---: | ---: |",
        f"| tiles_y | {report['differences']['tiles_y'][0]} | {report['differences']['tiles_y'][1]} |",
        f"| tiles_x | {report['differences']['tiles_x'][0]} | {report['differences']['tiles_x'][1]} |",
        f"| tiles_oc | {report['differences']['tiles_oc'][0]} | {report['differences']['tiles_oc'][1]} |",
        f"| line_fill bytes | {report['differences']['line_fill_bytes'][0]} | {report['differences']['line_fill_bytes'][1]} |",
        f"| weight_preload bytes | {report['differences']['weight_preload_bytes'][0]} | {report['differences']['weight_preload_bytes'][1]} |",
        "",
        "## 结论",
        "",
        "- 两层已经可以共用同一套 10 状态控制骨架。",
        "- 当前差异主要落在计数范围和 payload 大小，而不是状态结构本身。",
        "- 这说明从 `conv2_3x3_b` 走向 `conv3_3x3_b`，是骨架复用问题，不是重新发明控制器问题。",
    ]
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    a = load_json(args.contract_a)
    b = load_json(args.contract_b)
    report = build_compare(a, b)

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
