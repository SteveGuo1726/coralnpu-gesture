"""Train a small static hand-gesture CNN for Coral NPU experiments."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data_dir", required=True, help="Image-folder dataset root.")
    parser.add_argument("--out_dir", required=True, help="Directory for model outputs.")
    parser.add_argument("--image_size", type=int, default=64)
    parser.add_argument("--batch_size", type=int, default=32)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--learning_rate", type=float, default=1e-3)
    parser.add_argument("--seed", type=int, default=20260601)
    parser.add_argument(
        "--require_gpu",
        action="store_true",
        help="Exit immediately if TensorFlow cannot see a GPU device.",
    )
    parser.add_argument(
        "--variant",
        choices=["v1", "regularized_3x3", "residual_3x3", "repvgg_3x3"],
        default="v1",
        help=(
            "v1 keeps the original baseline. regularized_3x3 adds training-only augmentation "
            "and L2. residual_3x3 keeps a plain 3x3-heavy residual trunk. repvgg_3x3 uses "
            "training-time multi-branch blocks intended to export back to plain 3x3 convs."
        ),
    )
    parser.add_argument("--dropout", type=float, default=0.2)
    parser.add_argument("--weight_decay", type=float, default=0.0)
    parser.add_argument(
        "--width_multiplier",
        type=float,
        default=1.0,
        help="Scales the 3x3 block channels while keeping the network 3x3-heavy.",
    )
    parser.add_argument(
        "--head_channels",
        type=int,
        default=96,
        help="Channels used by the tail stage or 1x1 head depending on variant.",
    )
    parser.add_argument(
        "--label_smoothing",
        type=float,
        default=0.0,
        help="Label smoothing factor for cross-entropy.",
    )
    parser.add_argument(
        "--reduce_lr_on_plateau",
        action="store_true",
        help="Enable ReduceLROnPlateau during training.",
    )
    parser.add_argument(
        "--augmentation_mode",
        choices=["full", "light", "none"],
        default="full",
        help=(
            "Training-time image augmentation intensity. "
            "'full' keeps the current recipe, 'light' reduces motion jitter, "
            "'none' disables augmentation for quick diagnosis."
        ),
    )
    parser.add_argument(
        "--repvgg_branch_scale",
        type=float,
        default=1.0,
        help=(
            "Scale applied to each RepVGG branch before summation. "
            "Useful for diagnosing branch-sum instability without changing deploy form."
        ),
    )
    parser.add_argument(
        "--repvgg_disable_identity",
        action="store_true",
        help="Disable the BatchNorm identity branch inside RepVGG units for diagnosis.",
    )
    return parser.parse_args()


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Create a venv under "
            "gesture_project/algorithms and run: pip install -r requirements.txt"
        ) from exc
    return tf


def configure_runtime(tf, require_gpu: bool):
    gpus = tf.config.list_physical_devices("GPU")
    for gpu in gpus:
        try:
            tf.config.experimental.set_memory_growth(gpu, True)
        except RuntimeError:
            pass
    print(f"TensorFlow GPUs: {gpus}")
    if require_gpu and not gpus:
        raise SystemExit("TensorFlow GPU is required for this run, but no GPU was detected.")
    return gpus


def kernel_regularizer(tf, weight_decay: float):
    if weight_decay <= 0:
        return None
    return tf.keras.regularizers.L2(weight_decay)


def scaled_channels(value: int, width_multiplier: float) -> int:
    return max(8, int(round(value * width_multiplier / 8.0) * 8))


def build_loss(tf, label_smoothing: float):
    if label_smoothing <= 0:
        return tf.keras.losses.SparseCategoricalCrossentropy()
    return tf.keras.losses.CategoricalCrossentropy(label_smoothing=label_smoothing)


def maybe_one_hot(tf, dataset, num_classes: int, enabled: bool):
    if not enabled:
        return dataset
    return dataset.map(
        lambda image, label: (image, tf.one_hot(label, depth=num_classes)),
        num_parallel_calls=tf.data.AUTOTUNE,
    )


def add_training_augmentation(tf, x, mode: str):
    if mode == "none":
        return x
    if mode == "light":
        x = tf.keras.layers.RandomTranslation(
            height_factor=0.04,
            width_factor=0.04,
            fill_mode="nearest",
            name="aug_translate",
        )(x)
        x = tf.keras.layers.RandomRotation(0.04, fill_mode="nearest", name="aug_rotate")(x)
        x = tf.keras.layers.RandomZoom(
            height_factor=(-0.06, 0.04),
            width_factor=(-0.06, 0.04),
            fill_mode="nearest",
            name="aug_zoom",
        )(x)
        return tf.keras.layers.RandomContrast(0.08, name="aug_contrast")(x)
    x = tf.keras.layers.RandomTranslation(
        height_factor=0.08,
        width_factor=0.08,
        fill_mode="nearest",
        name="aug_translate",
    )(x)
    x = tf.keras.layers.RandomRotation(0.08, fill_mode="nearest", name="aug_rotate")(x)
    x = tf.keras.layers.RandomZoom(
        height_factor=(-0.12, 0.08),
        width_factor=(-0.12, 0.08),
        fill_mode="nearest",
        name="aug_zoom",
    )(x)
    return tf.keras.layers.RandomContrast(0.15, name="aug_contrast")(x)


def conv_bn_relu(
    tf,
    x,
    filters: int,
    kernel_size: int,
    regularizer,
    name: str,
    strides: int = 1,
):
    x = tf.keras.layers.Conv2D(
        filters,
        kernel_size=kernel_size,
        strides=strides,
        padding="same",
        use_bias=False,
        kernel_regularizer=regularizer,
        name=f"{name}_conv",
    )(x)
    x = tf.keras.layers.BatchNormalization(name=f"{name}_bn")(x)
    return tf.keras.layers.ReLU(name=f"{name}_relu")(x)


def residual_3x3_unit(tf, x, filters: int, regularizer, stage: int, unit: int):
    shortcut = x
    prefix = f"stage{stage}_unit{unit}"
    x = tf.keras.layers.Conv2D(
        filters,
        kernel_size=3,
        padding="same",
        use_bias=False,
        kernel_regularizer=regularizer,
        name=f"{prefix}_conv1",
    )(x)
    x = tf.keras.layers.BatchNormalization(name=f"{prefix}_bn1")(x)
    x = tf.keras.layers.ReLU(name=f"{prefix}_relu1")(x)
    x = tf.keras.layers.Conv2D(
        filters,
        kernel_size=3,
        padding="same",
        use_bias=False,
        kernel_regularizer=regularizer,
        name=f"{prefix}_conv2",
    )(x)
    x = tf.keras.layers.BatchNormalization(name=f"{prefix}_bn2")(x)
    x = tf.keras.layers.Add(name=f"{prefix}_add")([shortcut, x])
    return tf.keras.layers.ReLU(name=f"{prefix}_relu2")(x)


def maybe_scale_branch(tf, x, scale: float, name: str):
    if abs(scale - 1.0) < 1e-8:
        return x
    return tf.keras.layers.Rescaling(scale=scale, offset=0.0, name=name)(x)


def repvgg_3x3_unit(tf, x, filters: int, regularizer, stage: int, unit: int, args: argparse.Namespace):
    prefix = f"stage{stage}_unit{unit}"
    branches = []

    branch_3x3 = tf.keras.layers.Conv2D(
        filters,
        kernel_size=3,
        padding="same",
        use_bias=False,
        kernel_regularizer=regularizer,
        name=f"{prefix}_rbr_dense_conv",
    )(x)
    branch_3x3 = tf.keras.layers.BatchNormalization(name=f"{prefix}_rbr_dense_bn")(branch_3x3)
    branch_3x3 = maybe_scale_branch(
        tf,
        branch_3x3,
        args.repvgg_branch_scale,
        name=f"{prefix}_rbr_dense_scale",
    )
    branches.append(branch_3x3)

    branch_1x1 = tf.keras.layers.Conv2D(
        filters,
        kernel_size=1,
        padding="same",
        use_bias=False,
        kernel_regularizer=regularizer,
        name=f"{prefix}_rbr_1x1_conv",
    )(x)
    branch_1x1 = tf.keras.layers.BatchNormalization(name=f"{prefix}_rbr_1x1_bn")(branch_1x1)
    branch_1x1 = maybe_scale_branch(
        tf,
        branch_1x1,
        args.repvgg_branch_scale,
        name=f"{prefix}_rbr_1x1_scale",
    )
    branches.append(branch_1x1)

    input_channels = int(x.shape[-1])
    if input_channels == filters and not args.repvgg_disable_identity:
        branch_identity = tf.keras.layers.BatchNormalization(name=f"{prefix}_rbr_identity_bn")(x)
        branch_identity = maybe_scale_branch(
            tf,
            branch_identity,
            args.repvgg_branch_scale,
            name=f"{prefix}_rbr_identity_scale",
        )
        branches.append(branch_identity)

    if len(branches) == 1:
        merged = branches[0]
    else:
        merged = tf.keras.layers.Add(name=f"{prefix}_add")(branches)
    return tf.keras.layers.ReLU(name=f"{prefix}_relu")(merged)


def build_residual_3x3_model(tf, args: argparse.Namespace, num_classes: int):
    image_size = args.image_size
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = add_training_augmentation(tf, inputs, args.augmentation_mode)
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(x)
    regularizer = kernel_regularizer(tf, args.weight_decay)

    stem_filters = scaled_channels(16, args.width_multiplier)
    x = conv_bn_relu(tf, x, stem_filters, 3, regularizer, "stem")

    stage_filters = [16, 32, 64, 96]
    units_per_stage = [2, 2, 2, 1]
    for stage, (base_filters, units) in enumerate(zip(stage_filters, units_per_stage), start=1):
        filters = scaled_channels(base_filters, args.width_multiplier)
        if stage > 1:
            x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"stage{stage}_pool")(x)
            x = conv_bn_relu(tf, x, filters, 3, regularizer, f"stage{stage}_entry")
        elif stem_filters != filters:
            x = conv_bn_relu(tf, x, filters, 3, regularizer, f"stage{stage}_entry")
        for unit in range(1, units + 1):
            x = residual_3x3_unit(tf, x, filters, regularizer, stage, unit)

    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_residual_3x3")


def build_repvgg_3x3_model(tf, args: argparse.Namespace, num_classes: int):
    image_size = args.image_size
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = add_training_augmentation(tf, inputs, args.augmentation_mode)
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(x)
    regularizer = kernel_regularizer(tf, args.weight_decay)

    stem_filters = scaled_channels(16, args.width_multiplier)
    x = conv_bn_relu(tf, x, stem_filters, 3, regularizer, "stem")

    stage_filters = [16, 32, 64, args.head_channels]
    units_per_stage = [2, 2, 2, 1]
    for stage, (base_filters, units) in enumerate(zip(stage_filters, units_per_stage), start=1):
        filters = scaled_channels(base_filters, args.width_multiplier)
        if stage > 1:
            x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"stage{stage}_pool")(x)
            x = conv_bn_relu(tf, x, filters, 3, regularizer, f"stage{stage}_entry")
        elif stem_filters != filters:
            x = conv_bn_relu(tf, x, filters, 3, regularizer, f"stage{stage}_entry")
        for unit in range(1, units + 1):
            x = repvgg_3x3_unit(tf, x, filters, regularizer, stage, unit, args)

    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_repvgg_3x3_train")


def build_model(tf, args: argparse.Namespace, num_classes: int):
    if args.variant == "repvgg_3x3":
        return build_repvgg_3x3_model(tf, args, num_classes)
    if args.variant == "residual_3x3":
        return build_residual_3x3_model(tf, args, num_classes)
    image_size = args.image_size
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = inputs
    if args.variant in {"regularized_3x3", "residual_3x3", "repvgg_3x3"}:
        x = add_training_augmentation(tf, x, args.augmentation_mode)
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(x)
    regularizer = kernel_regularizer(tf, args.weight_decay)

    # Keep the network intentionally 3x3-heavy so hardware optimization impact
    # can be estimated from Conv2D layer shapes.
    for block, base_filters in enumerate([16, 32, 64], start=1):
        filters = scaled_channels(base_filters, args.width_multiplier)
        x = tf.keras.layers.Conv2D(
            filters,
            kernel_size=3,
            padding="same",
            use_bias=False,
            kernel_regularizer=regularizer,
            name=f"conv{block}_3x3_a",
        )(x)
        x = tf.keras.layers.BatchNormalization(name=f"bn{block}_a")(x)
        x = tf.keras.layers.ReLU(name=f"relu{block}_a")(x)
        x = tf.keras.layers.Conv2D(
            filters,
            kernel_size=3,
            padding="same",
            use_bias=False,
            kernel_regularizer=regularizer,
            name=f"conv{block}_3x3_b",
        )(x)
        x = tf.keras.layers.BatchNormalization(name=f"bn{block}_b")(x)
        x = tf.keras.layers.ReLU(name=f"relu{block}_b")(x)
        x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"pool{block}")(x)

    x = tf.keras.layers.Conv2D(
        args.head_channels,
        kernel_size=1,
        padding="same",
        activation="relu",
        kernel_regularizer=regularizer,
        name="conv_head_1x1",
    )(x)
    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_static_cnn_v1")


def load_datasets(tf, data_dir: Path, image_size: int, batch_size: int, seed: int):
    train_dir = data_dir / "train"
    val_dir = data_dir / "val"
    test_dir = data_dir / "test"
    if not train_dir.is_dir():
        raise SystemExit(f"Missing train directory: {train_dir}")
    if not val_dir.is_dir():
        raise SystemExit(f"Missing val directory: {val_dir}")

    train_ds = tf.keras.utils.image_dataset_from_directory(
        train_dir,
        image_size=(image_size, image_size),
        batch_size=batch_size,
        seed=seed,
        shuffle=True,
    )
    class_names = list(train_ds.class_names)
    val_ds = tf.keras.utils.image_dataset_from_directory(
        val_dir,
        image_size=(image_size, image_size),
        batch_size=batch_size,
        seed=seed,
        shuffle=False,
    )

    test_ds = None
    if test_dir.is_dir():
        test_ds = tf.keras.utils.image_dataset_from_directory(
            test_dir,
            image_size=(image_size, image_size),
            batch_size=batch_size,
            seed=seed,
            shuffle=False,
        )

    autotune = tf.data.AUTOTUNE
    train_ds = train_ds.prefetch(autotune)
    val_ds = val_ds.prefetch(autotune)
    if test_ds is not None:
        test_ds = test_ds.prefetch(autotune)
    return train_ds, val_ds, test_ds, class_names


def evaluate_model_per_image(model, data_dir: Path, labels: list[str]) -> dict | None:
    test_dir = data_dir / "test"
    if not test_dir.is_dir():
        return None
    input_shape = model.input_shape
    height, width = int(input_shape[1]), int(input_shape[2])
    samples: list[tuple[Path, int]] = []
    for label_index, label in enumerate(labels):
        class_dir = test_dir / label
        if not class_dir.is_dir():
            raise SystemExit(f"Missing class directory: {class_dir}")
        for path in sorted(class_dir.rglob("*")):
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                samples.append((path, label_index))
    if not samples:
        raise SystemExit(f"No images found in {test_dir}")

    images = np.stack(
        [
            np.asarray(
                Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR),
                dtype=np.float32,
            )
            for path, _ in samples
        ],
        axis=0,
    )
    true_indices = np.asarray([label_index for _path, label_index in samples], dtype=np.int64)
    scores = model.predict(images, verbose=0)
    pred_indices = np.argmax(scores, axis=1)
    accuracy = float((pred_indices == true_indices).mean())
    return {
        "num_samples": len(samples),
        "accuracy": accuracy,
        "correct": int((pred_indices == true_indices).sum()),
    }


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()
    configure_runtime(tf, args.require_gpu)
    tf.keras.utils.set_random_seed(args.seed)

    data_dir = Path(args.data_dir).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    train_ds, val_ds, test_ds, class_names = load_datasets(
        tf, data_dir, args.image_size, args.batch_size, args.seed
    )
    use_one_hot = args.label_smoothing > 0
    train_ds = maybe_one_hot(tf, train_ds, len(class_names), use_one_hot)
    val_ds = maybe_one_hot(tf, val_ds, len(class_names), use_one_hot)
    if test_ds is not None:
        test_ds = maybe_one_hot(tf, test_ds, len(class_names), use_one_hot)
    model = build_model(tf, args, len(class_names))
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=args.learning_rate),
        loss=build_loss(tf, args.label_smoothing),
        metrics=["accuracy"],
    )

    callbacks = [
        tf.keras.callbacks.ModelCheckpoint(
            out_dir / "model.keras", monitor="val_accuracy", save_best_only=True
        ),
        tf.keras.callbacks.CSVLogger(out_dir / "history.csv"),
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy", patience=8, restore_best_weights=True
        ),
    ]
    if args.reduce_lr_on_plateau:
        callbacks.append(
            tf.keras.callbacks.ReduceLROnPlateau(
                monitor="val_loss",
                factor=0.5,
                patience=3,
                min_lr=1e-5,
            )
        )
    history = model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=args.epochs,
        callbacks=callbacks,
    )
    model.save(out_dir / "model.keras")
    (out_dir / "labels.txt").write_text("\n".join(class_names) + "\n", encoding="utf-8")

    test_metrics = None
    if test_ds is not None:
        test_values = model.evaluate(test_ds, verbose=1)
        test_metrics = dict(zip(model.metrics_names, [float(v) for v in test_values]))
    test_inference = evaluate_model_per_image(model, data_dir, class_names)

    summary = {
        "data_dir": str(data_dir),
        "variant": args.variant,
        "image_size": args.image_size,
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history.get("loss", [])),
        "learning_rate": args.learning_rate,
        "dropout": args.dropout,
        "weight_decay": args.weight_decay,
        "width_multiplier": args.width_multiplier,
        "head_channels": args.head_channels,
        "label_smoothing": args.label_smoothing,
        "reduce_lr_on_plateau": args.reduce_lr_on_plateau,
        "augmentation_mode": args.augmentation_mode,
        "repvgg_branch_scale": args.repvgg_branch_scale,
        "repvgg_disable_identity": args.repvgg_disable_identity,
        "classes": class_names,
        "final_train_accuracy": float(history.history["accuracy"][-1]),
        "final_val_accuracy": float(history.history["val_accuracy"][-1]),
        "test_metrics": test_metrics,
        "test_inference": test_inference,
    }
    (out_dir / "training_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
