"""导出核心 3x3 层通用寄存器更新表与伪 RTL 骨架。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from core_3x3_handshake_codegen import (
    build_register_table,
    pseudo_sv_text,
    register_table_markdown,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract_json", required=True, help="握手级 contract JSON。")
    parser.add_argument("--out_json", required=True, help="输出寄存器更新表 JSON。")
    parser.add_argument("--out_md", required=True, help="输出寄存器更新表 Markdown。")
    parser.add_argument("--out_sv", required=True, help="输出伪 SystemVerilog 骨架。")
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> None:
    args = parse_args()
    contract = load_json(args.contract_json)
    table = build_register_table(contract)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(register_table_markdown(table), encoding="utf-8")

    out_sv = Path(args.out_sv).resolve()
    out_sv.parent.mkdir(parents=True, exist_ok=True)
    out_sv.write_text(pseudo_sv_text(contract, table), encoding="utf-8")

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")
    print(f"Wrote {out_sv}")


if __name__ == "__main__":
    main()
