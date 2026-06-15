"""Convert the static gesture CNN to full-int8 TFLite."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Input .keras model.")
    parser.add_argument("--data_dir", required=True, help="Image-folder dataset root.")
    parser.add_argument("--out", required=True, help="Output .tflite path.")
    parser.add_argument("--image_size", type=int, default=64)
    parser.add_argument("--samples", type=int, default=200)
    parser.add_argument("--batch_size", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20260601)
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


def representative_dataset(tf, data_dir: Path, image_size: int, samples: int, seed: int):
    rep_dir = data_dir / "train"
    if not rep_dir.is_dir():
        raise SystemExit(f"Missing representative data directory: {rep_dir}")
    ds = tf.keras.utils.image_dataset_from_directory(
        rep_dir,
        image_size=(image_size, image_size),
        batch_size=1,
        seed=seed,
        shuffle=True,
    )
    ds = ds.map(lambda image, _label: image)
    count = 0
    for image in ds:
        yield [tf.cast(image, tf.float32)]
        count += 1
        if count >= samples:
            break


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()

    model_path = Path(args.model).resolve()
    data_dir = Path(args.data_dir).resolve()
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    model = tf.keras.models.load_model(model_path)
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = lambda: representative_dataset(
        tf, data_dir, args.image_size, args.samples, args.seed
    )
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8

    model_int8 = converter.convert()
    out_path.write_bytes(model_int8)
    print(f"Wrote {out_path} ({len(model_int8)} bytes)")


if __name__ == "__main__":
    main()
