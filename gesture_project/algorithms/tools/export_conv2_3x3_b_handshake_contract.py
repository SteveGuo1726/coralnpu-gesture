"""导出 conv2_3x3_b 4x8x8 握手级接口契约。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from core_3x3_handshake_codegen import build_contract, contract_markdown


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schedule_json", required=True, help="输入 tile schedule JSON。")
    parser.add_argument("--out_json", required=True, help="输出 JSON。")
    parser.add_argument("--out_md", required=True, help="输出 Markdown。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> None:
    args = parse_args()
    schedule = load_json(args.schedule_json)
    contract = build_contract(schedule)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(contract, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(contract_markdown(contract), encoding="utf-8")

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")


if __name__ == "__main__":
    main()
