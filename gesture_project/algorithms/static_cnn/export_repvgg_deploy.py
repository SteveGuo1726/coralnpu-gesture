"""Export a training-time RepVGG-style classifier into a plain-conv deploy model."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Input training-time .keras model.")
    parser.add_argument("--out", required=True, help="Output deploy-time .keras model.")
    parser.add_argument(
        "--metadata_out",
        help="Optional JSON metadata path describing the exported deploy model.",
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


def scaled_stage_filters(train_model) -> list[int]:
    filters = []
    stage = 1
    while True:
        candidate_names = [
            f"stage{stage}_unit1_rbr_dense_conv",
            f"stage{stage}_entry_conv",
        ]
        for layer_name in candidate_names:
            try:
                layer = train_model.get_layer(layer_name)
            except ValueError:
                continue
            filters.append(int(layer.filters))
            break
        else:
            break
        stage += 1
    if not filters:
        raise SystemExit("No RepVGG-style stages found in the input model.")
    return filters


def branch_scale_for_layer(train_model, layer_name: str) -> float:
    try:
        layer = train_model.get_layer(layer_name)
    except ValueError:
        return 1.0
    scale = getattr(layer, "scale", None)
    if scale is None:
        return 1.0
    return float(scale)


def fuse_bn_params(gamma, beta, mean, variance, epsilon: float):
    scale = gamma / np.sqrt(variance + epsilon)
    bias = beta - mean * scale
    return scale, bias


def fuse_conv_bn(conv_layer, bn_layer):
    weights = conv_layer.get_weights()
    kernel = weights[0]
    if conv_layer.use_bias and len(weights) > 1:
        bias = weights[1]
    else:
        bias = np.zeros(kernel.shape[-1], dtype=np.float32)
    gamma, beta, mean, variance = bn_layer.get_weights()
    scale, bn_bias = fuse_bn_params(gamma, beta, mean, variance, bn_layer.epsilon)
    fused_kernel = kernel * scale.reshape((1, 1, 1, -1))
    fused_bias = bn_bias + bias * scale
    return fused_kernel.astype(np.float32), fused_bias.astype(np.float32)


def fuse_identity_bn(num_channels: int, bn_layer, kernel_size: int):
    gamma, beta, mean, variance = bn_layer.get_weights()
    scale, bn_bias = fuse_bn_params(gamma, beta, mean, variance, bn_layer.epsilon)
    kernel = np.zeros(
        (kernel_size, kernel_size, num_channels, num_channels), dtype=np.float32
    )
    # TensorFlow SAME with an even kernel places the identity at floor((K-1)/2).
    center = (kernel_size - 1) // 2
    kernel[center, center, np.arange(num_channels), np.arange(num_channels)] = (
        scale.astype(np.float32)
    )
    return kernel, bn_bias.astype(np.float32)


def pad_1x1_to_kernel(kernel_1x1, kernel_size: int):
    channels_in = kernel_1x1.shape[2]
    channels_out = kernel_1x1.shape[3]
    kernel = np.zeros(
        (kernel_size, kernel_size, channels_in, channels_out), dtype=np.float32
    )
    center = (kernel_size - 1) // 2
    kernel[center, center, :, :] = kernel_1x1[0, 0, :, :]
    return kernel


def pad_same_kernel_to_kernel(kernel_small, kernel_size: int):
    """Embed a SAME-padded smaller kernel into a larger SAME-padded kernel.

    PROJECT_LOCAL_MOD: TensorFlow SAME uses ``floor((K - 1) / 2)`` leading
    padding for stride-one convolutions. A 3x3 branch therefore starts at
    offset zero inside a 4x4 kernel (whereas a 1x1 branch starts at offset one).
    This preserves every output position, including image borders.
    """
    small_height, small_width, channels_in, channels_out = kernel_small.shape
    if small_height != small_width or small_height > kernel_size:
        raise ValueError(
            f"Cannot embed kernel with shape {kernel_small.shape} into {kernel_size}x{kernel_size}."
        )
    kernel = np.zeros(
        (kernel_size, kernel_size, channels_in, channels_out), dtype=np.float32
    )
    offset = (kernel_size - 1) // 2 - (small_height - 1) // 2
    kernel[
        offset : offset + small_height,
        offset : offset + small_width,
        :, :,
    ] = kernel_small
    return kernel


def build_deploy_model(
    tf,
    input_shape,
    stem_filters: int,
    stem_kernel_size: int,
    stage_filters: list[int],
    units_per_stage: list[int],
    stage_kernel_sizes: list[int],
    dropout: float,
    num_classes: int,
):
    height, width, channels = input_shape
    inputs = tf.keras.Input(shape=(height, width, channels), name="image")
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(inputs)
    x = tf.keras.layers.Conv2D(
        stem_filters,
        kernel_size=stem_kernel_size,
        padding="same",
        use_bias=True,
        name="stem_reparam",
    )(x)
    x = tf.keras.layers.ReLU(name="stem_reparam_relu")(x)

    # The stem can have a different width from stage 1.  Keep that distinction
    # explicit; otherwise export silently creates a wrong weight shape.
    current_filters = stem_filters
    for stage, (filters, units, kernel_size) in enumerate(
        zip(stage_filters, units_per_stage, stage_kernel_sizes), start=1
    ):
        if stage > 1:
            x = tf.keras.layers.MaxPooling2D(pool_size=2, name=f"stage{stage}_pool")(x)
            x = tf.keras.layers.Conv2D(
                filters,
                kernel_size=kernel_size,
                padding="same",
                use_bias=True,
                name=f"stage{stage}_entry_reparam",
            )(x)
            x = tf.keras.layers.ReLU(name=f"stage{stage}_entry_reparam_relu")(x)
        elif current_filters != filters:
            x = tf.keras.layers.Conv2D(
                filters,
                kernel_size=kernel_size,
                padding="same",
                use_bias=True,
                name=f"stage{stage}_entry_reparam",
            )(x)
            x = tf.keras.layers.ReLU(name=f"stage{stage}_entry_reparam_relu")(x)
        current_filters = filters
        for unit in range(1, units + 1):
            x = tf.keras.layers.Conv2D(
                filters,
                kernel_size=kernel_size,
                padding="same",
                use_bias=True,
                name=f"stage{stage}_unit{unit}_reparam",
            )(x)
            x = tf.keras.layers.ReLU(name=f"stage{stage}_unit{unit}_reparam_relu")(x)

    x = tf.keras.layers.GlobalAveragePooling2D(name="global_avg_pool")(x)
    x = tf.keras.layers.Dropout(dropout, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(
        inputs=inputs,
        outputs=outputs,
        name="gesture_repvgg_hybrid_deploy",
    )


def load_units_per_stage(train_model, num_stages: int) -> list[int]:
    units = []
    for stage in range(1, num_stages + 1):
        count = 0
        while True:
            count += 1
            name = f"stage{stage}_unit{count}_rbr_dense_conv"
            try:
                train_model.get_layer(name)
            except ValueError:
                count -= 1
                break
        units.append(count)
    return units


def load_stage_kernel_sizes(train_model, num_stages: int) -> list[int]:
    """Infer each deploy-time stage kernel from actual training layers.

    PROJECT_LOCAL_MOD: a stage may intentionally contain zero re-parameterized
    units when it is the plain 1x1 classification head, so it cannot always be
    inferred from ``unit1`` alone.
    """
    kernel_sizes = []
    for stage in range(1, num_stages + 1):
        candidates = [
            f"stage{stage}_unit1_rbr_dense_conv",
            f"stage{stage}_entry_conv",
        ]
        if stage == 1:
            candidates.append("stem_conv")
        for layer_name in candidates:
            try:
                layer = train_model.get_layer(layer_name)
            except ValueError:
                continue
            kernel_size = int(layer.kernel_size[0])
            if kernel_size not in {1, 3, 4}:
                raise SystemExit(
                    f"Expected 1x1, 3x3, or 4x4 RepVGG stage, got {kernel_size}x{kernel_size}."
                )
            kernel_sizes.append(kernel_size)
            break
        else:
            raise SystemExit(f"Cannot infer kernel size for RepVGG stage {stage}.")
    return kernel_sizes


def fuse_repvgg_block(train_model, stage: int, unit: int):
    prefix = f"stage{stage}_unit{unit}"
    kernel_3x3, bias_3x3 = fuse_conv_bn(
        train_model.get_layer(f"{prefix}_rbr_dense_conv"),
        train_model.get_layer(f"{prefix}_rbr_dense_bn"),
    )
    dense_scale = branch_scale_for_layer(train_model, f"{prefix}_rbr_dense_scale")
    kernel_3x3 *= dense_scale
    bias_3x3 *= dense_scale
    kernel_1x1, bias_1x1 = fuse_conv_bn(
        train_model.get_layer(f"{prefix}_rbr_1x1_conv"),
        train_model.get_layer(f"{prefix}_rbr_1x1_bn"),
    )
    one_scale = branch_scale_for_layer(train_model, f"{prefix}_rbr_1x1_scale")
    kernel_1x1 *= one_scale
    bias_1x1 *= one_scale
    kernel_size = int(kernel_3x3.shape[0])
    if kernel_3x3.shape[0] != kernel_3x3.shape[1]:
        raise ValueError(f"RepVGG dense branch must be square, got {kernel_3x3.shape}")
    kernel = kernel_3x3 + pad_1x1_to_kernel(kernel_1x1, kernel_size)
    bias = bias_3x3 + bias_1x1

    try:
        aux3_conv = train_model.get_layer(f"{prefix}_rbr_aux3_conv")
        aux3_bn = train_model.get_layer(f"{prefix}_rbr_aux3_bn")
    except ValueError:
        aux3_conv = aux3_bn = None
    if aux3_conv is not None:
        aux3_kernel, aux3_bias = fuse_conv_bn(aux3_conv, aux3_bn)
        aux3_scale = branch_scale_for_layer(train_model, f"{prefix}_rbr_aux3_scale")
        aux3_kernel *= aux3_scale
        aux3_bias *= aux3_scale
        kernel += pad_same_kernel_to_kernel(aux3_kernel, kernel_size)
        bias += aux3_bias

    try:
        identity_bn = train_model.get_layer(f"{prefix}_rbr_identity_bn")
    except ValueError:
        identity_bn = None
    if identity_bn is not None:
        identity_kernel, identity_bias = fuse_identity_bn(
            kernel.shape[2], identity_bn, kernel_size
        )
        identity_scale = branch_scale_for_layer(train_model, f"{prefix}_rbr_identity_scale")
        identity_kernel *= identity_scale
        identity_bias *= identity_scale
        kernel += identity_kernel
        bias += identity_bias
    return kernel.astype(np.float32), bias.astype(np.float32)


def export_deploy_model(tf, model_path: Path, out_path: Path, metadata_path: Path | None):
    train_model = tf.keras.models.load_model(model_path)
    if "repvgg" not in train_model.name:
        raise SystemExit(
            f"Expected a RepVGG-style training model, got '{train_model.name}'."
        )

    input_shape = train_model.input_shape
    if not isinstance(input_shape, (list, tuple)) or len(input_shape) != 4:
        raise SystemExit(f"Expected NHWC input shape, got {input_shape}")
    _, height, width, channels = input_shape

    stage_filters = scaled_stage_filters(train_model)
    units_per_stage = load_units_per_stage(train_model, len(stage_filters))
    stage_kernel_sizes = load_stage_kernel_sizes(train_model, len(stage_filters))
    stem_layer = train_model.get_layer("stem_conv")
    stem_filters = int(stem_layer.filters)
    stem_kernel_size = int(stem_layer.kernel_size[0])
    dropout = float(train_model.get_layer("dropout").rate)
    num_classes = int(train_model.get_layer("class").units)

    deploy_model = build_deploy_model(
        tf,
        (int(height), int(width), int(channels)),
        stem_filters,
        stem_kernel_size,
        stage_filters,
        units_per_stage,
        stage_kernel_sizes,
        dropout,
        num_classes,
    )

    stem_kernel, stem_bias = fuse_conv_bn(
        train_model.get_layer("stem_conv"),
        train_model.get_layer("stem_bn"),
    )
    deploy_model.get_layer("stem_reparam").set_weights([stem_kernel, stem_bias])

    # Match the deploy graph's real stem width so stage 1 entry weights are
    # copied whenever the stem and stage 1 widths differ.
    current_filters = stem_filters
    for stage, filters in enumerate(stage_filters, start=1):
        if stage > 1 or current_filters != filters:
            entry_kernel, entry_bias = fuse_conv_bn(
                train_model.get_layer(f"stage{stage}_entry_conv"),
                train_model.get_layer(f"stage{stage}_entry_bn"),
            )
            deploy_model.get_layer(f"stage{stage}_entry_reparam").set_weights([entry_kernel, entry_bias])
        current_filters = filters
        for unit in range(1, units_per_stage[stage - 1] + 1):
            kernel, bias = fuse_repvgg_block(train_model, stage, unit)
            deploy_model.get_layer(f"stage{stage}_unit{unit}_reparam").set_weights([kernel, bias])

    deploy_model.get_layer("class").set_weights(train_model.get_layer("class").get_weights())
    out_path.parent.mkdir(parents=True, exist_ok=True)
    deploy_model.save(out_path)

    if metadata_path is not None:
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata = {
            "source_model": str(model_path),
            "deploy_model": str(out_path),
            "input_shape": [int(height), int(width), int(channels)],
            "stage_filters": stage_filters,
            "units_per_stage": units_per_stage,
            "stage_kernel_sizes": stage_kernel_sizes,
            "has_4x4_aux_3x3": any(
                layer.name.endswith("_rbr_aux3_conv") for layer in train_model.layers
            ),
            "num_classes": num_classes,
        }
        metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()
    model_path = Path(args.model).resolve()
    out_path = Path(args.out).resolve()
    metadata_path = Path(args.metadata_out).resolve() if args.metadata_out else None
    export_deploy_model(tf, model_path, out_path, metadata_path)
    print(f"Wrote {out_path}")
    if metadata_path is not None:
        print(f"Wrote {metadata_path}")


if __name__ == "__main__":
    main()
