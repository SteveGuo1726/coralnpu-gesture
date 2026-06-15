"""Compare gesture-recognition model candidates with static MAC estimates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def conv2d(name: str, h: int, w: int, in_c: int, out_c: int, k: int, stride: int = 1) -> dict:
    out_h = h // stride
    out_w = w // stride
    return {
        "name": name,
        "op": "CONV_2D",
        "kernel": [k, k],
        "input_shape": [1, h, w, in_c],
        "output_shape": [1, out_h, out_w, out_c],
        "macs": out_h * out_w * out_c * k * k * in_c,
    }


def depthwise(name: str, h: int, w: int, c: int, k: int = 3, stride: int = 1) -> dict:
    out_h = h // stride
    out_w = w // stride
    return {
        "name": name,
        "op": "DEPTHWISE_CONV_2D",
        "kernel": [k, k],
        "input_shape": [1, h, w, c],
        "output_shape": [1, out_h, out_w, c],
        "macs": out_h * out_w * c * k * k,
    }


def dense(name: str, in_c: int, out_c: int) -> dict:
    return {
        "name": name,
        "op": "FULLY_CONNECTED",
        "input_shape": [1, in_c],
        "output_shape": [1, out_c],
        "macs": in_c * out_c,
    }


def static_cnn_v1(image_size: int, classes: int) -> list[dict]:
    h = image_size
    w = image_size
    layers = [
        conv2d("conv1_3x3_a", h, w, 3, 16, 3),
        conv2d("conv1_3x3_b", h, w, 16, 16, 3),
    ]
    h //= 2
    w //= 2
    layers += [
        conv2d("conv2_3x3_a", h, w, 16, 32, 3),
        conv2d("conv2_3x3_b", h, w, 32, 32, 3),
    ]
    h //= 2
    w //= 2
    layers += [
        conv2d("conv3_3x3_a", h, w, 32, 64, 3),
        conv2d("conv3_3x3_b", h, w, 64, 64, 3),
    ]
    h //= 2
    w //= 2
    layers += [
        conv2d("conv_head_1x1", h, w, 64, 96, 1),
        dense("classifier", 96, classes),
    ]
    return layers


def depthwise_cnn_v1(image_size: int, classes: int, alpha: float = 0.5) -> list[dict]:
    def c(value: int) -> int:
        return max(8, int(value * alpha))

    h = image_size
    w = image_size
    layers = [conv2d("stem_3x3_s2", h, w, 3, c(32), 3, stride=2)]
    h //= 2
    w //= 2
    specs = [
        (64, 1),
        (128, 2),
        (128, 1),
        (256, 2),
        (256, 1),
        (512, 2),
        (512, 1),
        (512, 1),
    ]
    in_c = c(32)
    for idx, (out_c_base, stride) in enumerate(specs, start=1):
        out_c = c(out_c_base)
        layers.append(depthwise(f"dw{idx}_3x3_s{stride}", h, w, in_c, stride=stride))
        h //= stride
        w //= stride
        layers.append(conv2d(f"pw{idx}_1x1", h, w, in_c, out_c, 1))
        in_c = out_c
    layers.append(dense("classifier", in_c, classes))
    return layers


def mobilenet_v1_025_64(classes: int) -> list[dict]:
    return depthwise_cnn_v1(64, classes, alpha=0.25)


def mobilenet_v1_050_96(classes: int) -> list[dict]:
    return depthwise_cnn_v1(96, classes, alpha=0.5)


def pointwise_tcn_keypoint(classes: int, frames: int = 16, landmarks: int = 21) -> list[dict]:
    features = landmarks * 3
    layers = [
        {
            "name": "input_keypoints",
            "op": "KEYPOINT_PREPROCESS",
            "input_shape": [1, frames, landmarks, 3],
            "output_shape": [1, frames, features],
            "macs": 0,
        },
        {
            "name": "tcn1_k3",
            "op": "CONV_1D",
            "kernel": [3],
            "input_shape": [1, frames, features],
            "output_shape": [1, frames, 64],
            "macs": frames * 64 * features * 3,
        },
        {
            "name": "tcn2_k3",
            "op": "CONV_1D",
            "kernel": [3],
            "input_shape": [1, frames, 64],
            "output_shape": [1, frames, 64],
            "macs": frames * 64 * 64 * 3,
        },
        dense("classifier", 64, classes),
    ]
    return layers


def summarize(name: str, family: str, layers: list[dict], notes: str) -> dict:
    totals_by_op: dict[str, int] = {}
    conv2d_1x1_macs = 0
    conv2d_3x3_macs = 0
    other_conv2d_macs = 0
    for layer in layers:
        totals_by_op[layer["op"]] = totals_by_op.get(layer["op"], 0) + layer["macs"]
        if layer["op"] == "CONV_2D":
            kernel = layer.get("kernel")
            if kernel == [1, 1]:
                conv2d_1x1_macs += layer["macs"]
            elif kernel == [3, 3]:
                conv2d_3x3_macs += layer["macs"]
            else:
                other_conv2d_macs += layer["macs"]
    total_macs = sum(totals_by_op.values())
    conv_macs = totals_by_op.get("CONV_2D", 0)
    depthwise_macs = totals_by_op.get("DEPTHWISE_CONV_2D", 0)
    return {
        "name": name,
        "family": family,
        "notes": notes,
        "layers": layers,
        "totals": {
            "total_macs": total_macs,
            "by_op": totals_by_op,
            "conv2d_mac_ratio": conv_macs / total_macs if total_macs else 0,
            "conv2d_3x3_macs": conv2d_3x3_macs,
            "conv2d_1x1_macs": conv2d_1x1_macs,
            "other_conv2d_macs": other_conv2d_macs,
            "conv2d_3x3_mac_ratio": conv2d_3x3_macs / total_macs if total_macs else 0,
            "conv2d_1x1_mac_ratio": conv2d_1x1_macs / total_macs if total_macs else 0,
            "depthwise_mac_ratio": depthwise_macs / total_macs if total_macs else 0,
            "layer_count": len(layers),
        },
    }


def candidates(classes: int) -> list[dict]:
    return [
        summarize(
            "gesture_static_cnn_v1_64",
            "standard_3x3_cnn",
            static_cnn_v1(64, classes),
            "当前项目基线；最能验证标准 3x3 Conv2D 优化。",
        ),
        summarize(
            "mobilenet_v1_0.25_64",
            "depthwise_separable_cnn",
            mobilenet_v1_025_64(classes),
            "MobileNetV1 风格；贴近 Coral NPU 官方示例，依赖 DepthwiseConv + 1x1 Conv。",
        ),
        summarize(
            "mobilenet_v1_0.50_96",
            "depthwise_separable_cnn",
            mobilenet_v1_050_96(classes),
            "更高容量的 MobileNetV1 风格候选；用于准确率优先时对比。",
        ),
        summarize(
            "keypoint_tcn_16f",
            "keypoint_temporal",
            pointwise_tcn_keypoint(classes),
            "MediaPipe/关键点路线的轻量时序分类器；NPU 卷积验证价值较弱，但端到端可能很省。",
        ),
    ]


def write_markdown(report: dict, out_path: Path) -> None:
    lines = [
        "# 手势识别候选模型静态对比",
        "",
        "该报告只统计结构级 MAC 和算子构成，不代表真实准确率。真实选择需要继续结合训练、INT8 量化和 NPUSim。",
        "",
        "| 模型 | 路线 | 总 MACs | 3x3 Conv2D | 1x1 Conv2D | Depthwise | 层数 | 备注 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for item in report["candidates"]:
        totals = item["totals"]
        lines.append(
            "| {name} | {family} | {macs:,} | {conv3:.1%} | {conv1:.1%} | {dw:.1%} | {layers} | {notes} |".format(
                name=item["name"],
                family=item["family"],
                macs=totals["total_macs"],
                conv3=totals["conv2d_3x3_mac_ratio"],
                conv1=totals["conv2d_1x1_mac_ratio"],
                dw=totals["depthwise_mac_ratio"],
                layers=totals["layer_count"],
                notes=item["notes"],
            )
        )
    lines += [
        "",
        "## 初步判断",
        "",
        "- `gesture_static_cnn_v1_64` 适合作为 3x3 Conv2D 硬件优化验证主线，因为标准 Conv2D 占比最高。",
        "- `mobilenet_v1_0.25_64` 和 `mobilenet_v1_0.50_96` 必须纳入比对，因为 Coral NPU 官方已有 MobileNet/DepthwiseConv 示例，且 DepthwiseConv 当前 NPUSim 优化效果明显。",
        "- MobileNet 风格模型的主要 Conv2D MAC 来自 1x1 pointwise conv；当前 1x1 NPUSim 只有约 2.04x 到 2.07x，相比 3x3/DepthwiseConv 仍是硬件缺口。",
        "- `keypoint_tcn_16f` 可能端到端计算量最低，但依赖关键点检测前端，对当前 NPU 3x3 卷积优化验证价值较弱。",
        "- 最终优解不应只由 MAC 数决定，还要看数据集准确率、INT8 精度损失、TFLM 支持情况、NPUSim 周期和工程展示难度。",
        "",
        "## 当前 NPUSim 约束",
        "",
        "- 3x3 Conv2D：`gesture_static_cnn_v1` 六个真实 3x3 层整体约 21.41x。",
        "- DepthwiseConv：现有 microbenchmark 约 20x 到 35x。",
        "- 1x1 Conv2D：新增 pointwise 基线约 2.04x 到 2.07x，说明 MobileNet 的 pointwise 部分不能只看 MAC 数低估成本。",
        "",
    ]
    out_path.write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--classes", type=int, default=10)
    parser.add_argument("--json_out", required=True)
    parser.add_argument("--md_out", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    report = {
        "classes": args.classes,
        "candidates": candidates(args.classes),
    }
    json_path = Path(args.json_out).resolve()
    md_path = Path(args.md_out).resolve()
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    write_markdown(report, md_path)
    print(f"Wrote {json_path}")
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
