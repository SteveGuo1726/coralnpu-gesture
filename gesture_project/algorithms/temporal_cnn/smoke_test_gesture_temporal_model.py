"""Run a bounded functional, gradient, and TFLite conversion smoke test.

PROJECT_LOCAL_MOD: This test uses deterministic synthetic frames only because
the real IPN/EgoGesture videos are not present yet. It is not an accuracy
result and must never be reported as one.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np

from gesture_temporal_model import (
    TemporalModelConfig,
    build_gesture_temporal_model,
    require_tensorflow,
    summarize_model,
)


def main() -> None:
    tf = require_tensorflow()
    tf.keras.utils.set_random_seed(20260814)
    config = TemporalModelConfig(sequence_length=8, num_classes=14)
    model = build_gesture_temporal_model(config)
    frames = tf.random.stateless_uniform(
        (2, config.sequence_length, config.image_size, config.image_size, 3),
        seed=(20260814, 1),
        minval=0.0,
        maxval=255.0,
        dtype=tf.float32,
    )
    labels = tf.constant([2, 7], dtype=tf.int32)
    loss_fn = tf.keras.losses.SparseCategoricalCrossentropy()
    with tf.GradientTape() as tape:
        probabilities = model(frames, training=True)
        loss = loss_fn(labels, probabilities)
    gradients = tape.gradient(loss, model.trainable_variables)
    non_null = [gradient for gradient in gradients if gradient is not None]
    if len(non_null) != len(model.trainable_variables):
        raise SystemExit("A trainable variable has no gradient.")
    optimizer = tf.keras.optimizers.Adam(learning_rate=1e-3)
    before = model.trainable_variables[0].numpy().copy()
    optimizer.apply_gradients(zip(gradients, model.trainable_variables))
    weight_delta = float(np.linalg.norm(model.trainable_variables[0].numpy() - before))

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite_model = converter.convert()
    summary = summarize_model(model)
    summary.update(
        {
            "synthetic_batch": [2, config.sequence_length, config.image_size, config.image_size, 3],
            "loss": float(loss.numpy()),
            "weight_delta": weight_delta,
            "tflite_bytes": len(tflite_model),
        }
    )
    with tempfile.TemporaryDirectory(prefix="gesture-temporal-smoke-") as temp_dir:
        Path(temp_dir, "model.tflite").write_bytes(tflite_model)
        Path(temp_dir, "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
