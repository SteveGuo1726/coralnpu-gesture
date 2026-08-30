"""Train MobileNet-style gesture classifiers for algorithm comparison."""

from __future__ import annotations

import argparse
import json
import math
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
    parser.add_argument(
        "--optimizer",
        choices=["adam", "adamw"],
        default="adam",
        help="Optimizer used in both frozen and fine-tune stages.",
    )
    parser.add_argument(
        "--lr_schedule",
        choices=["constant", "cosine"],
        default="constant",
        help="Learning-rate schedule. cosine enables warmup plus cosine decay per stage.",
    )
    parser.add_argument(
        "--warmup_epochs",
        type=int,
        default=0,
        help="Warmup epochs applied when --lr_schedule=cosine.",
    )
    parser.add_argument(
        "--min_learning_rate",
        type=float,
        default=1e-5,
        help="Minimum learning rate reached by cosine decay or plateau decay.",
    )
    parser.add_argument(
        "--weight_decay",
        type=float,
        default=0.0,
        help="Decoupled weight decay used when optimizer=adamw.",
    )
    parser.add_argument(
        "--grad_clipnorm",
        type=float,
        default=0.0,
        help="Global gradient clip norm. Set 0 to disable.",
    )
    parser.add_argument(
        "--early_stop_patience",
        type=int,
        default=8,
        help="Early-stopping patience measured in epochs.",
    )
    parser.add_argument(
        "--cache_mode",
        choices=["none", "eval", "all"],
        default="eval",
        help="Dataset caching mode. eval caches validation/test only, all caches train/val/test.",
    )
    parser.add_argument("--seed", type=int, default=20260601)
    parser.add_argument(
        "--require_gpu",
        action="store_true",
        help="Exit if TensorFlow cannot see a GPU device.",
    )
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
    parser.add_argument(
        "--alpha",
        type=float,
        default=1.0,
        help=(
            "Width multiplier used by MobileNet-family backbones. "
            "For pretrained Keras MobileNetV3, valid imagenet values are typically 0.75 or 1.0."
        ),
    )
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
        "--augmentation_mode",
        choices=["full", "light", "medium", "none"],
        default="full",
        help=(
            "Training-time image augmentation intensity. "
            "medium uses degree-bounded handheld-image perturbations."
        ),
    )
    parser.add_argument(
        "--mixup_alpha",
        type=float,
        default=0.0,
        help="MixUp beta distribution alpha. Set 0 to disable MixUp.",
    )
    parser.add_argument(
        "--mixup_probability",
        type=float,
        default=1.0,
        help="Probability of applying MixUp to a training batch.",
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


def validate_args(args: argparse.Namespace) -> None:
    if args.weights == "imagenet" and args.arch in {
        "keras_mobilenet_v3_small",
        "keras_mobilenet_v3_large",
    }:
        if args.alpha not in {0.75, 1.0}:
            raise SystemExit(
                "--arch keras_mobilenet_v3_* with --weights imagenet requires "
                "--alpha 0.75 or 1.0."
            )


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


def build_mobilenet_v1_small(
    tf, image_size: int, num_classes: int, alpha: float, dropout: float
):
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
    x = tf.keras.layers.Dropout(dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(
        inputs=inputs,
        outputs=outputs,
        name=f"gesture_mobilenet_v1_small_a{alpha:g}_{image_size}",
    )


def add_training_augmentation(tf, x, mode: str):
    if mode == "none":
        return x
    if mode == "medium":
        # PROJECT_LOCAL_MOD: RandomRotation is expressed as a fraction of one
        # complete turn. This keeps the intended rotation at about +/-8 degrees.
        x = tf.keras.layers.RandomTranslation(
            height_factor=0.06,
            width_factor=0.06,
            fill_mode="nearest",
            name="aug_translate",
        )(x)
        x = tf.keras.layers.RandomRotation(
            8.0 / 360.0,
            fill_mode="nearest",
            name="aug_rotate",
        )(x)
        x = tf.keras.layers.RandomZoom(
            height_factor=(-0.10, 0.06),
            width_factor=(-0.10, 0.06),
            fill_mode="nearest",
            name="aug_zoom",
        )(x)
        return tf.keras.layers.RandomContrast(0.12, name="aug_contrast")(x)
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


def maybe_augment(tf, inputs, mode: str):
    return add_training_augmentation(tf, inputs, mode)


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
    x = maybe_augment(tf, inputs, args.augmentation_mode)
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
    x = maybe_augment(tf, inputs, args.augmentation_mode)
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
    x = maybe_augment(tf, inputs, args.augmentation_mode)
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


def maybe_cache_dataset(dataset, enabled: bool):
    if dataset is None or not enabled:
        return dataset
    return dataset.cache()


def apply_mixup(tf, dataset, alpha: float, probability: float):
    if alpha <= 0 or probability <= 0:
        return dataset

    def mix_batch(images, labels):
        def do_mix():
            batch_size = tf.shape(images)[0]
            shuffled_indices = tf.random.shuffle(tf.range(batch_size))
            mixed_images_b = tf.gather(images, shuffled_indices)
            mixed_labels_b = tf.gather(labels, shuffled_indices)

            gamma_a = tf.random.gamma([batch_size], alpha=alpha)
            gamma_b = tf.random.gamma([batch_size], alpha=alpha)
            lam = gamma_a / (gamma_a + gamma_b)
            lam_images = tf.reshape(lam, (-1, 1, 1, 1))
            lam_labels = tf.reshape(lam, (-1, 1))
            images_f = tf.cast(images, tf.float32)
            labels_f = tf.cast(labels, tf.float32)
            return (
                lam_images * images_f + (1.0 - lam_images) * tf.cast(mixed_images_b, tf.float32),
                lam_labels * labels_f + (1.0 - lam_labels) * tf.cast(mixed_labels_b, tf.float32),
            )

        if probability >= 1.0:
            return do_mix()
        return tf.cond(tf.random.uniform([]) <= probability, do_mix, lambda: (images, labels))

    return dataset.map(mix_batch, num_parallel_calls=tf.data.AUTOTUNE)


def evaluate_model_per_image(
    model, data_dir: Path, labels: list[str], batch_size: int = 128
) -> dict | None:
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

    if batch_size <= 0:
        raise ValueError("batch_size must be positive")
    correct = 0
    for start in range(0, len(samples), batch_size):
        batch = samples[start : start + batch_size]
        images = np.stack(
            [
                np.asarray(
                    Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR),
                    dtype=np.float32,
                )
                for path, _ in batch
            ],
            axis=0,
        )
        pred_indices = np.argmax(model.predict(images, verbose=0), axis=1)
        correct += sum(
            int(prediction == target)
            for prediction, (_path, target) in zip(pred_indices, batch, strict=True)
        )
    accuracy = float(correct / len(samples))
    return {
        "num_samples": len(samples),
        "accuracy": accuracy,
        "correct": correct,
    }


def build_model(tf, args: argparse.Namespace, num_classes: int):
    if args.arch == "mobilenet_v1_small":
        return build_mobilenet_v1_small(
            tf, args.image_size, num_classes, args.alpha, args.dropout
        ), None
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

def cosine_epoch_lr(epoch: int, total_epochs: int, base_lr: float, min_lr: float, warmup_epochs: int) -> float:
    if warmup_epochs > 0 and epoch < warmup_epochs:
        return base_lr * float(epoch + 1) / float(max(1, warmup_epochs))
    if total_epochs <= warmup_epochs:
        return base_lr
    progress = float(epoch - warmup_epochs) / float(max(1, total_epochs - warmup_epochs - 1))
    progress = min(max(progress, 0.0), 1.0)
    cosine = 0.5 * (1.0 + math.cos(math.pi * progress))
    return min_lr + (base_lr - min_lr) * cosine


def build_optimizer(tf, args: argparse.Namespace, learning_rate: float):
    optimizer_kwargs = {"learning_rate": learning_rate}
    if args.grad_clipnorm > 0:
        optimizer_kwargs["global_clipnorm"] = args.grad_clipnorm
    if args.optimizer == "adamw":
        optimizer_kwargs["weight_decay"] = args.weight_decay
        return tf.keras.optimizers.AdamW(**optimizer_kwargs)
    return tf.keras.optimizers.Adam(**optimizer_kwargs)


def compile_model(tf, model, args: argparse.Namespace, learning_rate: float) -> None:
    model.compile(
        optimizer=build_optimizer(tf, args, learning_rate),
        loss=build_loss(tf, args.label_smoothing),
        metrics=["accuracy"],
    )


def stage_callbacks(
    tf,
    args: argparse.Namespace,
    out_dir: Path,
    *,
    append_history: bool,
    patience: int,
    stage_epochs: int,
    base_learning_rate: float,
):
    callbacks = [
        tf.keras.callbacks.ModelCheckpoint(
            out_dir / "model.keras", monitor="val_accuracy", save_best_only=True
        ),
        tf.keras.callbacks.CSVLogger(out_dir / "history.csv", append=append_history),
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy",
            patience=patience,
            restore_best_weights=True,
        ),
    ]
    if args.reduce_lr_on_plateau:
        callbacks.append(
            tf.keras.callbacks.ReduceLROnPlateau(
                monitor="val_loss",
                factor=0.5,
                patience=max(2, patience // 3),
                min_lr=args.min_learning_rate,
            )
        )
    if args.lr_schedule == "cosine":
        callbacks.append(
            tf.keras.callbacks.LearningRateScheduler(
                lambda epoch, _lr: cosine_epoch_lr(
                    epoch,
                    stage_epochs,
                    base_learning_rate,
                    args.min_learning_rate,
                    args.warmup_epochs,
                ),
                verbose=0,
            )
        )
    return callbacks


def main() -> None:
    args = parse_args()
    validate_args(args)
    tf = require_tensorflow()
    tf.keras.utils.set_random_seed(args.seed)
    configure_runtime(tf, args.require_gpu)

    data_dir = Path(args.data_dir).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    train_ds, val_ds, test_ds, class_names = load_datasets(
        tf, data_dir, args.image_size, args.batch_size, args.seed
    )
    cache_train = args.cache_mode == "all"
    cache_eval = args.cache_mode in {"all", "eval"}
    train_ds = maybe_cache_dataset(train_ds, cache_train)
    val_ds = maybe_cache_dataset(val_ds, cache_eval)
    if test_ds is not None:
        test_ds = maybe_cache_dataset(test_ds, cache_eval)

    use_one_hot = args.label_smoothing > 0 or args.mixup_alpha > 0
    train_ds = maybe_one_hot(tf, train_ds, len(class_names), use_one_hot)
    val_ds = maybe_one_hot(tf, val_ds, len(class_names), use_one_hot)
    if test_ds is not None:
        test_ds = maybe_one_hot(tf, test_ds, len(class_names), use_one_hot)
    train_ds = apply_mixup(tf, train_ds, args.mixup_alpha, args.mixup_probability)
    model, base_model = build_model(tf, args, len(class_names))
    compile_model(tf, model, args, args.learning_rate)

    callbacks = stage_callbacks(
        tf,
        args,
        out_dir,
        append_history=False,
        patience=args.early_stop_patience,
        stage_epochs=args.epochs,
        base_learning_rate=args.learning_rate,
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
        compile_model(tf, model, args, args.finetune_learning_rate)
        finetune_callbacks = stage_callbacks(
            tf,
            args,
            out_dir,
            append_history=True,
            patience=max(4, args.early_stop_patience - 2),
            stage_epochs=args.finetune_epochs,
            base_learning_rate=args.finetune_learning_rate,
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
    best_epoch = int(np.argmax(history.history["val_accuracy"])) + 1

    summary = {
        "arch": args.arch,
        "alpha": args.alpha,
        "weights": args.weights,
        "freeze_backbone": args.freeze_backbone,
        "finetune_epochs": args.finetune_epochs,
        "finetune_learning_rate": args.finetune_learning_rate,
        "optimizer": args.optimizer,
        "lr_schedule": args.lr_schedule,
        "warmup_epochs": args.warmup_epochs,
        "min_learning_rate": args.min_learning_rate,
        "weight_decay": args.weight_decay,
        "grad_clipnorm": args.grad_clipnorm,
        "early_stop_patience": args.early_stop_patience,
        "cache_mode": args.cache_mode,
        "augmentation_mode": args.augmentation_mode,
        "mixup_alpha": args.mixup_alpha,
        "mixup_probability": args.mixup_probability,
        "dropout": args.dropout,
        "label_smoothing": args.label_smoothing,
        "reduce_lr_on_plateau": args.reduce_lr_on_plateau,
        "data_dir": str(data_dir),
        "image_size": args.image_size,
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history.get("loss", [])),
        "best_epoch": best_epoch,
        "best_val_accuracy": float(np.max(history.history["val_accuracy"])),
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
