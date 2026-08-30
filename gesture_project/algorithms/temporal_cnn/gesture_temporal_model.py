"""Hardware-aware static and dynamic gesture model.

PROJECT_LOCAL_MOD: This is a project model, not an upstream CoralNPU model.
The design keeps the expensive spatial computation in INT8 Conv2D operators
and makes temporal mixing mostly reduction and data movement. It is intended
to be trained on IPN Hand and EgoGesture after the real frames are available.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TemporalModelConfig:
    image_size: int = 96
    sequence_length: int = 8
    num_classes: int = 14
    stage_channels: tuple[int, int, int] = (16, 48, 80)
    temporal_channels: int = 96
    architecture: str = "legacy_shift"


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Use gesture_project/algorithms/.venv/bin/python."
        ) from exc
    return tf


def _validate_config(config: TemporalModelConfig) -> None:
    if config.image_size <= 0 or config.sequence_length <= 0:
        raise ValueError("image_size and sequence_length must be positive")
    if len(config.stage_channels) != 3:
        raise ValueError("stage_channels must contain three spatial stages")
    if any(channel <= 0 or channel % 16 for channel in config.stage_channels):
        raise ValueError("spatial channels must be positive multiples of 16")
    if config.temporal_channels <= 0 or config.temporal_channels % 48:
        raise ValueError("temporal_channels must be a positive multiple of 48")
    if config.architecture not in {"legacy_shift", "coral3x3_bn"}:
        raise ValueError("architecture must be legacy_shift or coral3x3_bn")


def _temporal_shift_layer(tf):
    class TemporalShift(tf.keras.layers.Layer):
        """Move channel groups to adjacent frames without multiplication."""

        def __init__(self, **kwargs):
            super().__init__(**kwargs)

        def call(self, inputs):
            channels = inputs.shape[-1]
            if channels is None or channels % 3:
                raise ValueError("TemporalShift needs a statically known channel count divisible by 3")
            group = channels // 3
            zeros = tf.zeros_like(inputs[:, :1, :, :, :group])
            previous = tf.concat([zeros, inputs[:, :-1, :, :, :group]], axis=1)
            following = tf.concat([inputs[:, 1:, :, :, group : 2 * group], zeros], axis=1)
            stationary = inputs[:, :, :, :, 2 * group :]
            return tf.concat([previous, following, stationary], axis=-1)

        def get_config(self):
            return super().get_config()

    return TemporalShift


def _temporal_summary_layer(tf):
    class TemporalSummary(tf.keras.layers.Layer):
        """Emit mean, max, and signed first-to-last motion statistics."""

        def call(self, inputs):
            mean = tf.reduce_mean(inputs, axis=1)
            maximum = tf.reduce_max(inputs, axis=1)
            signed_delta = inputs[:, -1, :] - inputs[:, 0, :]
            return tf.concat([mean, maximum, signed_delta], axis=-1)

        def get_config(self):
            return super().get_config()

    return TemporalSummary


def build_gesture_temporal_model(config: TemporalModelConfig | None = None):
    """Build the shared static/dynamic model.

    The spatial deployment shape is ``3x3 / 4x4 / 4x4 / 1x1`` with channel
    counts ``16 / 48 / 80 / 96`` by default. The final 96-channel embedding is
    divisible into three 32-channel temporal-shift groups and remains aligned
    to the RVV output-channel blocks. For a static model use
    ``sequence_length=1``; no second architecture is needed.
    """
    tf = require_tensorflow()
    config = config or TemporalModelConfig()
    _validate_config(config)
    if config.architecture == "coral3x3_bn":
        return _build_coral3x3_bn_model(tf, config)

    shift_layer = _temporal_shift_layer(tf)
    summary_layer = _temporal_summary_layer(tf)

    inputs = tf.keras.Input(
        shape=(config.sequence_length, config.image_size, config.image_size, 3),
        name="frames",
    )
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(inputs)

    spatial_names = ("spatial_stem_3x3", "spatial_stage2_4x4", "spatial_stage3_4x4")
    spatial_kernels = (3, 4, 4)
    for index, (channels, kernel_size, name) in enumerate(
        zip(config.stage_channels, spatial_kernels, spatial_names, strict=True)
    ):
        x = tf.keras.layers.TimeDistributed(
            tf.keras.layers.Conv2D(
                channels,
                kernel_size=kernel_size,
                padding="same",
                use_bias=True,
                name=name,
            ),
            name=f"{name}_per_frame",
        )(x)
        x = tf.keras.layers.TimeDistributed(
            tf.keras.layers.ReLU(name=f"{name}_relu"),
            name=f"{name}_per_frame_relu",
        )(x)
        if index < 2:
            x = tf.keras.layers.TimeDistributed(
                tf.keras.layers.MaxPooling2D(pool_size=2, name=f"{name}_pool"),
                name=f"{name}_per_frame_pool",
            )(x)

    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.Conv2D(
            config.temporal_channels,
            kernel_size=1,
            padding="same",
            use_bias=True,
            name="spatial_embedding_1x1",
        ),
        name="spatial_embedding_1x1_per_frame",
    )(x)
    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.ReLU(name="spatial_embedding_1x1_relu"),
        name="spatial_embedding_1x1_per_frame_relu",
    )(x)
    spatial_height = config.image_size // 4
    spatial_width = config.image_size // 4
    x = shift_layer(name="temporal_shift_zero_mac")(x)
    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.GlobalAveragePooling2D(name="per_frame_global_average_pool"),
        name="per_frame_global_average_pool_wrapper",
    )(x)
    x = summary_layer(name="temporal_summary_mean_max_delta")(x)
    x = tf.keras.layers.Reshape((1, 1, config.temporal_channels * 3), name="temporal_fusion_input")(x)
    x = tf.keras.layers.Conv2D(
        config.temporal_channels,
        kernel_size=1,
        padding="same",
        use_bias=True,
        name="temporal_fusion_1x1",
    )(x)
    x = tf.keras.layers.ReLU(name="temporal_fusion_1x1_relu")(x)
    x = tf.keras.layers.Flatten(name="temporal_embedding_flatten")(x)
    outputs = tf.keras.layers.Dense(
        config.num_classes, activation="softmax", name="class"
    )(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_temporal_shift_cnn")


def _build_coral3x3_bn_model(tf, config: TemporalModelConfig):
    """Build the project hardware candidate with only regular spatial Conv2D.

    PROJECT_LOCAL_MOD: This is a project candidate, not an upstream CoralNPU
    module. Batch normalization is kept during training and is intended to be
    folded into convolution weights before INT8 export. The spatial path uses
    stride-2 regular 3x3 convolutions so it maps to the same sliding-window
    primitive at every stage; temporal mixing remains shift, mean, max, and
    endpoint delta with no recurrent state.
    """
    inputs = tf.keras.Input(
        shape=(config.sequence_length, config.image_size, config.image_size, 3),
        name="frames",
    )
    x = tf.keras.layers.Rescaling(1.0 / 255.0, name="rescale")(inputs)
    channels = (24, 48, 96)
    for index, channel_count in enumerate(channels):
        x = tf.keras.layers.TimeDistributed(
            tf.keras.layers.Conv2D(
                channel_count,
                kernel_size=3,
                strides=2,
                padding="same",
                use_bias=False,
                name=f"coral3x3_stage{index + 1}",
            ),
            name=f"coral3x3_stage{index + 1}_per_frame",
        )(x)
        x = tf.keras.layers.TimeDistributed(
            tf.keras.layers.BatchNormalization(name=f"coral3x3_stage{index + 1}_bn"),
            name=f"coral3x3_stage{index + 1}_bn_per_frame",
        )(x)
        x = tf.keras.layers.TimeDistributed(
            tf.keras.layers.ReLU(name=f"coral3x3_stage{index + 1}_relu"),
            name=f"coral3x3_stage{index + 1}_relu_per_frame",
        )(x)

    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.Conv2D(
            config.temporal_channels,
            kernel_size=1,
            padding="same",
            use_bias=False,
            name="coral3x3_embedding_1x1",
        ),
        name="coral3x3_embedding_1x1_per_frame",
    )(x)
    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.BatchNormalization(name="coral3x3_embedding_bn"),
        name="coral3x3_embedding_bn_per_frame",
    )(x)
    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.ReLU(name="coral3x3_embedding_relu"),
        name="coral3x3_embedding_relu_per_frame",
    )(x)

    shift_layer = _temporal_shift_layer(tf)
    summary_layer = _temporal_summary_layer(tf)
    x = shift_layer(name="temporal_shift_zero_mac")(x)
    x = tf.keras.layers.TimeDistributed(
        tf.keras.layers.GlobalAveragePooling2D(name="per_frame_global_average_pool"),
        name="per_frame_global_average_pool_wrapper",
    )(x)
    x = summary_layer(name="temporal_summary_mean_max_delta")(x)
    x = tf.keras.layers.Reshape((1, 1, config.temporal_channels * 3), name="temporal_fusion_input")(x)
    x = tf.keras.layers.Conv2D(
        config.temporal_channels,
        kernel_size=1,
        padding="same",
        use_bias=True,
        name="temporal_fusion_1x1",
    )(x)
    x = tf.keras.layers.ReLU(name="temporal_fusion_1x1_relu")(x)
    x = tf.keras.layers.Flatten(name="temporal_embedding_flatten")(x)
    outputs = tf.keras.layers.Dense(config.num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="gesture_coral3x3_bn_temporal")


def summarize_model(model) -> dict:
    """Return a compact operator summary for later hardware comparison."""
    import tensorflow as tf  # pylint: disable=import-outside-toplevel

    convs = []
    for layer in model.layers:
        conv_layer = layer.layer if isinstance(layer, tf.keras.layers.TimeDistributed) else layer
        if isinstance(conv_layer, tf.keras.layers.Conv2D):
            # Keras 3 does not expose a stable ``input`` tensor for a Conv2D
            # nested inside TimeDistributed. The built kernel is the source
            # of truth for the input-channel count and is also what the
            # exported operator will use.
            input_channels = None
            if conv_layer.kernel is not None:
                input_channels = int(conv_layer.kernel.shape[2])
            convs.append(
                {
                    "name": conv_layer.name,
                    "kernel": [int(conv_layer.kernel_size[0]), int(conv_layer.kernel_size[1])],
                    "input_channels": input_channels,
                    "output_channels": int(conv_layer.filters),
                    "parameters": int(conv_layer.count_params()),
                }
            )
    return {
        "name": model.name,
        "input_shape": [int(value) if value is not None else None for value in model.input_shape],
        "output_shape": [int(value) if value is not None else None for value in model.output_shape],
        "parameters": int(model.count_params()),
        "conv2d_layers": convs,
    }
