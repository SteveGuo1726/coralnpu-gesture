"""Train a lightweight landmark MLP on extracted hand landmarks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


HAND_BONES = (
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (0, 9), (9, 10), (10, 11), (11, 12),
    (0, 13), (13, 14), (14, 15), (15, 16),
    (0, 17), (17, 18), (18, 19), (19, 20),
)
FINGERTIP_IDS = (4, 8, 12, 16, 20)
PALM_IDS = (0, 5, 9, 13, 17)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset_npz", required=True, help="NPZ produced by extract_static_hand_landmarks.py.")
    parser.add_argument("--out_dir", required=True, help="Directory for model outputs.")
    parser.add_argument("--batch_size", type=int, default=64)
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--learning_rate", type=float, default=1e-3)
    parser.add_argument("--dropout", type=float, default=0.25)
    parser.add_argument("--hidden_dims", default="256,128", help="Comma-separated hidden layer sizes.")
    parser.add_argument(
        "--feature_mode",
        choices=["coords", "coords_detect", "coords_bones_detect", "coords_bones_geom_detect"],
        default="coords",
        help=(
            "coords uses only the 21x3 normalized landmarks. "
            "coords_detect appends the hand-detected flag. "
            "coords_bones_detect adds 20 bone vectors. "
            "coords_bones_geom_detect further adds bone lengths and fingertip-to-palm geometry."
        ),
    )
    parser.add_argument("--seed", type=int, default=20260728)
    parser.add_argument(
        "--require_gpu",
        action="store_true",
        help="Exit immediately if TensorFlow cannot see a GPU device.",
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


def parse_hidden_dims(text: str) -> list[int]:
    dims = [int(item.strip()) for item in text.split(",") if item.strip()]
    if not dims:
        raise SystemExit("--hidden_dims must contain at least one integer.")
    return dims


def bone_vectors(coords: np.ndarray) -> np.ndarray:
    vectors = [coords[:, child, :] - coords[:, parent, :] for parent, child in HAND_BONES]
    return np.stack(vectors, axis=1).astype(np.float32)


def fingertip_geometry(coords: np.ndarray) -> np.ndarray:
    palm_center = coords[:, PALM_IDS, :].mean(axis=1, keepdims=True)
    fingertips = coords[:, FINGERTIP_IDS, :]
    fingertip_offsets = fingertips - palm_center
    fingertip_lengths = np.linalg.norm(fingertip_offsets, axis=2)
    return np.concatenate(
        [fingertip_offsets.reshape(coords.shape[0], -1), fingertip_lengths],
        axis=1,
    ).astype(np.float32)


def build_feature_matrix(
    x_flat: np.ndarray,
    detected: np.ndarray | None,
    feature_mode: str,
) -> np.ndarray:
    if x_flat.ndim != 2 or x_flat.shape[1] != 63:
        raise SystemExit(f"Expected landmark rows shaped [N, 63], got {x_flat.shape}")

    coords = x_flat.reshape((-1, 21, 3)).astype(np.float32)
    features = [x_flat.astype(np.float32)]

    include_detect = feature_mode in {
        "coords_detect",
        "coords_bones_detect",
        "coords_bones_geom_detect",
    }
    include_bones = feature_mode in {
        "coords_bones_detect",
        "coords_bones_geom_detect",
    }
    include_geom = feature_mode == "coords_bones_geom_detect"

    if include_bones:
        bones = bone_vectors(coords)
        features.append(bones.reshape((bones.shape[0], -1)))
    if include_geom:
        bone_lengths = np.linalg.norm(bone_vectors(coords), axis=2).astype(np.float32)
        features.append(bone_lengths)
        features.append(fingertip_geometry(coords))
    if include_detect:
        if detected is None:
            raise SystemExit(f"Feature mode {feature_mode} requires detected_* arrays in the dataset npz.")
        features.append(detected.astype(np.float32).reshape((-1, 1)))

    return np.concatenate(features, axis=1).astype(np.float32)


def build_model(tf, input_dim: int, num_classes: int, hidden_dims: list[int], dropout: float):
    inputs = tf.keras.Input(shape=(input_dim,), name="landmarks")
    x = inputs
    for index, hidden_dim in enumerate(hidden_dims, start=1):
        x = tf.keras.layers.Dense(hidden_dim, use_bias=False, name=f"dense{index}")(x)
        x = tf.keras.layers.BatchNormalization(name=f"bn{index}")(x)
        x = tf.keras.layers.ReLU(name=f"relu{index}")(x)
        x = tf.keras.layers.Dropout(dropout, name=f"dropout{index}")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="class")(x)
    return tf.keras.Model(inputs=inputs, outputs=outputs, name="landmark_static_mlp")


def make_dataset(tf, x: np.ndarray, y: np.ndarray, batch_size: int, training: bool):
    ds = tf.data.Dataset.from_tensor_slices((x.astype(np.float32), y.astype(np.int64)))
    if training:
        ds = ds.shuffle(buffer_size=len(x), reshuffle_each_iteration=True)
    return ds.batch(batch_size).prefetch(tf.data.AUTOTUNE)


def evaluate_per_image(model, x: np.ndarray, y: np.ndarray) -> dict[str, float | int]:
    scores = model.predict(x.astype(np.float32), verbose=0)
    preds = np.argmax(scores, axis=1)
    correct = int((preds == y).sum())
    return {
        "num_samples": int(len(y)),
        "correct": correct,
        "accuracy": correct / len(y) if len(y) else None,
    }


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()
    configure_runtime(tf, args.require_gpu)
    tf.keras.utils.set_random_seed(args.seed)

    dataset_path = Path(args.dataset_npz).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    data = np.load(dataset_path, allow_pickle=True)
    class_names = [str(item) for item in data["class_names"].tolist()]
    x_train = data["x_train"]
    y_train = data["y_train"]
    x_val = data["x_val"]
    y_val = data["y_val"]
    x_test = data["x_test"] if "x_test" in data else None
    y_test = data["y_test"] if "y_test" in data else None
    detected_train = data["detected_train"] if "detected_train" in data else None
    detected_val = data["detected_val"] if "detected_val" in data else None
    detected_test = data["detected_test"] if "detected_test" in data else None

    x_train = build_feature_matrix(x_train, detected_train, args.feature_mode)
    x_val = build_feature_matrix(x_val, detected_val, args.feature_mode)
    if x_test is not None:
        x_test = build_feature_matrix(x_test, detected_test, args.feature_mode)

    train_ds = make_dataset(tf, x_train, y_train, args.batch_size, training=True)
    val_ds = make_dataset(tf, x_val, y_val, args.batch_size, training=False)
    test_ds = make_dataset(tf, x_test, y_test, args.batch_size, training=False) if x_test is not None else None

    hidden_dims = parse_hidden_dims(args.hidden_dims)
    model = build_model(tf, input_dim=int(x_train.shape[1]), num_classes=len(class_names), hidden_dims=hidden_dims, dropout=args.dropout)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=args.learning_rate),
        loss=tf.keras.losses.SparseCategoricalCrossentropy(),
        metrics=["accuracy"],
    )

    callbacks = [
        tf.keras.callbacks.ModelCheckpoint(out_dir / "model.keras", monitor="val_accuracy", save_best_only=True),
        tf.keras.callbacks.CSVLogger(out_dir / "history.csv"),
        tf.keras.callbacks.EarlyStopping(monitor="val_accuracy", patience=10, restore_best_weights=True),
        tf.keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=3, min_lr=1e-5),
    ]
    history = model.fit(train_ds, validation_data=val_ds, epochs=args.epochs, callbacks=callbacks)
    model.save(out_dir / "model.keras")
    (out_dir / "labels.txt").write_text("\n".join(class_names) + "\n", encoding="utf-8")

    test_metrics = None
    test_inference = None
    if test_ds is not None:
        values = model.evaluate(test_ds, verbose=1)
        test_metrics = dict(zip(model.metrics_names, [float(v) for v in values]))
        test_inference = evaluate_per_image(model, x_test, y_test)

    summary = {
        "dataset_npz": str(dataset_path),
        "batch_size": args.batch_size,
        "epochs_requested": args.epochs,
        "epochs_ran": len(history.history.get("loss", [])),
        "best_epoch": int(np.argmax(history.history["val_accuracy"]) + 1),
        "best_val_accuracy": float(np.max(history.history["val_accuracy"])),
        "learning_rate": args.learning_rate,
        "dropout": args.dropout,
        "hidden_dims": hidden_dims,
        "feature_mode": args.feature_mode,
        "feature_dim": int(x_train.shape[1]),
        "classes": class_names,
        "params": int(model.count_params()),
        "final_train_accuracy": float(history.history["accuracy"][-1]),
        "final_val_accuracy": float(history.history["val_accuracy"][-1]),
        "test_metrics": test_metrics,
        "test_inference": test_inference,
    }
    (out_dir / "training_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Wrote {out_dir / 'training_summary.json'}")


if __name__ == "__main__":
    main()
