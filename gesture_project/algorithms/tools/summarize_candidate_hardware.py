"""Summarize model candidates with accuracy and hardware-oriented metrics."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        required=True,
        help="JSON config listing candidate models and their report files.",
    )
    parser.add_argument("--out_json", required=True, help="Output JSON summary path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown summary path.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def pct_str(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 100:.2f}%"


def num_str(value: int | float | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, float) and not value.is_integer():
        return f"{value:.2f}"
    return f"{int(value):,}"


def x_str(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


def brief_model_path(path_text: str) -> str:
    path = Path(path_text)
    try:
        models_idx = path.parts.index("models")
        return "/".join(path.parts[models_idx:])
    except ValueError:
        return path.name


def classify_priority(candidate: dict[str, Any]) -> str:
    int8_acc = candidate.get("tflite_accuracy")
    speedup = candidate.get("total_speedup")
    dominant = candidate.get("dominant_category")
    if int8_acc is None or speedup is None:
        return "信息不完整，不能进入 RTL 优先判断"
    if int8_acc >= 0.70 and speedup >= 10.0 and dominant == "conv2d_3x3":
        return "进入 3x3 RTL 主线"
    if speedup < 5.0 and dominant == "conv2d_1x1":
        return "保留为 1x1 次级基准"
    return "保留观察，不进入当前 RTL 主线"


def build_candidate(item: dict[str, Any], base_dir: Path) -> dict[str, Any]:
    keras_eval = load_json((base_dir / item["keras_eval"]).resolve())
    tflite_eval = load_json((base_dir / item["tflite_eval"]).resolve())
    ops = load_json((base_dir / item["tflite_ops"]).resolve())
    cycles = load_json((base_dir / item["npucycles"]).resolve())
    hotspots = load_json((base_dir / item["hotspots"]).resolve())

    conv2d_macs = 0
    depthwise_macs = 0
    for op in ops.get("operators", []):
        macs = int(op.get("estimated_macs") or 0)
        if op.get("op_name") == "CONV_2D":
            conv2d_macs += macs
        elif op.get("op_name") == "DEPTHWISE_CONV_2D":
            depthwise_macs += macs

    categories = hotspots.get("categories", [])
    top_hotspots = hotspots.get("top_hotspots_by_optimized_cycles", [])
    dominant_category = categories[0]["category"] if categories else None
    top_hotspot = top_hotspots[0] if top_hotspots else None

    candidate = {
        "name": item["name"],
        "family": item.get("family", ""),
        "notes": item.get("notes", ""),
        "model_path": brief_model_path(tflite_eval.get("model", "")),
        "keras_accuracy": keras_eval.get("accuracy"),
        "tflite_accuracy": tflite_eval.get("accuracy"),
        "accuracy_drop_pct": None,
        "conv2d_macs": conv2d_macs,
        "depthwise_macs": depthwise_macs,
        "total_reference_cycles": cycles.get("total_reference_cycles"),
        "total_optimized_cycles": cycles.get("total_optimized_cycles"),
        "total_speedup": cycles.get("total_speedup"),
        "dominant_category": dominant_category,
        "dominant_category_cycle_share_pct": (
            categories[0].get("optimized_cycle_share_pct") if categories else None
        ),
        "top_hotspot_shape": top_hotspot.get("shape_signature") if top_hotspot else None,
        "top_hotspot_cycle_share_pct": (
            top_hotspot.get("optimized_cycle_share_pct") if top_hotspot else None
        ),
        "top_hotspot_speedup": top_hotspot.get("estimated_speedup") if top_hotspot else None,
        "categories": categories,
    }
    if candidate["keras_accuracy"] is not None and candidate["tflite_accuracy"] is not None:
        candidate["accuracy_drop_pct"] = (
            candidate["keras_accuracy"] - candidate["tflite_accuracy"]
        ) * 100.0
    candidate["rtl_priority"] = classify_priority(candidate)
    return candidate


def build_summary(config: dict[str, Any], config_path: Path) -> dict[str, Any]:
    base_dir = config_path.parent
    candidates = [build_candidate(item, base_dir) for item in config["candidates"]]
    candidates.sort(
        key=lambda item: (
            item["rtl_priority"] != "进入 3x3 RTL 主线",
            -(item.get("tflite_accuracy") or -1.0),
            -(item.get("total_speedup") or -1.0),
        )
    )
    return {
        "title": config.get("title", "候选模型硬件优先汇总"),
        "dataset": config.get("dataset", ""),
        "candidates": candidates,
    }


def write_markdown(summary: dict[str, Any], out_path: Path) -> None:
    lines = [
        f"# {summary['title']}",
        "",
        "## 评估口径",
        "",
        "统一按照下面链路判断候选是否值得继续投入：",
        "",
        "```text",
        "Keras test accuracy -> INT8 TFLite test accuracy -> TFLite 算子结构 -> NPU 周期估算 -> RTL 优先级",
        "```",
        "",
    ]
    if summary.get("dataset"):
        lines.extend(
            [
                "数据集：",
                "",
                f"- `{summary['dataset']}`",
                "",
            ]
        )

    lines.extend(
        [
            "## 总表",
            "",
            "| 模型 | Keras | INT8 | 量化损失 | Conv2D MAC | Depthwise MAC | 估算加速 | 主导瓶颈 | 当前判断 |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
        ]
    )
    for item in summary["candidates"]:
        lines.append(
            "| {name} | {keras} | {tflite} | {drop} | {conv} | {dw} | {speedup} | {dominant} | {priority} |".format(
                name=item["name"],
                keras=pct_str(item.get("keras_accuracy")),
                tflite=pct_str(item.get("tflite_accuracy")),
                drop="-" if item.get("accuracy_drop_pct") is None else f"{item['accuracy_drop_pct']:.2f} pct",
                conv=num_str(item.get("conv2d_macs")),
                dw=num_str(item.get("depthwise_macs")),
                speedup=x_str(item.get("total_speedup")),
                dominant=item.get("dominant_category") or "-",
                priority=item["rtl_priority"],
            )
        )

    lines.extend(["", "## 候选细节", ""])
    for item in summary["candidates"]:
        lines.extend(
            [
                f"### {item['name']}",
                "",
                f"- 模型文件：`{item['model_path']}`",
                f"- 模型族：`{item['family'] or '-'}`",
                f"- Keras / INT8：`{pct_str(item.get('keras_accuracy'))}` / `{pct_str(item.get('tflite_accuracy'))}`",
                f"- 估算 reference / optimized cycles：`{num_str(item.get('total_reference_cycles'))}` / `{num_str(item.get('total_optimized_cycles'))}`",
                f"- 模型级估算加速：`{x_str(item.get('total_speedup'))}`",
                f"- 优化后主导类别：`{item.get('dominant_category') or '-'}`，周期占比 `"
                + (
                    "-"
                    if item.get("dominant_category_cycle_share_pct") is None
                    else f"{item['dominant_category_cycle_share_pct']:.2f}%"
                )
                + "`",
                f"- 最热点层：`{item.get('top_hotspot_shape') or '-'}`",
                f"- 最热点层优化后周期占比：`"
                + (
                    "-"
                    if item.get("top_hotspot_cycle_share_pct") is None
                    else f"{item['top_hotspot_cycle_share_pct']:.2f}%"
                )
                + "`",
                f"- 最热点层估算加速：`{x_str(item.get('top_hotspot_speedup'))}`",
                f"- 当前判断：`{item['rtl_priority']}`",
            ]
        )
        if item.get("notes"):
            lines.append(f"- 说明：{item['notes']}")
        lines.append("")

    lines.extend(
        [
            "## 当前结论",
            "",
            "- 后续算法实验不再只看验证精度，必须同时满足 INT8 精度和 NPU 周期收益才进入 RTL 视野。",
            "- 若候选主导瓶颈是 `conv2d_1x1` 且模型级加速明显偏低，就只保留为 pointwise 次级基准，不挤占 3x3 主线资源。",
            "- 若候选在 `3x3` 上保持高精度且模型级加速显著，就优先服务 `conv2_3x3_*` / `conv3_3x3_*` 的 RTL 迭代。",
            "",
        ]
    )

    out_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    config_path = Path(args.config).resolve()
    config = load_json(config_path)
    summary = build_summary(config, config_path)

    out_json = Path(args.out_json).resolve()
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    out_md = Path(args.out_md).resolve()
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(summary, out_md)

    print(f"Wrote {out_json}")
    print(f"Wrote {out_md}")
    print(f"Candidates summarized: {len(summary['candidates'])}")


if __name__ == "__main__":
    main()
