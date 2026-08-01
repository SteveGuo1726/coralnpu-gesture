"""Evaluate late fusion between the static CNN and a landmark classifier."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}
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
    parser.add_argument("--image_model", required=True, help="Keras static CNN model path.")
    parser.add_argument("--image_labels", required=True, help="labels.txt written by the static CNN run.")
    parser.add_argument("--landmark_model", required=True, help="Keras landmark model path.")
    parser.add_argument("--landmark_npz", required=True, help="Landmark dataset npz.")
    parser.add_argument("--data_dir", required=True, help="Dataset root that contains val/test splits.")
    parser.add_argument(
        "--landmark_feature_mode",
        choices=["coords", "coords_detect", "coords_bones_detect", "coords_bones_geom_detect"],
        default="coords",
        help="Feature mode used when the landmark model was trained.",
    )
    parser.add_argument(
        "--image_weight",
        type=float,
        default=-1.0,
        help="Optional fixed image-model weight in [0,1]. Use negative to sweep on validation.",
    )
    parser.add_argument("--out", required=True, help="Output JSON report.")
    return parser.parse_args()


def require_tensorflow():
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow is not installed. Use gesture_project/algorithms/.venv/bin/python."
        ) from exc
    return tf


def read_labels(path: Path) -> list[str]:
    labels = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    labels = [label for label in labels if label]
    if not labels:
        raise SystemExit(f"No labels found in {path}")
    return labels


def list_split_samples(data_dir: Path, split: str, labels: list[str]) -> list[tuple[Path, int]]:
    samples: list[tuple[Path, int]] = []
    for label_index, label in enumerate(labels):
        class_dir = data_dir / split / label
        if not class_dir.is_dir():
            raise SystemExit(f"Missing class directory: {class_dir}")
        for path in sorted(class_dir.rglob("*")):
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                samples.append((path, label_index))
    if not samples:
        raise SystemExit(f"No images found under {data_dir / split}")
    return samples


def load_image_batch(samples: list[tuple[Path, int]], height: int, width: int) -> tuple[np.ndarray, np.ndarray]:
    images = np.stack(
        [
            np.asarray(Image.open(path).convert("RGB").resize((width, height), Image.BILINEAR), dtype=np.float32)
            for path, _label in samples
        ],
        axis=0,
    )
    labels = np.asarray([label for _path, label in samples], dtype=np.int64)
    return images, labels


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
        features.append(np.linalg.norm(bone_vectors(coords), axis=2).astype(np.float32))
        features.append(fingertip_geometry(coords))
    if include_detect:
        if detected is None:
            raise SystemExit(f"Feature mode {feature_mode} requires detected_* arrays in landmark npz.")
        features.append(detected.astype(np.float32).reshape((-1, 1)))

    return np.concatenate(features, axis=1).astype(np.float32)


def accuracy(scores: np.ndarray, labels: np.ndarray) -> float:
    return float((scores.argmax(axis=1) == labels).mean())


def main() -> None:
    args = parse_args()
    tf = require_tensorflow()

    image_model_path = Path(args.image_model).resolve()
    image_labels_path = Path(args.image_labels).resolve()
    landmark_model_path = Path(args.landmark_model).resolve()
    landmark_npz_path = Path(args.landmark_npz).resolve()
    data_dir = Path(args.data_dir).resolve()
    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    labels = read_labels(image_labels_path)
    image_model = tf.keras.models.load_model(image_model_path)
    landmark_model = tf.keras.models.load_model(landmark_model_path)
    input_shape = image_model.input_shape
    height, width = int(input_shape[1]), int(input_shape[2])

    val_samples = list_split_samples(data_dir, "val", labels)
    test_samples = list_split_samples(data_dir, "test", labels)
    val_images, val_labels = load_image_batch(val_samples, height, width)
    test_images, test_labels = load_image_batch(test_samples, height, width)

    image_val_scores = image_model.predict(val_images, batch_size=64, verbose=0)
    image_test_scores = image_model.predict(test_images, batch_size=64, verbose=0)

    landmark_data = np.load(landmark_npz_path, allow_pickle=True)
    landmark_val_scores = landmark_model.predict(
        build_feature_matrix(
            landmark_data["x_val"],
            landmark_data["detected_val"] if "detected_val" in landmark_data else None,
            args.landmark_feature_mode,
        ),
        batch_size=256,
        verbose=0,
    )
    landmark_test_scores = landmark_model.predict(
        build_feature_matrix(
            landmark_data["x_test"],
            landmark_data["detected_test"] if "detected_test" in landmark_data else None,
            args.landmark_feature_mode,
        ),
        batch_size=256,
        verbose=0,
    )

    if 0.0 <= args.image_weight <= 1.0:
        best_image_weight = args.image_weight
        best_val_accuracy = accuracy(
            best_image_weight * image_val_scores + (1.0 - best_image_weight) * landmark_val_scores,
            val_labels,
        )
    else:
        best_image_weight = 0.0
        best_val_accuracy = -1.0
        for image_weight in [i / 100.0 for i in range(101)]:
            mixed_val_scores = image_weight * image_val_scores + (1.0 - image_weight) * landmark_val_scores
            mixed_val_accuracy = accuracy(mixed_val_scores, val_labels)
            if mixed_val_accuracy > best_val_accuracy:
                best_image_weight = image_weight
                best_val_accuracy = mixed_val_accuracy

    mixed_test_scores = (
        best_image_weight * image_test_scores + (1.0 - best_image_weight) * landmark_test_scores
    )
    report = {
        "image_model": str(image_model_path),
        "landmark_model": str(landmark_model_path),
        "landmark_feature_mode": args.landmark_feature_mode,
        "image_weight": best_image_weight,
        "landmark_weight": 1.0 - best_image_weight,
        "val_accuracy": best_val_accuracy,
        "test_accuracy": accuracy(mixed_test_scores, test_labels),
        "image_val_accuracy": accuracy(image_val_scores, val_labels),
        "image_test_accuracy": accuracy(image_test_scores, test_labels),
        "landmark_val_accuracy": accuracy(landmark_val_scores, val_labels),
        "landmark_test_accuracy": accuracy(landmark_test_scores, test_labels),
    }
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
