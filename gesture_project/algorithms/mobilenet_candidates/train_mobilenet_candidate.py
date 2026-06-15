"""Train MobileNet-style gesture classifiers for algorithm comparison."""

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
        "--arch",
        choices=[
            "mobilenet_v1_small",
            "keras_mobilenet_v2",
            "keras_mobilenet_v3_small",
            "keras_mobilenet_v3_large",
            "keras_efficientnet_b0",
            "keras_efficientnet_v2_b0",
        ],
        default="mobilenet_v1_small",
    )
    parser.add_argument("--alpha", type=float, default=0.25)
    parser.add_argument(
        "--weights",
        choices=["none", "imagenet"],
        default="none",
        help="Used by Keras application backbones. imagenet may download weights.",
    )
    parser.add_argument(
        "--freeze_backbone",
        action="store_true",
        help="Freeze Keras application backbone during this training run.",
    )
    parser.add_argument(
        "--finetune_epochs",
        type=int,
        default=0,
        help="Optional second-stage fine-tuning epochs after frozen-backbone training.",
    )
    parser.add_argument(
        "--finetune_learning_rate",
        type=float,
        default=1e-4,
        help="Learning rate used during second-stage fine-tuning.",
    )
    parser.add_argument("--dropout", type=float, default=0.2)
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
        "--augment",
        action="store_true",
        help="Add training-only image augmentation before preprocessing.",
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


def scaled_channels(value: int, alpha: float) -> int:
    return max(8, int(value * alpha))


def depthwise_block(tf, x, out_channels: int, stride: int, name: str):
    x = tf.keras.layers.DepthwiseConv2D(
        kernel_size=3,
        strides=stride,
        padding="same",
        use_bias=False,
        name=f"{name}_dw_3x3",
    )(x)
    x = tf.keras.layers.BatchNormalization(name=f"{name}_dw_bn")(x)
    x = tf.keras.layers.ReLU(max_value=6.0, name=f"{name}_dw_relu6")(x)
    x = tf.keras.layers.Conv2D(
        out_channels,
        kernel_size=1,
        padding="same",
        use_bias=False,
        name=f"{name}_pw_1x1",
    )(x)
    x = tf.keras.layers.BatchNormalization(name=f"{name}_pw_bn")(x)
    return tf.keras.layers.ReLU(max_value=6.0, name=f"{name}_pw_relu6")(x)


