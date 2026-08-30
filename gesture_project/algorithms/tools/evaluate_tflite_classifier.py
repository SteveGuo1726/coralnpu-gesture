"""Evaluate an int8/float TFLite image classifier on an image-folder split."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image


IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Input .tflite model.")
    parser.add_argument("--data_dir", required=True, help="Dataset split directory, e.g. .../test.")
    parser.add_argument("--labels", required=True, help="labels.txt written during training.")
    parser.add_argument("--out", required=True, help="Output JSON report.")
    parser.add_argument("--csv_out", help="Optional per-image prediction CSV.")
    parser.add_argument(
        "--batch_size",
        type=int,
        default=1,
        help="Fixed inference batch size. Requires a dynamic TFLite batch dimension when above one.",
    )
    parser.add_argument(
        "--op_resolver",
        choices=["builtin", "builtin_ref"],
        default="builtin",
        help="TFLite kernel set. builtin_ref bypasses CPU delegates for compatibility diagnosis.",
    )
    return parser.parse_args()


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Use gesture_project/algorithms/.venv/bin/python."
        ) from exc
    return tf


def read_labels(path: Path) -> list[str]:
    labels = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    labels = [label for label in labels if label]
    if not labels:
        raise SystemExit(f"No labels found in {path}")
    return labels


def list_images(data_dir: Path, labels: list[str]) -> list[tuple[Path, int]]:
    samples: list[tuple[Path, int]] = []
    for label_index, label in enumerate(labels):
        class_dir = data_dir / label
        if not class_dir.is_dir():
            raise SystemExit(f"Missing class directory: {class_dir}")
        for path in sorted(class_dir.rglob("*")):
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                samples.append((path, label_index))
    if not samples:
        raise SystemExit(f"No images found in {data_dir}")
    return samples


def quantize_input(image: np.ndarray, input_detail: dict) -> np.ndarray:
    dtype = input_detail["dtype"]
    if dtype == np.float32:
        return image.astype(np.float32)
    scale, zero_point = input_detail["quantization"]
    if not scale:
        raise SystemExit("Quantized model input is missing scale.")
    quantized = np.round(image / scale + zero_point)
    info = np.iinfo(dtype)
    return np.clip(quantized, info.min, info.max).astype(dtype)


def dequantize_output(output: np.ndarray, output_detail: dict) -> np.ndarray:
    if output_detail["dtype"] == np.float32:
        return output.astype(np.float32)
    scale, zero_point = output_detail["quantization"]
    if not scale:
        return output.astype(np.float32)
    return (output.astype(np.float32) - zero_point) * scale


def load_image(path: Path, height: int, width: int) -> np.ndarray:
    image = Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR)
    return np.asarray(image, dtype=np.float32)


def make_interpreter(tf, model_path: Path, resolver_name: str):
    resolver_type = (
        tf.lite.experimental.OpResolverType.BUILTIN_REF
        if resolver_name == "builtin_ref"
        else tf.lite.experimental.OpResolverType.BUILTIN
    )
    return tf.lite.Interpreter(
        model_path=str(model_path), experimental_op_resolver_type=resolver_type
    )


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()

    model_path = Path(args.model).resolve()
    data_dir = Path(args.data_dir).resolve()
    labels_path = Path(args.labels).resolve()
    out_path = Path(args.out).resolve()
    csv_path = Path(args.csv_out).resolve() if args.csv_out else None
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if csv_path:
        csv_path.parent.mkdir(parents=True, exist_ok=True)

    labels = read_labels(labels_path)
    samples = list_images(data_dir, labels)
    if args.batch_size <= 0:
        raise SystemExit("--batch_size must be positive.")

    interpreter = make_interpreter(tf, model_path, args.op_resolver)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    input_shape = [int(value) for value in input_detail["shape"]]
    if len(input_shape) != 4:
        raise SystemExit(f"Expected NHWC input, got {input_shape}")
    height, width, channels = input_shape[1], input_shape[2], input_shape[3]
    if channels != 3:
        raise SystemExit(f"Expected RGB input channels, got {channels}")
    if args.batch_size != input_shape[0]:
        signature = input_detail.get("shape_signature", input_detail["shape"])
        if int(signature[0]) != -1:
            raise SystemExit(
                f"Model has fixed batch {input_shape[0]}; cannot use --batch_size {args.batch_size}."
            )
        interpreter.resize_tensor_input(
            input_detail["index"], [args.batch_size, height, width, channels], strict=True
        )
        interpreter.allocate_tensors()
        input_detail = interpreter.get_input_details()[0]
        input_shape = [int(value) for value in input_detail["shape"]]
    output_detail = interpreter.get_output_details()[0]

    confusion = np.zeros((len(labels), len(labels)), dtype=np.int64)
    rows: list[dict[str, str | int | float]] | None = [] if csv_path else None
    correct = 0

    for start in range(0, len(samples), args.batch_size):
        batch = samples[start : start + args.batch_size]
        images = np.zeros(input_shape, dtype=np.float32)
        images[: len(batch)] = np.stack(
            [load_image(path, height, width) for path, _true_index in batch], axis=0
        )
        interpreter.set_tensor(input_detail["index"], quantize_input(images, input_detail))
        interpreter.invoke()
        scores_batch = dequantize_output(
            interpreter.get_tensor(output_detail["index"]), output_detail
        )
        for (path, true_index), scores in zip(batch, scores_batch[: len(batch)], strict=True):
            pred_index = int(np.argmax(scores))
            confusion[true_index, pred_index] += 1
            correct += int(pred_index == true_index)
            if rows is not None:
                rows.append(
                    {
                        "path": str(path),
                        "true_label": labels[true_index],
                        "pred_label": labels[pred_index],
                        "pred_score": float(scores[pred_index]),
                        "correct": int(pred_index == true_index),
                    }
                )

    per_class = {}
    for index, label in enumerate(labels):
        total = int(confusion[index].sum())
        class_correct = int(confusion[index, index])
        per_class[label] = {
            "total": total,
            "correct": class_correct,
            "accuracy": class_correct / total if total else None,
        }

    report = {
        "model": str(model_path),
        "data_dir": str(data_dir),
        "labels": labels,
        "input_shape": input_shape,
        "batch_size": args.batch_size,
        "op_resolver": args.op_resolver,
        "num_samples": len(samples),
        "accuracy": correct / len(samples),
        "correct": correct,
        "confusion_matrix": confusion.tolist(),
        "per_class": per_class,
    }
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    if csv_path:
        with csv_path.open("w", newline="", encoding="utf-8") as fp:
            writer = csv.DictWriter(
                fp,
                fieldnames=["path", "true_label", "pred_label", "pred_score", "correct"],
            )
            writer.writeheader()
        writer.writerows(rows or [])

    print(f"Wrote {out_path}")
    if csv_path:
        print(f"Wrote {csv_path}")
    print(f"Accuracy: {correct}/{len(samples)} = {correct / len(samples):.4f}")


if __name__ == "__main__":
    main()
