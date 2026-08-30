"""Numerically verify project-side RepVGG branch folding before training.

PROJECT_LOCAL_MOD: This test builds a deterministic training-time model with
the optional 4x4 auxiliary 3x3 branches, exports it, and compares inference
probabilities on random images. It proves that the project-side training-only
branches introduce no deployment-graph change or border-coordinate error.
"""

from __future__ import annotations

import argparse
import tempfile
from argparse import Namespace
from pathlib import Path

import numpy as np

from export_repvgg_deploy import export_deploy_model
from train_static_cnn import build_model, require_tensorflow


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image_size", type=int, default=96)
    parser.add_argument("--batch_size", type=int, default=5)
    parser.add_argument("--tolerance", type=float, default=2e-5)
    return parser.parse_args()


def model_args(image_size: int) -> Namespace:
    return Namespace(
        image_size=image_size,
        optimizer="adamw",
        learning_rate=1e-3,
        grad_clipnorm=0.0,
        weight_decay=2e-4,
        augmentation_mode="none",
        dropout=0.30,
        width_multiplier=1.0,
        head_channels=112,
        body_kernel_size=3,
        body_kernel_schedule="",
        stage_channels="16,48,80",
        head_kernel_size=1,
        repvgg_branch_scale=1.0,
        repvgg_disable_identity=True,
        repvgg_4x4_aux_3x3=True,
        repvgg_kernel_schedule="3,4,4,1",
        repvgg_units_per_stage="1,1,1,0",
        variant="repvgg_hybrid",
    )


def main() -> None:
    args = parse_args()
    if args.batch_size <= 0 or args.image_size <= 0:
        raise SystemExit("--image_size and --batch_size must be positive.")
    tf = require_tensorflow()
    tf.keras.utils.set_random_seed(20260812)
    train_model = build_model(tf, model_args(args.image_size), num_classes=6)
    images = tf.random.stateless_uniform(
        (args.batch_size, args.image_size, args.image_size, 3),
        seed=(20260812, 17),
        minval=0.0,
        maxval=255.0,
        dtype=tf.float32,
    )
    training_output = train_model(images, training=False).numpy()

    with tempfile.TemporaryDirectory(prefix="repvgg-fold-check-") as temp_dir:
        train_path = Path(temp_dir) / "train.keras"
        deploy_path = Path(temp_dir) / "deploy.keras"
        train_model.save(train_path)
        export_deploy_model(tf, train_path, deploy_path, None)
        deploy_model = tf.keras.models.load_model(deploy_path)
        deploy_output = deploy_model(images, training=False).numpy()

    max_abs_error = float(np.max(np.abs(training_output - deploy_output)))
    mean_abs_error = float(np.mean(np.abs(training_output - deploy_output)))
    matching_predictions = int(
        np.sum(np.argmax(training_output, axis=1) == np.argmax(deploy_output, axis=1))
    )
    print(
        "RESULT "
        f"max_abs_error={max_abs_error:.9g} mean_abs_error={mean_abs_error:.9g} "
        f"matching_predictions={matching_predictions}/{args.batch_size}"
    )
    if max_abs_error > args.tolerance:
        raise SystemExit(
            f"Fold mismatch {max_abs_error:.9g} exceeds tolerance {args.tolerance:.9g}."
        )


if __name__ == "__main__":
    main()
