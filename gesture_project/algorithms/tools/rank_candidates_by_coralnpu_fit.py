"""Rank gesture-model candidates by CoralNPU official-fit evidence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


FIT_WEIGHTS = {
    "conv2d_4x4": 1.00,
    "depthwise_3x3": 0.86,
    "conv2d_1x1": 0.52,
    "conv2d_3x3": 0.38,
    "conv1d_3": 0.24,
    "dense": 0.22,
    "recurrent": 0.18,
    "host_fusion": 0.08,
    "other": 0.10,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, help="Candidate config JSON.")
    parser.add_argument("--out_json", required=True, help="Output JSON summary path.")
    parser.add_argument("--out_md", required=True, help="Output Markdown summary path.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def read_accuracy_report(path: Path) -> dict[str, Any]:
    report = load_json(path)
    accuracy = report.get("test_accuracy")
    if accuracy is None:
        accuracy = report.get("accuracy")
    return {
        "accuracy": accuracy,
        "raw": report,
    }


def normalized_profile(profile: dict[str, float]) -> dict[str, float]:
    total = float(sum(profile.values()))
    if total <= 0:
        return {}
    return {key: float(value) / total for key, value in profile.items()}


def kernel_from_op(op: dict[str, Any]) -> tuple[int, int] | None:
    input_shapes = op.get("input_shapes") or []
    if len(input_shapes) < 2:
        return None
    weight_shape = input_shapes[1]
    if not isinstance(weight_shape, list):
        return None
    if op.get("op_name") == "CONV_2D" and len(weight_shape) == 4:
        return int(weight_shape[1]), int(weight_shape[2])
    if op.get("op_name") == "DEPTHWISE_CONV_2D" and len(weight_shape) == 4:
        return int(weight_shape[1]), int(weight_shape[2])
    return None


def channels_from_op(op: dict[str, Any]) -> tuple[int | None, int | None]:
    input_shapes = op.get("input_shapes") or []
    output_shapes = op.get("output_shapes") or []
    in_channels = None
    out_channels = None
    if input_shapes and isinstance(input_shapes[0], list) and len(input_shapes[0]) >= 4:
        in_channels = int(input_shapes[0][3])
    if output_shapes and isinstance(output_shapes[0], list) and len(output_shapes[0]) >= 4:
        out_channels = int(output_shapes[0][3])
    return in_channels, out_channels


def fit_bucket_from_op(op: dict[str, Any]) -> str:
    op_name = op.get("op_name")
    kernel = kernel_from_op(op)
    if op_name == "CONV_2D":
        if kernel == (4, 4):
            return "conv2d_4x4"
        if kernel == (3, 3):
            return "conv2d_3x3"
        if kernel == (1, 1):
            return "conv2d_1x1"
    if op_name == "DEPTHWISE_CONV_2D" and kernel == (3, 3):
        return "depthwise_3x3"
    return "other"


def summarize_tflite_ops(ops_report: dict[str, Any]) -> dict[str, Any]:
    operators = ops_report.get("operators", [])
    total_macs = 0
    profile: dict[str, float] = {}
    align16_macs = 0
    align8_macs = 0
    for op in operators:
        macs = int(op.get("estimated_macs") or 0)
        if macs <= 0:
            continue
        total_macs += macs
        bucket = fit_bucket_from_op(op)
        profile[bucket] = profile.get(bucket, 0) + macs
        in_channels, out_channels = channels_from_op(op)
        if in_channels and out_channels:
            if in_channels % 16 == 0 and out_channels % 16 == 0:
                align16_macs += macs
            elif in_channels % 8 == 0 and out_channels % 8 == 0:
                align8_macs += macs
    ratio_profile = normalized_profile(profile)
    align16_ratio = align16_macs / total_macs if total_macs else 0.0
    align8_ratio = align8_macs / total_macs if total_macs else 0.0
    return {
        "total_macs": total_macs,
        "fit_profile": ratio_profile,
        "align16_ratio": align16_ratio,
        "align8_ratio": align8_ratio,
    }


def official_fit_score(fit_profile: dict[str, float], align16_ratio: float, align8_ratio: float) -> float:
    base = 0.0
    for key, ratio in fit_profile.items():
        base += FIT_WEIGHTS.get(key, FIT_WEIGHTS["other"]) * ratio
    alignment = 0.7 * align16_ratio + 0.3 * max(align8_ratio - align16_ratio, 0.0)
    score = 100.0 * min(1.0, 0.85 * base + 0.15 * alignment)
    return round(score, 2)


def speedup_score(speedup: float | None) -> float | None:
    if speedup is None:
        return None
    return round(min(speedup / 25.0, 1.0) * 100.0, 2)


def recommendation(candidate: dict[str, Any]) -> str:
    if candidate["type"] == "measured_accuracy_only":
        if (candidate.get("accuracy") or 0.0) >= 0.90:
            return "当前最高精度参考线，但不是当前纯 NPU 直跑主线"
        return "保留作融合或低算力对照，不作为当前 NPU 主线"

    if candidate["type"] == "prospective":
        if candidate["task"] == "dynamic":
            return "动态手势优先探索候选"
        if candidate["official_fit_score"] >= 70:
            return "优先进入下一轮新训练"
        return "保留为结构备选，暂不优先"

    accuracy = candidate.get("accuracy") or 0.0
    fit = candidate["official_fit_score"]
    speedup = candidate.get("measured_speedup") or 0.0
    if accuracy >= 0.75 and fit >= 30 and speedup >= 10.0:
        return "当前可直接推进的 NPU 图像主线"
    if fit >= 70:
        return "结构很贴官方，但当前任务精度仍需补训练"
    if candidate.get("dominant_fit_bucket") == "conv2d_1x1":
        return "1x1/瓶颈偏重，保留作次级对照"
    return "保留观察，不进入当前首发主线"


def dominant_fit_bucket(fit_profile: dict[str, float]) -> str | None:
    if not fit_profile:
        return None
    return max(fit_profile.items(), key=lambda item: item[1])[0]


def build_candidate(item: dict[str, Any], base_dir: Path) -> dict[str, Any]:
    candidate = {
        "name": item["name"],
        "type": item["type"],
        "task": item.get("task", ""),
        "family": item.get("family", ""),
        "notes": item.get("notes", ""),
    }

    if item["type"] == "measured_tflite":
        keras_eval = load_json((base_dir / item["keras_eval"]).resolve())
        tflite_eval = load_json((base_dir / item["tflite_eval"]).resolve())
        ops_report = load_json((base_dir / item["tflite_ops"]).resolve())
        cycle_report = load_json((base_dir / item["npucycles"]).resolve())
        ops_summary = summarize_tflite_ops(ops_report)
        fit_profile = ops_summary["fit_profile"]
        candidate.update(
            {
                "accuracy": tflite_eval.get("accuracy"),
                "keras_accuracy": keras_eval.get("accuracy"),
                "measured_speedup": cycle_report.get("total_speedup"),
                "optimized_cycles": cycle_report.get("total_optimized_cycles"),
                "reference_cycles": cycle_report.get("total_reference_cycles"),
                "fit_profile": fit_profile,
                "align16_ratio": ops_summary["align16_ratio"],
                "align8_ratio": ops_summary["align8_ratio"],
                "dominant_fit_bucket": dominant_fit_bucket(fit_profile),
            }
        )
    elif item["type"] == "measured_accuracy_only":
        accuracy_report = read_accuracy_report((base_dir / item["accuracy_report"]).resolve())
        fit_profile = normalized_profile(item.get("fit_profile", {}))
        candidate.update(
            {
                "accuracy": accuracy_report["accuracy"],
                "fit_profile": fit_profile,
                "align16_ratio": float(item.get("align16_ratio", 0.0)),
                "align8_ratio": float(item.get("align8_ratio", 0.0)),
                "dominant_fit_bucket": dominant_fit_bucket(fit_profile),
            }
        )
    elif item["type"] == "prospective":
        fit_profile = normalized_profile(item.get("fit_profile", {}))
        candidate.update(
            {
                "accuracy": item.get("accuracy"),
                "fit_profile": fit_profile,
                "align16_ratio": float(item.get("align16_ratio", 0.0)),
                "align8_ratio": float(item.get("align8_ratio", 0.0)),
                "dominant_fit_bucket": dominant_fit_bucket(fit_profile),
            }
        )
    else:
        raise SystemExit(f"Unsupported candidate type: {item['type']}")

    candidate["official_fit_score"] = official_fit_score(
        candidate["fit_profile"], candidate["align16_ratio"], candidate["align8_ratio"]
    )
    candidate["speedup_score"] = speedup_score(candidate.get("measured_speedup"))
    candidate["recommendation"] = recommendation(candidate)
    return candidate


def build_summary(config: dict[str, Any], config_path: Path) -> dict[str, Any]:
    base_dir = config_path.parent
    candidates = [build_candidate(item, base_dir) for item in config["candidates"]]
    candidates.sort(
        key=lambda item: (
            -item["official_fit_score"],
            -((item.get("accuracy") or -1.0) * 100.0),
            -((item.get("measured_speedup") or -1.0)),
        )
    )
    return {
        "title": config.get("title", "CoralNPU 适配候选排序"),
        "candidates": candidates,
    }


def pct(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 100:.2f}%"


def num(value: float | int | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, float) and not value.is_integer():
        return f"{value:.2f}"
    return f"{int(value):,}"


def fit_profile_str(profile: dict[str, float]) -> str:
    if not profile:
        return "-"
    items = sorted(profile.items(), key=lambda item: item[1], reverse=True)
    return ", ".join(f"{name} {ratio * 100:.1f}%" for name, ratio in items if ratio > 0)


def write_markdown(summary: dict[str, Any], out_path: Path) -> None:
    lines = [
        f"# {summary['title']}",
        "",
        "## 评分口径",
        "",
        "- `official_fit_score` 优先依据当前官方源码中已经明确存在的算子路径：标准 `4x4 Conv2D`、`3x3 depthwise`、一般 `1x1/3x3 Conv2D`、以及非卷积路线。",
        "- `accuracy` 优先看当前已有实测结果；没有实测的候选只给结构判断，不冒充真实精度。",
        "- `measured_speedup` 只在当前仓库已有周期报告时填入，用来补充判断，不覆盖官方适配优先级。",
        "",
        "## 总表",
        "",
        "| 候选 | 任务 | 类型 | 官方适配分 | 当前精度 | 已测加速 | 主导结构 | 当前建议 |",
        "| --- | --- | --- | ---: | ---: | ---: | --- | --- |",
    ]
    for item in summary["candidates"]:
        lines.append(
            "| {name} | {task} | {type} | {fit} | {acc} | {speedup} | {dominant} | {rec} |".format(
                name=item["name"],
                task=item["task"] or "-",
                type=item["type"],
                fit=num(item["official_fit_score"]),
                acc=pct(item.get("accuracy")),
                speedup=(
                    f"{item['measured_speedup']:.2f}x"
                    if item.get("measured_speedup") is not None
                    else "-"
                ),
                dominant=item.get("dominant_fit_bucket") or "-",
                rec=item["recommendation"],
            )
        )

    lines.extend(["", "## 逐项说明", ""])
    for item in summary["candidates"]:
        lines.extend(
            [
                f"### {item['name']}",
                "",
                f"- 任务：`{item['task'] or '-'}`",
                f"- 候选类型：`{item['type']}`",
                f"- 官方适配分：`{item['official_fit_score']:.2f}`",
                f"- 结构构成：{fit_profile_str(item['fit_profile'])}",
                f"- 通道 16 对齐占比：`{pct(item.get('align16_ratio'))}`",
                f"- 当前精度：`{pct(item.get('accuracy'))}`",
            ]
        )
        if item.get("keras_accuracy") is not None:
            lines.append(f"- Keras 精度：`{pct(item['keras_accuracy'])}`")
        if item.get("optimized_cycles") is not None:
            lines.append(
                f"- reference / optimized cycles：`{num(item['reference_cycles'])}` / `{num(item['optimized_cycles'])}`"
            )
        if item.get("measured_speedup") is not None:
            lines.append(f"- 已测加速：`{item['measured_speedup']:.2f}x`")
        lines.append(f"- 当前建议：{item['recommendation']}")
        if item.get("notes"):
            lines.append(f"- 说明：{item['notes']}")
        lines.append("")

    best_accuracy = max(
        [item for item in summary["candidates"] if item.get("accuracy") is not None],
        key=lambda item: item["accuracy"],
    )
    best_fit = max(summary["candidates"], key=lambda item: item["official_fit_score"])
    lines.extend(
        [
            "## 当前结论",
            "",
            f"- 当前最高精度线是 `{best_accuracy['name']}`，精度 `{pct(best_accuracy.get('accuracy'))}`，但它不等于当前最适合直接映射到 CoralNPU 的主线。",
            f"- 当前官方适配分最高的是 `{best_fit['name']}`，说明下一轮结构探索应优先围绕它对应的算子组成展开。",
            "- 静态图像路线不能只留一条：应并行保留 `现有 3x3 高精度基线` 和 `面向官方 4x4/Depthwise 路径的新候选`。",
            "- 动态手势路线建议先走 `关键点序列 + GRU/TCN`，先把准确率和时序判别能力做起来，再决定是否再引入图像流前端。",
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
    print(f"Candidates ranked: {len(summary['candidates'])}")


if __name__ == "__main__":
    main()
