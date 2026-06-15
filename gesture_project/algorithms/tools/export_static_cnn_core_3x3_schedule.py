"""从核心 3x3 握手收益报告里导出指定层的 schedule。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--impact_json", required=True, help="核心 3x3 握手收益 JSON。")
    parser.add_argument("--layer_name", required=True, help="目标层名。")
    parser.add_argument("--out_json", required=True, help="输出 schedule JSON。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> None:
    args = parse_args()
    report = load_json(args.impact_json)
    match = next((item for item in report["layers"] if item["layer_name"] == args.layer_name), None)
    if match is None:
        raise SystemExit(f"Layer not found: {args.layer_name}")

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(match["schedule"], ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_json}")


if __name__ == "__main__":
    main()
