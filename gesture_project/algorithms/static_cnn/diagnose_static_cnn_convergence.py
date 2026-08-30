"""Fixed-batch convergence check for static gesture CNN candidates.

PROJECT_LOCAL_MOD: This is a project-side training diagnostic.  It deliberately
uses the unmodified raw HAGRID six-class split and disables augmentation and
MixUp so an early training failure can be distinguished from normal warm-up.
"""

from __future__ import annotations

import argparse
from argparse import Namespace
from pathlib import Path

import numpy as np

from train_static_cnn import (
    build_loss,
    build_model,
    build_optimizer,
    configure_runtime,
    load_datasets,
    require_tensorflow,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--data_dir",
        type=Path,
        default=Path("gesture_project/datasets/processed/hagrid_sample_static_6cls"),
    )
    parser.add_argument("--steps", type=int, default=40)
    parser.add_argument("--batch_size", type=int, default=64)
    parser.add_argument("--image_size", type=int, default=96)
    return parser.parse_args()


def candidate_args(name: str, image_size: int) -> Namespace:
    common = dict(
        image_size=image_size,
        optimizer="adamw",
        learning_rate=1e-3,
        grad_clipnorm=0.0,
        weight_decay=1e-4,
        augmentation_mode="none",
        dropout=0.2,
        width_multiplier=1.0,
        head_channels=96,
        body_kernel_size=3,
        body_kernel_schedule="",
        stage_channels="",
        head_kernel_size=1,
        repvgg_branch_scale=1.0,
        repvgg_disable_identity=False,
        repvgg_4x4_aux_3x3=False,
        repvgg_kernel_schedule="",
        repvgg_units_per_stage="",
    )
    if name == "hybrid344":
        config = {**common, "variant": "regularized_plain", "body_kernel_schedule": "3,4,4"}
        return Namespace(**config)
    if name == "pure444":
        config = {
            **common,
            "variant": "regularized_plain",
            "width_multiplier": 1.25,
            "head_channels": 112,
            "dropout": 0.30,
            "weight_decay": 2e-4,
            "body_kernel_size": 4,
        }
        return Namespace(**config)
    if name == "repvgg3":
        config = {**common, "variant": "repvgg_3x3", "head_channels": 96}
        return Namespace(**config)
    raise ValueError(f"Unknown candidate: {name}")


def accuracy(tf, labels, probabilities) -> float:
    predicted = tf.argmax(probabilities, axis=1, output_type=tf.int32)
    return float(tf.reduce_mean(tf.cast(tf.equal(labels, predicted), tf.float32)).numpy())


def run_candidate(tf, name: str, images, labels, steps: int) -> None:
    args = candidate_args(name, int(images.shape[1]))
    model = build_model(tf, args, 6)
    optimizer = build_optimizer(tf, args)
    loss_fn = build_loss(tf, use_soft_labels=False, label_smoothing=0.0)

    trainable_before = model.trainable_variables[0].numpy().copy()
    first_loss = first_accuracy = first_grad_norm = None
    last_loss = last_accuracy = None
    for step in range(steps):
        with tf.GradientTape() as tape:
            probabilities = model(images, training=True)
            loss = loss_fn(labels, probabilities)
            if model.losses:
                loss += tf.add_n(model.losses)
        gradients = tape.gradient(loss, model.trainable_variables)
        usable_gradients = [gradient for gradient in gradients if gradient is not None]
        grad_norm = float(tf.linalg.global_norm(usable_gradients).numpy())
        optimizer.apply_gradients(zip(gradients, model.trainable_variables))
        current_loss = float(loss.numpy())
        current_accuracy = accuracy(tf, labels, probabilities)
        if step == 0:
            first_loss = current_loss
            first_accuracy = current_accuracy
            first_grad_norm = grad_norm
        last_loss = current_loss
        last_accuracy = current_accuracy

    weight_delta = float(np.linalg.norm(model.trainable_variables[0].numpy() - trainable_before))
    print(
        "RESULT "
        f"candidate={name} params={model.count_params()} steps={steps} "
        f"first_loss={first_loss:.6f} last_loss={last_loss:.6f} "
        f"first_accuracy={first_accuracy:.6f} last_accuracy={last_accuracy:.6f} "
        f"first_grad_norm={first_grad_norm:.6f} first_kernel_delta={weight_delta:.6f}"
    )


def main() -> None:
    args = parse_args()
    if args.steps <= 0:
        raise SystemExit("--steps must be positive")
    tf = require_tensorflow()
    configure_runtime(tf, require_gpu=False)
    tf.keras.utils.set_random_seed(20260811)
    train_ds, _val_ds, _test_ds, class_names = load_datasets(
        tf, args.data_dir.resolve(), args.image_size, args.batch_size, 20260811
    )
    images, labels = next(iter(train_ds.take(1)))
    labels_np = labels.numpy()
    print(
        "DATA "
        f"classes={','.join(class_names)} label_counts={np.bincount(labels_np, minlength=6).tolist()} "
        f"input_min={float(tf.reduce_min(images).numpy()):.1f} "
        f"input_max={float(tf.reduce_max(images).numpy()):.1f} "
        f"input_mean={float(tf.reduce_mean(images).numpy()):.3f}"
    )
    for name in ("hybrid344", "pure444", "repvgg3"):
        run_candidate(tf, name, images, labels, args.steps)


if __name__ == "__main__":
    main()
