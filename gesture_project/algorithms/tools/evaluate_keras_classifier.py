"""Evaluate a Keras image classifier on an image-folder split."""

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
    parser.add_argument("--model", required=True, help="Input .keras model.")
    parser.add_argument("--data_dir", required=True, help="Dataset split directory, e.g. .../test.")
    parser.add_argument("--labels", required=True, help="labels.txt written during training.")
    parser.add_argument("--out", required=True, help="Output JSON report.")
    parser.add_argument("--csv_out", help="Optional per-image prediction CSV.")
    parser.add_argument(
        "--batch_size",
        type=int,
        default=64,
        help="Batch size used for float-model evaluation.",
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


def load_image(path: Path, height: int, width: int) -> np.ndarray:
    image = Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR)
    return np.asarray(image, dtype=np.float32)


def batched(items: list[tuple[Path, int]], batch_size: int):
    for start in range(0, len(items), batch_size):
        yield items[start : start + batch_size]


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
    model = tf.keras.models.load_model(model_path)
    input_shape = model.input_shape
    if not isinstance(input_shape, (list, tuple)) or len(input_shape) != 4:
        raise SystemExit(f"Expected NHWC input, got {input_shape}")
    height, width = int(input_shape[1]), int(input_shape[2])

    confusion = np.zeros((len(labels), len(labels)), dtype=np.int64)
    rows: list[dict[str, str | int | float]] = []
    correct = 0

    for batch in batched(samples, args.batch_size):
        batch_images = np.stack(
            [load_image(path, height, width) for path, _ in batch],
            axis=0,
        )
        scores = model.predict(batch_images, verbose=0)
        pred_indices = np.argmax(scores, axis=1)
        for (path, true_index), pred_index, score_row in zip(batch, pred_indices, scores, strict=True):
            pred_index = int(pred_index)
            confusion[true_index, pred_index] += 1
            correct += int(pred_index == true_index)
            rows.append(
                {
                    "path": str(path),
                    "true_label": labels[true_index],
                    "pred_label": labels[pred_index],
                    "pred_score": float(score_row[pred_index]),
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
        "input_shape": [int(v) if v is not None else None for v in input_shape],
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
            writer.writerows(rows)

    print(f"Wrote {out_path}")
    if csv_path:
        print(f"Wrote {csv_path}")
    print(f"Accuracy: {correct}/{len(samples)} = {correct / len(samples):.4f}")


if __name__ == "__main__":
    main()
