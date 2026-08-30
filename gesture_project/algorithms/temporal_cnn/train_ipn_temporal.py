"""Train the project temporal CNN on IPN Hand JSONL manifests.

PROJECT_LOCAL_MOD: The model and training policy are project work, not an
official CoralNPU implementation. The script deliberately keeps the IPN
14-class label space, including the non-gesture class.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from gesture_temporal_model import TemporalModelConfig, build_gesture_temporal_model
from ipn_hand_sequence import IPNWindowSequence, read_manifest


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Use gesture_project/algorithms/.venv/bin/python."
        ) from exc
    return tf


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames_root", type=Path, required=True)
    parser.add_argument("--manifest_dir", type=Path, required=True)
    parser.add_argument("--output_dir", type=Path, required=True)
    parser.add_argument("--sequence_length", type=int, default=8)
    parser.add_argument("--frame_stride", type=int, default=2)
    parser.add_argument("--image_size", type=int, default=96)
    parser.add_argument("--batch_size", type=int, default=16)
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--early_stop_patience", type=int, default=10)
    parser.add_argument("--learning_rate", type=float, default=3e-4)
    parser.add_argument("--weight_decay", type=float, default=8e-4)
    parser.add_argument(
        "--architecture",
        choices=("legacy_shift", "coral3x3_bn"),
        default="legacy_shift",
        help="Project model variant; coral3x3_bn is the hardware candidate.",
    )
    parser.add_argument("--seed", type=int, default=20260814)
    parser.add_argument(
        "--no_class_weights",
        action="store_true",
        help="Disable inverse-frequency weights for an optimization diagnosis.",
    )
    parser.add_argument(
        "--balanced_samples_per_class",
        type=int,
        help="Sample this many clips per class for each training epoch.",
    )
    parser.add_argument(
        "--max_samples",
        type=int,
        help="Bounded training check only; do not use for reported accuracy.",
    )
    return parser.parse_args()


def class_weights(samples: list[dict], num_classes: int) -> dict[int, float]:
    counts = np.bincount([int(sample["label_index"]) for sample in samples], minlength=num_classes)
    present = counts > 0
    if not np.all(present):
        missing = np.flatnonzero(~present).tolist()
        raise ValueError(f"Training manifest has no samples for classes {missing}")
    total = counts.sum()
    return {index: float(total / (num_classes * count)) for index, count in enumerate(counts)}


def balanced_samples(samples: list[dict], samples_per_class: int, seed: int) -> list[dict]:
    """Build a bounded class-balanced epoch by sampling clip records."""
    if samples_per_class <= 0:
        raise ValueError("samples_per_class must be positive")
    groups: dict[int, list[dict]] = {}
    for sample in samples:
        groups.setdefault(int(sample["label_index"]), []).append(sample)
    if not groups or len(groups) != max(groups) + 1:
        raise ValueError("training labels must contain every class from zero")
    rng = np.random.default_rng(seed)
    output = []
    for label_index in sorted(groups):
        group = groups[label_index]
        choices = rng.choice(
            len(group),
            size=samples_per_class,
            replace=len(group) < samples_per_class,
        )
        output.extend(group[int(choice)] for choice in choices)
    rng.shuffle(output)
    return output


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()
    tf.keras.utils.set_random_seed(args.seed)
    frames_root = args.frames_root.resolve()
    manifest_dir = args.manifest_dir.resolve()
    if not frames_root.is_dir():
        raise SystemExit(f"Missing IPN frames root: {frames_root}")
    train_samples = read_manifest(manifest_dir / "train.jsonl")
    val_samples = read_manifest(manifest_dir / "val.jsonl")
    if args.max_samples is not None:
        if args.max_samples < 2:
            raise SystemExit("--max_samples must be at least 2")
        train_samples = train_samples[: args.max_samples]
        val_samples = val_samples[: max(1, min(len(val_samples), args.max_samples // 4))]
    original_train_samples = len(train_samples)
    if args.balanced_samples_per_class is not None:
        train_samples = balanced_samples(
            train_samples,
            args.balanced_samples_per_class,
            args.seed,
        )
    labels = (manifest_dir / "labels.txt").read_text(encoding="utf-8").splitlines()
    num_classes = len(labels)
    if num_classes != max(int(s["label_index"]) for s in train_samples + val_samples) + 1:
        raise SystemExit("labels.txt and manifest label indices disagree")

    config = TemporalModelConfig(
        image_size=args.image_size,
        sequence_length=args.sequence_length,
        num_classes=num_classes,
        architecture=args.architecture,
    )
    model = build_gesture_temporal_model(config)
    optimizer = tf.keras.optimizers.AdamW(
        learning_rate=args.learning_rate,
        weight_decay=args.weight_decay,
    )
    model.compile(
        optimizer=optimizer,
        loss=tf.keras.losses.SparseCategoricalCrossentropy(),
        metrics=[tf.keras.metrics.SparseCategoricalAccuracy(name="accuracy")],
    )
    train_sequence = IPNWindowSequence(
        train_samples,
        frames_root,
        args.batch_size,
        args.image_size,
        args.sequence_length,
        args.frame_stride,
        training=True,
        seed=args.seed,
    )
    val_sequence = IPNWindowSequence(
        val_samples,
        frames_root,
        args.batch_size,
        args.image_size,
        args.sequence_length,
        args.frame_stride,
        training=False,
        seed=args.seed + 1,
    )
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = output_dir / "best.weights.h5"
    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy",
            patience=args.early_stop_patience,
            mode="max",
            restore_best_weights=True,
        ),
        tf.keras.callbacks.ModelCheckpoint(
            checkpoint,
            monitor="val_accuracy",
            mode="max",
            save_best_only=True,
            save_weights_only=True,
        ),
    ]
    sample_class_weights = None if args.no_class_weights else class_weights(train_samples, num_classes)
    history = model.fit(
        train_sequence,
        validation_data=val_sequence,
        epochs=args.epochs,
        class_weight=sample_class_weights,
        callbacks=callbacks,
        verbose=2,
    )
    summary = {
        "dataset": "IPN Hand",
        "labels": labels,
        "train_samples": len(train_samples),
        "original_train_samples": original_train_samples,
        "val_samples": len(val_samples),
        "sequence_length": args.sequence_length,
        "frame_stride": args.frame_stride,
        "image_size": args.image_size,
        "architecture": args.architecture,
        "best_val_accuracy": float(max(history.history["val_accuracy"])),
        "epochs_run": len(history.history["loss"]),
        "checkpoint": str(checkpoint),
        "class_weights": sample_class_weights,
        "balanced_samples_per_class": args.balanced_samples_per_class,
    }
    (output_dir / "training_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