def build_mobilenet_v1_small(tf, image_size: int, num_classes: int, alpha: float):
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(inputs)
    x = tf.keras.layers.Conv2D(
        scaled_channels(32, alpha),
        kernel_size=3,
        strides=2,
        padding="same",
        use_bias=False,
        name="stem_3x3_s2",
    )(x)
    x = tf.keras.layers.BatchNormalization(name="stem_bn")(x)
    x = tf.keras.layers.ReLU(max_value=6.0, name="stem_relu6")(x)

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
    for index, (channels, stride) in enumerate(specs, start=1):
        x = depthwise_block(
            tf,
            x,
            scaled_channels(channels, alpha),
            stride,
            name=f"block{index}",
        )

    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(0.2, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(
        inputs=inputs,
        outputs=outputs,
        name=f"gesture_mobilenet_v1_small_a{alpha:g}_{image_size}",
    )


def add_training_augmentation(tf, x):
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


def maybe_augment(tf, inputs, enabled: bool):
    return add_training_augmentation(tf, inputs) if enabled else inputs


def weights_arg(weights: str):
    return None if weights == "none" else "imagenet"


def build_keras_mobilenet_v2(tf, args: argparse.Namespace, num_classes: int):
    image_size = args.image_size
    base_model = tf.keras.applications.MobileNetV2(
        input_shape=(image_size, image_size, 3),
        alpha=args.alpha,
        include_top=False,
        weights=weights_arg(args.weights),
        pooling="avg",
    )
    base_model.trainable = not args.freeze_backbone
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = maybe_augment(tf, inputs, args.augment)
    x = tf.keras.layers.Rescaling(1.0 / 127.5, offset=-1.0, name="mobilenetv2_rescale")(x)
    # Keep BatchNorm in inference mode during transfer learning and fine-tuning.
    x = base_model(x, training=False)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_mobilenet_v2"), base_model


def build_keras_mobilenet_v3(tf, args: argparse.Namespace, num_classes: int, *, large: bool):
    image_size = args.image_size
    application = tf.keras.applications.MobileNetV3Large if large else tf.keras.applications.MobileNetV3Small
    base_model = application(
        input_shape=(image_size, image_size, 3),
        alpha=args.alpha,
        include_top=False,
        weights=weights_arg(args.weights),
        pooling="avg",
        include_preprocessing=True,
    )
    base_model.trainable = not args.freeze_backbone
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = maybe_augment(tf, inputs, args.augment)
    x = base_model(x, training=False)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    name = "gesture_mobilenet_v3_large" if large else "gesture_mobilenet_v3_small"
    return tf.keras.Model(inputs=inputs, outputs=outputs, name=name), base_model


def build_keras_efficientnet(tf, args: argparse.Namespace, num_classes: int, *, v2: bool):
    image_size = args.image_size
    application = tf.keras.applications.EfficientNetV2B0 if v2 else tf.keras.applications.EfficientNetB0
    kwargs = {
        "input_shape": (image_size, image_size, 3),
        "include_top": False,
        "weights": weights_arg(args.weights),
        "pooling": "avg",
    }
    if v2:
        kwargs["include_preprocessing"] = True
    base_model = application(**kwargs)
    base_model.trainable = not args.freeze_backbone
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = maybe_augment(tf, inputs, args.augment)
    x = base_model(x, training=False)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    name = "gesture_efficientnet_v2_b0" if v2 else "gesture_efficientnet_b0"
    return tf.keras.Model(inputs=inputs, outputs=outputs, name=name), base_model


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
    return (
        train_ds.prefetch(autotune),
        val_ds.prefetch(autotune),
        test_ds.prefetch(autotune) if test_ds is not None else None,
        class_names,
    )


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


def build_model(tf, args: argparse.Namespace, num_classes: int):
    if args.arch == "mobilenet_v1_small":
        return build_mobilenet_v1_small(tf, args.image_size, num_classes, args.alpha), None
    if args.arch == "keras_mobilenet_v2":
        return build_keras_mobilenet_v2(tf, args, num_classes)
    if args.arch == "keras_mobilenet_v3_small":
        return build_keras_mobilenet_v3(tf, args, num_classes, large=False)
    if args.arch == "keras_mobilenet_v3_large":
        return build_keras_mobilenet_v3(tf, args, num_classes, large=True)
    if args.arch == "keras_efficientnet_b0":
        return build_keras_efficientnet(tf, args, num_classes, v2=False)
    return build_keras_efficientnet(tf, args, num_classes, v2=True)


def trainable_params(model) -> int:
    return int(sum(w.shape.num_elements() or 0 for w in model.trainable_weights))


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


def compile_model(tf, model, learning_rate: float, label_smoothing: float) -> None:
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=learning_rate),
        loss=build_loss(tf, label_smoothing),
        metrics=["accuracy"],
    )


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()
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
    model, base_model = build_model(tf, args, len(class_names))
    compile_model(tf, model, args.learning_rate, args.label_smoothing)

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
    phase_summaries = [
        {
            "phase": "frozen" if args.freeze_backbone else "single_stage",
            "epochs_ran": len(history.history.get("loss", [])),
            "learning_rate": args.learning_rate,
            "backbone_trainable": bool(base_model.trainable) if base_model is not None else True,
        }
    ]

    if args.finetune_epochs > 0 and base_model is not None:
        base_model.trainable = True
        compile_model(tf, model, args.finetune_learning_rate, args.label_smoothing)
        finetune_callbacks = [
            tf.keras.callbacks.ModelCheckpoint(
                out_dir / "model.keras", monitor="val_accuracy", save_best_only=True
            ),
            tf.keras.callbacks.CSVLogger(out_dir / "history.csv", append=True),
            tf.keras.callbacks.EarlyStopping(
                monitor="val_accuracy", patience=6, restore_best_weights=True
            ),
        ]
        if args.reduce_lr_on_plateau:
            finetune_callbacks.append(
                tf.keras.callbacks.ReduceLROnPlateau(
                    monitor="val_loss",
                    factor=0.5,
                    patience=2,
                    min_lr=1e-5,
                )
            )
        finetune_history = model.fit(
            train_ds,
            validation_data=val_ds,
            initial_epoch=len(history.history.get("loss", [])),
            epochs=len(history.history.get("loss", [])) + args.finetune_epochs,
            callbacks=finetune_callbacks,
        )
        phase_summaries.append(
            {
                "phase": "finetune",
                "epochs_ran": len(finetune_history.history.get("loss", [])),
                "learning_rate": args.finetune_learning_rate,
                "backbone_trainable": True,
            }
        )
        for key, values in finetune_history.history.items():
            history.history.setdefault(key, [])
            history.history[key].extend(values)

    model.save(out_dir / "model.keras")
    (out_dir / "labels.txt").write_text("\n".join(class_names) + "\n", encoding="utf-8")

    test_metrics = None
    if test_ds is not None:
        test_values = model.evaluate(test_ds, verbose=1)
        test_metrics = dict(zip(model.metrics_names, [float(v) for v in test_values]))
    test_inference = evaluate_model_per_image(model, data_dir, class_names)

    summary = {
        "arch": args.arch,
        "alpha": args.alpha,
        "weights": args.weights,
        "freeze_backbone": args.freeze_backbone,
        "finetune_epochs": args.finetune_epochs,
        "finetune_learning_rate": args.finetune_learning_rate,
        "augment": args.augment,
        "dropout": args.dropout,
        "label_smoothing": args.label_smoothing,
        "reduce_lr_on_plateau": args.reduce_lr_on_plateau,
        "data_dir": str(data_dir),
        "image_size": args.image_size,
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history.get("loss", [])),
        "learning_rate": args.learning_rate,
        "total_params": int(model.count_params()),
        "trainable_params": trainable_params(model),
        "phases": phase_summaries,
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
