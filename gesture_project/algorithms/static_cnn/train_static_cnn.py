"""Train a small static hand-gesture CNN for Coral NPU experiments."""

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
        help="Training optimizer. AdamW uses decoupled weight decay instead of kernel L2.",
    )
    parser.add_argument(
        "--lr_schedule",
        choices=["constant", "cosine"],
        default="constant",
        help="Learning-rate schedule. cosine enables epoch-wise warmup + cosine decay.",
    )
    parser.add_argument(
        "--warmup_epochs",
        type=int,
        default=0,
        help="Warmup epochs used by the cosine schedule.",
    )
    parser.add_argument(
        "--min_learning_rate",
        type=float,
        default=1e-5,
        help="Minimum learning rate reached by the cosine schedule.",
    )
    parser.add_argument(
        "--grad_clipnorm",
        type=float,
        default=0.0,
        help="Global gradient clip norm. Set 0 to disable clipping.",
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
        help=(
            "Dataset caching mode. 'eval' caches validation/test only, "
            "'all' caches train/val/test."
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
    parser.add_argument("--seed", type=int, default=20260601)
    parser.add_argument(
        "--require_gpu",
        action="store_true",
        help="Exit immediately if TensorFlow cannot see a GPU device.",
    )
    parser.add_argument(
        "--variant",
        choices=[
            "v1",
            "regularized_3x3",
            "regularized_plain",
            "residual_3x3",
            "repvgg_3x3",
            "repvgg_4x4",
            "repvgg_hybrid",
        ],
        default="v1",
        help=(
            "v1 keeps the original baseline. regularized_3x3 adds training-only augmentation "
            "and L2. regularized_plain keeps the same plain CNN training path but allows "
            "kernel-size sweeps through --body_kernel_size. residual_3x3 keeps a plain "
            "3x3-heavy residual trunk. RepVGG variants use training-time multi-branch "
            "blocks intended to export back to one plain spatial convolution. "
            "repvgg_hybrid permits an explicit per-stage 3x3/4x4/1x1 deployment schedule."
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
        "--body_kernel_size",
        type=int,
        choices=[3, 4],
        default=3,
        help=(
            "Kernel size used by the plain CNN body blocks. "
            "Set to 4 to probe official Conv2D 4x4-friendly candidates."
        ),
    )
    parser.add_argument(
        "--body_kernel_schedule",
        default="",
        help=(
            "Optional comma-separated kernel schedule for the three body blocks. "
            "Example: 3,4,4 keeps the first block at 3x3 and the later blocks at 4x4."
        ),
    )
    parser.add_argument(
        "--stage_channels",
        default="",
        help=(
            "Optional comma-separated output channels for the three body stages. "
            "Example: 16,48,80 aligns 4x4 RVV output-channel blocks to 16 lanes."
        ),
    )
    parser.add_argument(
        "--head_kernel_size",
        type=int,
        choices=[1, 3, 4],
        default=1,
        help=(
            "Kernel size used by the plain static CNN head conv. "
            "Use 3 or 4 to keep the deployed network spatial-conv-heavy."
        ),
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
        choices=["full", "light", "medium", "realistic", "none"],
        default="full",
        help=(
            "Training-time image augmentation intensity. "
            "'full' keeps the current recipe, 'light' reduces motion jitter, "
            "'medium' increases degree-bounded handheld perturbations, "
            "'realistic' uses conservative degree-bounded rotation for handheld images, "
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
    parser.add_argument(
        "--repvgg_4x4_aux_3x3",
        action="store_true",
        help=(
            "Add a training-only 3x3 Conv+BN branch to each 4x4 RepVGG unit. "
            "The branch is fused into the same 4x4 deploy kernel, so it adds no "
            "deploy-time operator or MACs."
        ),
    )
    parser.add_argument(
        "--repvgg_kernel_schedule",
        default="",
        help=(
            "Optional comma-separated deployment kernel sizes for all four RepVGG stages. "
            "Example: 3,4,4,1 keeps the spatial trunk hybrid and makes the final "
            "post-pool head a 1x1 convolution. Empty preserves the selected RepVGG variant."
        ),
    )
    parser.add_argument(
        "--repvgg_units_per_stage",
        default="",
        help=(
            "Optional comma-separated RepVGG unit counts for the four stages. "
            "Example: 1,1,1,0 gives one re-parameterized unit per spatial stage and "
            "a plain final head entry. Empty preserves 2,2,2,1."
        ),
    )
    parser.add_argument(
        "--distill_teacher_model",
        type=Path,
        help=(
            "Optional frozen Keras teacher model used only during training. "
            "The exported student architecture is unchanged."
        ),
    )
    parser.add_argument(
        "--distill_teacher_labels",
        type=Path,
        help="Teacher labels.txt. Required with --distill_teacher_model for class-order checking.",
    )
    parser.add_argument(
        "--distill_alpha",
        type=float,
        default=0.0,
        help="Weight of the teacher soft-target loss in [0, 1]. Set 0 to disable distillation.",
    )
    parser.add_argument(
        "--distill_temperature",
        type=float,
        default=2.0,
        help="Positive soft-target temperature used when distillation is enabled.",
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


def kernel_regularizer(tf, weight_decay: float, optimizer_name: str):
    if weight_decay <= 0 or optimizer_name == "adamw":
        return None
    return tf.keras.regularizers.L2(weight_decay)


def scaled_channels(value: int, width_multiplier: float) -> int:
    return max(8, int(round(value * width_multiplier / 8.0) * 8))


def build_loss(tf, *, use_soft_labels: bool, label_smoothing: float):
    if not use_soft_labels:
        return tf.keras.losses.SparseCategoricalCrossentropy()
    return tf.keras.losses.CategoricalCrossentropy(label_smoothing=label_smoothing)


def read_labels(path: Path) -> list[str]:
    labels = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    labels = [label for label in labels if label]
    if not labels:
        raise SystemExit(f"No labels found in {path}")
    return labels


def load_distillation_teacher(tf, args: argparse.Namespace, class_names: list[str]):
    """Load and validate a frozen teacher without changing student deployment."""
    if args.distill_teacher_model is None:
        if args.distill_alpha != 0.0:
            raise SystemExit("--distill_alpha requires --distill_teacher_model.")
        return None
    if args.distill_teacher_labels is None:
        raise SystemExit("--distill_teacher_model requires --distill_teacher_labels.")
    if not 0.0 < args.distill_alpha <= 1.0:
        raise SystemExit("--distill_alpha must be in (0, 1] when a teacher is configured.")
    if args.distill_temperature <= 0.0:
        raise SystemExit("--distill_temperature must be positive.")

    teacher_path = args.distill_teacher_model.resolve()
    teacher_labels_path = args.distill_teacher_labels.resolve()
    if not teacher_path.is_file():
        raise SystemExit(f"Missing teacher model: {teacher_path}")
    if not teacher_labels_path.is_file():
        raise SystemExit(f"Missing teacher labels: {teacher_labels_path}")
    teacher_labels = read_labels(teacher_labels_path)
    if teacher_labels != class_names:
        raise SystemExit(
            "Teacher and student class orders differ: "
            f"teacher={teacher_labels}, student={class_names}"
        )

    teacher = tf.keras.models.load_model(teacher_path, compile=False)
    expected_input = (args.image_size, args.image_size, 3)
    teacher_input = tuple(int(value) for value in teacher.input_shape[1:])
    if teacher_input != expected_input:
        raise SystemExit(
            f"Teacher input shape {teacher_input} does not match student {expected_input}."
        )
    if int(teacher.output_shape[-1]) != len(class_names):
        raise SystemExit(
            f"Teacher output classes {teacher.output_shape[-1]} do not match {len(class_names)}."
        )
    teacher.trainable = False
    print(
        "PROJECT_LOCAL_MOD distillation teacher loaded: "
        f"{teacher_path} temperature={args.distill_temperature} alpha={args.distill_alpha}"
    )
    return teacher


def build_distillation_trainer(
    tf,
    student,
    teacher,
    supervised_loss,
    alpha: float,
    temperature: float,
    use_soft_labels: bool,
):
    """Build a training-only wrapper whose call path remains the student model.

    PROJECT_LOCAL_MOD: the wrapper is never exported. Only ``student`` is
    checkpointed and converted to TFLite, so distillation adds no inference
    operator, parameter, memory, or CoralNPU scheduling cost.
    """

    class DistillationTrainer(tf.keras.Model):
        def __init__(self):
            super().__init__(name="project_distillation_trainer")
            self.student = student
            self.teacher = teacher
            self.supervised_loss = supervised_loss
            self.alpha = float(alpha)
            self.temperature = float(temperature)
            self.use_soft_labels = bool(use_soft_labels)
            self.loss_tracker = tf.keras.metrics.Mean(name="loss")
            self.supervised_tracker = tf.keras.metrics.Mean(name="supervised_loss")
            self.distill_tracker = tf.keras.metrics.Mean(name="distill_loss")
            self.accuracy_tracker = tf.keras.metrics.CategoricalAccuracy(name="accuracy")

        @property
        def metrics(self):
            return [
                self.loss_tracker,
                self.supervised_tracker,
                self.distill_tracker,
                self.accuracy_tracker,
            ]

        def call(self, images, training=False):
            return self.student(images, training=training)

        def soft_targets(self, probabilities):
            safe_probabilities = tf.clip_by_value(probabilities, 1e-7, 1.0)
            return tf.nn.softmax(tf.math.log(safe_probabilities) / self.temperature)

        def hard_labels(self, labels):
            if self.use_soft_labels:
                return labels
            return tf.one_hot(tf.cast(labels, tf.int32), depth=int(student.output_shape[-1]))

        def train_step(self, data):
            images, labels, _sample_weight = tf.keras.utils.unpack_x_y_sample_weight(data)
            with tf.GradientTape() as tape:
                student_probabilities = self.student(images, training=True)
                teacher_probabilities = self.teacher(images, training=False)
                supervised = self.supervised_loss(labels, student_probabilities)
                if self.student.losses:
                    supervised += tf.add_n(self.student.losses)
                teacher_targets = self.soft_targets(teacher_probabilities)
                student_targets = self.soft_targets(student_probabilities)
                distill = tf.reduce_mean(
                    tf.reduce_sum(
                        teacher_targets
                        * (tf.math.log(teacher_targets + 1e-7)
                           - tf.math.log(student_targets + 1e-7)),
                        axis=-1,
                    )
                ) * (self.temperature ** 2)
                total = (1.0 - self.alpha) * supervised + self.alpha * distill
            gradients = tape.gradient(total, self.student.trainable_variables)
            self.optimizer.apply_gradients(zip(gradients, self.student.trainable_variables))
            self.loss_tracker.update_state(total)
            self.supervised_tracker.update_state(supervised)
            self.distill_tracker.update_state(distill)
            self.accuracy_tracker.update_state(self.hard_labels(labels), student_probabilities)
            return {metric.name: metric.result() for metric in self.metrics}

        def test_step(self, data):
            images, labels, _sample_weight = tf.keras.utils.unpack_x_y_sample_weight(data)
            student_probabilities = self.student(images, training=False)
            supervised = self.supervised_loss(labels, student_probabilities)
            if self.student.losses:
                supervised += tf.add_n(self.student.losses)
            self.loss_tracker.update_state(supervised)
            self.supervised_tracker.update_state(supervised)
            self.distill_tracker.update_state(0.0)
            self.accuracy_tracker.update_state(self.hard_labels(labels), student_probabilities)
            return {metric.name: metric.result() for metric in self.metrics}

    return DistillationTrainer()


def build_student_checkpoint(tf, student, path: Path):
    """Save only the best deployable student rather than the training wrapper."""

    class StudentCheckpoint(tf.keras.callbacks.Callback):
        def __init__(self):
            super().__init__()
            self.best = -math.inf

        def on_epoch_end(self, epoch, logs=None):
            value = None if logs is None else logs.get("val_accuracy")
            if value is not None and float(value) > self.best:
                self.best = float(value)
                student.save(path)
                print(
                    "PROJECT_LOCAL_MOD saved distilled student "
                    f"epoch={epoch + 1} val_accuracy={self.best:.6f}"
                )

    return StudentCheckpoint()


def maybe_one_hot(tf, dataset, num_classes: int, enabled: bool):
    if not enabled:
        return dataset
    return dataset.map(
        lambda image, label: (image, tf.one_hot(label, depth=num_classes)),
        num_parallel_calls=tf.data.AUTOTUNE,
    )


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


def maybe_cache_dataset(dataset, enabled: bool):
    if dataset is None or not enabled:
        return dataset
    return dataset.cache()


def cosine_epoch_lr(epoch: int, total_epochs: int, base_lr: float, min_lr: float, warmup_epochs: int) -> float:
    if warmup_epochs > 0 and epoch < warmup_epochs:
        return base_lr * float(epoch + 1) / float(max(1, warmup_epochs))
    if total_epochs <= warmup_epochs:
        return base_lr
    progress = float(epoch - warmup_epochs) / float(max(1, total_epochs - warmup_epochs - 1))
    progress = min(max(progress, 0.0), 1.0)
    cosine = 0.5 * (1.0 + math.cos(math.pi * progress))
    return min_lr + (base_lr - min_lr) * cosine


def build_optimizer(tf, args: argparse.Namespace):
    optimizer_kwargs = {
        "learning_rate": args.learning_rate,
    }
    if args.grad_clipnorm > 0:
        optimizer_kwargs["global_clipnorm"] = args.grad_clipnorm
    if args.optimizer == "adamw":
        optimizer_kwargs["weight_decay"] = args.weight_decay
        return tf.keras.optimizers.AdamW(**optimizer_kwargs)
    return tf.keras.optimizers.Adam(**optimizer_kwargs)


def add_training_augmentation(tf, x, mode: str):
    if mode == "none":
        return x
    if mode == "medium":
        # Keras RandomRotation factors are fractions of a full turn, not degrees.
        # This is deliberately stronger than realistic but avoids the historical
        # full recipe's accidental +/-28.8 degree rotation.
        x = tf.keras.layers.RandomTranslation(
            height_factor=0.08,
            width_factor=0.08,
            fill_mode="nearest",
            name="aug_translate",
        )(x)
        x = tf.keras.layers.RandomRotation(
            12.0 / 360.0,
            fill_mode="nearest",
            name="aug_rotate",
        )(x)
        x = tf.keras.layers.RandomZoom(
            height_factor=(-0.12, 0.08),
            width_factor=(-0.12, 0.08),
            fill_mode="nearest",
            name="aug_zoom",
        )(x)
        return tf.keras.layers.RandomContrast(0.15, name="aug_contrast")(x)
    if mode == "realistic":
        # Keras RandomRotation factors are fractions of a full turn, not degrees.
        # Keep this recipe separate so historical light/full runs remain reproducible.
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
            height_factor=(-0.08, 0.06),
            width_factor=(-0.08, 0.06),
            fill_mode="nearest",
            name="aug_zoom",
        )(x)
        return tf.keras.layers.RandomContrast(0.10, name="aug_contrast")(x)
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


def kernel_label(kernel_size: int) -> str:
    return f"{kernel_size}x{kernel_size}"


def parse_body_kernel_schedule(args: argparse.Namespace) -> list[int]:
    if not args.body_kernel_schedule.strip():
        return [args.body_kernel_size] * 3

    parts = [part.strip() for part in args.body_kernel_schedule.split(",") if part.strip()]
    if len(parts) != 3:
        raise SystemExit(
            "--body_kernel_schedule must contain exactly three comma-separated values, "
            "one for each body block."
        )

    schedule: list[int] = []
    for part in parts:
        try:
            kernel_size = int(part)
        except ValueError as exc:
            raise SystemExit(f"Invalid kernel size in --body_kernel_schedule: {part}") from exc
        if kernel_size not in {3, 4}:
            raise SystemExit(
                "--body_kernel_schedule currently only supports 3 and 4 so the mixed "
                "candidate stays inside the same official-fit search space."
            )
        schedule.append(kernel_size)
    return schedule


def parse_stage_channels(args: argparse.Namespace) -> list[int]:
    if not args.stage_channels.strip():
        return [scaled_channels(value, args.width_multiplier) for value in [16, 32, 64]]

    parts = [part.strip() for part in args.stage_channels.split(",") if part.strip()]
    if len(parts) != 3:
        raise SystemExit(
            "--stage_channels must contain exactly three comma-separated values, "
            "one for each body stage."
        )
    try:
        channels = [int(part) for part in parts]
    except ValueError as exc:
        raise SystemExit("--stage_channels values must be integers.") from exc
    if any(value <= 0 or value % 8 for value in channels):
        raise SystemExit("--stage_channels values must be positive multiples of 8.")
    return channels


def parse_repvgg_kernel_schedule(args: argparse.Namespace, default_kernel: int) -> list[int]:
    """Return the four deploy-time kernels used by the RepVGG stage builder."""
    if not args.repvgg_kernel_schedule.strip():
        return [default_kernel] * 4

    parts = [part.strip() for part in args.repvgg_kernel_schedule.split(",") if part.strip()]
    if len(parts) != 4:
        raise SystemExit(
            "--repvgg_kernel_schedule must contain exactly four comma-separated values, "
            "one for each RepVGG stage."
        )
    try:
        kernels = [int(part) for part in parts]
    except ValueError as exc:
        raise SystemExit("--repvgg_kernel_schedule values must be integers.") from exc
    if any(kernel not in {1, 3, 4} for kernel in kernels):
        raise SystemExit("--repvgg_kernel_schedule only supports 1, 3, and 4.")
    return kernels


def parse_repvgg_units_per_stage(args: argparse.Namespace) -> list[int]:
    """Return the four training-time RepVGG block counts without hidden defaults."""
    if not args.repvgg_units_per_stage.strip():
        return [2, 2, 2, 1]

    parts = [part.strip() for part in args.repvgg_units_per_stage.split(",") if part.strip()]
    if len(parts) != 4:
        raise SystemExit(
            "--repvgg_units_per_stage must contain exactly four comma-separated values, "
            "one for each RepVGG stage."
        )
    try:
        units = [int(part) for part in parts]
    except ValueError as exc:
        raise SystemExit("--repvgg_units_per_stage values must be integers.") from exc
    if any(unit < 0 for unit in units):
        raise SystemExit("--repvgg_units_per_stage values must be non-negative.")
    if not any(units):
        raise SystemExit("--repvgg_units_per_stage must retain at least one RepVGG unit.")
    return units


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


def repvgg_unit(
    tf,
    x,
    filters: int,
    kernel_size: int,
    regularizer,
    stage: int,
    unit: int,
    args: argparse.Namespace,
):
    prefix = f"stage{stage}_unit{unit}"
    branches = []

    branch_3x3 = tf.keras.layers.Conv2D(
        filters,
        kernel_size=kernel_size,
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

    # PROJECT_LOCAL_MOD: retain the 4x4 deployment geometry required by the
    # CoralNPU-oriented path, while providing a 3x3 receptive-field branch
    # during optimization. The exporter folds this branch into the same 4x4
    # kernel using TensorFlow SAME-padding alignment.
    if kernel_size == 4 and args.repvgg_4x4_aux_3x3:
        branch_aux3 = tf.keras.layers.Conv2D(
            filters,
            kernel_size=3,
            padding="same",
            use_bias=False,
            kernel_regularizer=regularizer,
            name=f"{prefix}_rbr_aux3_conv",
        )(x)
        branch_aux3 = tf.keras.layers.BatchNormalization(
            name=f"{prefix}_rbr_aux3_bn"
        )(branch_aux3)
        branch_aux3 = maybe_scale_branch(
            tf,
            branch_aux3,
            args.repvgg_branch_scale,
            name=f"{prefix}_rbr_aux3_scale",
        )
        branches.append(branch_aux3)

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
    regularizer = kernel_regularizer(tf, args.weight_decay, args.optimizer)

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


def build_repvgg_model(
    tf, args: argparse.Namespace, num_classes: int, default_kernel: int
):
    image_size = args.image_size
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = add_training_augmentation(tf, inputs, args.augmentation_mode)
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(x)
    regularizer = kernel_regularizer(tf, args.weight_decay, args.optimizer)

    stage_kernel_sizes = parse_repvgg_kernel_schedule(args, default_kernel)
    stem_filters = scaled_channels(16, args.width_multiplier)
    x = conv_bn_relu(tf, x, stem_filters, stage_kernel_sizes[0], regularizer, "stem")

    # PROJECT_LOCAL_MOD: keep deployment channels explicitly controllable so
    # 4x4 candidates can fill CoralNPU's e32,m4 output-channel blocks.
    stage_filters = parse_stage_channels(args) + [args.head_channels]
    units_per_stage = parse_repvgg_units_per_stage(args)
    for stage, (base_filters, units, kernel_size) in enumerate(
        zip(stage_filters, units_per_stage, stage_kernel_sizes), start=1
    ):
        filters = scaled_channels(base_filters, args.width_multiplier)
        if stage > 1:
            x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"stage{stage}_pool")(x)
            x = conv_bn_relu(
                tf, x, filters, kernel_size, regularizer, f"stage{stage}_entry"
            )
        elif stem_filters != filters:
            x = conv_bn_relu(
                tf, x, filters, kernel_size, regularizer, f"stage{stage}_entry"
            )
        for unit in range(1, units + 1):
            x = repvgg_unit(
                tf,
                x,
                filters,
                kernel_size,
                regularizer,
                stage,
                unit,
                args,
            )

    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(args.dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(
        inputs=inputs,
        outputs=outputs,
        name="gesture_repvgg_hybrid_train",
    )


def build_model(tf, args: argparse.Namespace, num_classes: int):
    if args.variant == "repvgg_3x3":
        return build_repvgg_model(tf, args, num_classes, default_kernel=3)
    if args.variant == "repvgg_4x4":
        return build_repvgg_model(tf, args, num_classes, default_kernel=4)
    if args.variant == "repvgg_hybrid":
        return build_repvgg_model(tf, args, num_classes, default_kernel=4)
    if args.variant == "residual_3x3":
        return build_residual_3x3_model(tf, args, num_classes)
    image_size = args.image_size
    inputs = tf.keras.Input(shape=(image_size, image_size, 3), name="image")
    x = inputs
    if args.variant in {
        "regularized_3x3",
        "regularized_plain",
        "residual_3x3",
        "repvgg_3x3",
        "repvgg_4x4",
        "repvgg_hybrid",
    }:
        x = add_training_augmentation(tf, x, args.augmentation_mode)
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(x)
    regularizer = kernel_regularizer(tf, args.weight_decay, args.optimizer)
    body_kernel_sizes = parse_body_kernel_schedule(args)

    # Keep the network intentionally plain-conv-heavy so kernel sweeps can be
    # compared with the same training recipe and channel schedule.
    for block, filters in enumerate(parse_stage_channels(args), start=1):
        kernel_size = body_kernel_sizes[block - 1]
        body_kernel_label = kernel_label(kernel_size)
        x = tf.keras.layers.Conv2D(
            filters,
            kernel_size=kernel_size,
            padding="same",
            use_bias=False,
            kernel_regularizer=regularizer,
            name=f"conv{block}_{body_kernel_label}_a",
        )(x)
        x = tf.keras.layers.BatchNormalization(name=f"bn{block}_a")(x)
        x = tf.keras.layers.ReLU(name=f"relu{block}_a")(x)
        x = tf.keras.layers.Conv2D(
            filters,
            kernel_size=kernel_size,
            padding="same",
            use_bias=False,
            kernel_regularizer=regularizer,
            name=f"conv{block}_{body_kernel_label}_b",
        )(x)
        x = tf.keras.layers.BatchNormalization(name=f"bn{block}_b")(x)
        x = tf.keras.layers.ReLU(name=f"relu{block}_b")(x)
        x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"pool{block}")(x)

    x = tf.keras.layers.Conv2D(
        args.head_channels,
        kernel_size=args.head_kernel_size,
        padding="same",
        activation="relu",
        kernel_regularizer=regularizer,
        name=f"conv_head_{args.head_kernel_size}x{args.head_kernel_size}",
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
    if args.lr_schedule != "constant" and args.reduce_lr_on_plateau:
        raise SystemExit("Cannot combine --lr_schedule cosine with --reduce_lr_on_plateau.")
    if args.min_learning_rate > args.learning_rate:
        raise SystemExit("--min_learning_rate must be <= --learning_rate.")
    if not 0.0 <= args.mixup_probability <= 1.0:
        raise SystemExit("--mixup_probability must be between 0 and 1.")

    data_dir = Path(args.data_dir).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    train_ds, val_ds, test_ds, class_names = load_datasets(
        tf, data_dir, args.image_size, args.batch_size, args.seed
    )
    train_ds = maybe_cache_dataset(train_ds, args.cache_mode == "all")
    val_ds = maybe_cache_dataset(val_ds, args.cache_mode in {"eval", "all"})
    if test_ds is not None:
        test_ds = maybe_cache_dataset(test_ds, args.cache_mode in {"eval", "all"})

    use_soft_labels = args.label_smoothing > 0 or args.mixup_alpha > 0
    train_ds = maybe_one_hot(tf, train_ds, len(class_names), use_soft_labels)
    val_ds = maybe_one_hot(tf, val_ds, len(class_names), use_soft_labels)
    if test_ds is not None:
        test_ds = maybe_one_hot(tf, test_ds, len(class_names), use_soft_labels)
    train_ds = apply_mixup(tf, train_ds, args.mixup_alpha, args.mixup_probability)

    autotune = tf.data.AUTOTUNE
    train_ds = train_ds.prefetch(autotune)
    val_ds = val_ds.prefetch(autotune)
    if test_ds is not None:
        test_ds = test_ds.prefetch(autotune)

    student = build_model(tf, args, len(class_names))
    supervised_loss = build_loss(
        tf, use_soft_labels=use_soft_labels, label_smoothing=args.label_smoothing
    )
    teacher = load_distillation_teacher(tf, args, class_names)
    if teacher is None:
        student.compile(
            optimizer=build_optimizer(tf, args),
            loss=supervised_loss,
            metrics=["accuracy"],
        )
        training_model = student
        checkpoint_callback = tf.keras.callbacks.ModelCheckpoint(
            out_dir / "model.keras", monitor="val_accuracy", save_best_only=True
        )
    else:
        training_model = build_distillation_trainer(
            tf,
            student,
            teacher,
            supervised_loss,
            args.distill_alpha,
            args.distill_temperature,
            use_soft_labels,
        )
        training_model.compile(optimizer=build_optimizer(tf, args))
        checkpoint_callback = build_student_checkpoint(tf, student, out_dir / "model.keras")

    callbacks = []
    if args.lr_schedule == "cosine":
        callbacks.append(
            tf.keras.callbacks.LearningRateScheduler(
                lambda epoch, _lr: cosine_epoch_lr(
                    epoch=epoch,
                    total_epochs=args.epochs,
                    base_lr=args.learning_rate,
                    min_lr=args.min_learning_rate,
                    warmup_epochs=args.warmup_epochs,
                ),
                verbose=1,
            )
        )
    callbacks += [
        checkpoint_callback,
        tf.keras.callbacks.CSVLogger(out_dir / "history.csv"),
        tf.keras.callbacks.EarlyStopping(
            monitor="val_accuracy",
            # PROJECT_LOCAL_MOD: Keras 3 cannot infer the optimization direction
            # for this metric when it is emitted by the distillation wrapper.
            mode="max",
            patience=args.early_stop_patience,
            restore_best_weights=True,
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
    history = training_model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=args.epochs,
        callbacks=callbacks,
    )
    checkpoint_path = out_dir / "model.keras"
    if not checkpoint_path.is_file():
        # An interrupted run can end before the first callback write only when
        # no epoch completed; preserve a usable student in that edge case.
        student.save(checkpoint_path)
    (out_dir / "labels.txt").write_text("\n".join(class_names) + "\n", encoding="utf-8")

    test_metrics = None
    if test_ds is not None:
        if teacher is not None:
            student.compile(
                optimizer=build_optimizer(tf, args),
                loss=supervised_loss,
                metrics=["accuracy"],
            )
        test_values = student.evaluate(test_ds, verbose=1)
        test_metrics = dict(zip(student.metrics_names, [float(v) for v in test_values]))
    test_inference = evaluate_model_per_image(student, data_dir, class_names)

    summary = {
        "data_dir": str(data_dir),
        "variant": args.variant,
        "image_size": args.image_size,
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history.get("loss", [])),
        "best_epoch": int(np.argmax(history.history["val_accuracy"]) + 1),
        "best_val_accuracy": float(np.max(history.history["val_accuracy"])),
        "learning_rate": args.learning_rate,
        "optimizer": args.optimizer,
        "lr_schedule": args.lr_schedule,
        "warmup_epochs": args.warmup_epochs,
        "min_learning_rate": args.min_learning_rate,
        "grad_clipnorm": args.grad_clipnorm,
        "early_stop_patience": args.early_stop_patience,
        "cache_mode": args.cache_mode,
        "dropout": args.dropout,
        "weight_decay": args.weight_decay,
        "width_multiplier": args.width_multiplier,
        "body_kernel_size": args.body_kernel_size,
        "body_kernel_schedule": parse_body_kernel_schedule(args),
        "stage_channels": parse_stage_channels(args),
        "head_channels": args.head_channels,
        "head_kernel_size": args.head_kernel_size,
        "label_smoothing": args.label_smoothing,
        "mixup_alpha": args.mixup_alpha,
        "mixup_probability": args.mixup_probability,
        "reduce_lr_on_plateau": args.reduce_lr_on_plateau,
        "augmentation_mode": args.augmentation_mode,
        "repvgg_branch_scale": args.repvgg_branch_scale,
        "repvgg_disable_identity": args.repvgg_disable_identity,
        "repvgg_4x4_aux_3x3": args.repvgg_4x4_aux_3x3,
        "repvgg_kernel_schedule": (
            parse_repvgg_kernel_schedule(
                args, 4 if args.variant in {"repvgg_4x4", "repvgg_hybrid"} else 3
            )
            if args.variant.startswith("repvgg")
            else None
        ),
        "repvgg_units_per_stage": (
            parse_repvgg_units_per_stage(args) if args.variant.startswith("repvgg") else None
        ),
        "distill_teacher_model": str(args.distill_teacher_model.resolve())
        if args.distill_teacher_model is not None
        else None,
        "distill_alpha": args.distill_alpha,
        "distill_temperature": args.distill_temperature,
        "params": int(student.count_params()),
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
