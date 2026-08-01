"""Extract MediaPipe hand landmarks from an image-folder gesture dataset."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image


IMAGE_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png"}
SPLITS = ("train", "val", "test")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data_dir", required=True, help="Dataset root with train/val/test folders.")
    parser.add_argument("--out", required=True, help="Output .npz file.")
    parser.add_argument("--report_out", required=True, help="Output JSON report.")
    parser.add_argument(
        "--max_per_class",
        type=int,
        default=0,
        help="Optional cap per class per split. Use 0 to process all images.",
    )
    parser.add_argument(
        "--min_detection_confidence",
        type=float,
        default=0.5,
        help="MediaPipe Hands detection confidence threshold.",
    )
    parser.add_argument(
        "--min_tracking_confidence",
        type=float,
        default=0.5,
        help="MediaPipe Hands tracking confidence threshold.",
    )
    return parser.parse_args()


def require_mediapipe():
    try:
        import mediapipe as mp  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "MediaPipe is not installed. Use gesture_project/algorithms/.venv_mp/bin/python."
        ) from exc
    return mp


def list_split_samples(split_dir: Path) -> tuple[list[str], list[tuple[Path, int]]]:
    if not split_dir.is_dir():
        return [], []
    class_dirs = sorted(path for path in split_dir.iterdir() if path.is_dir())
    class_names = [path.name for path in class_dirs]
    samples: list[tuple[Path, int]] = []
    for label_index, class_dir in enumerate(class_dirs):
        for path in sorted(class_dir.rglob("*")):
            if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS:
                samples.append((path, label_index))
    return class_names, samples


def maybe_limit_per_class(
    samples: list[tuple[Path, int]],
    max_per_class: int,
) -> list[tuple[Path, int]]:
    if max_per_class <= 0:
        return samples
    counters: dict[int, int] = defaultdict(int)
    limited: list[tuple[Path, int]] = []
    for path, label in samples:
        if counters[label] >= max_per_class:
            continue
        counters[label] += 1
        limited.append((path, label))
    return limited


def normalize_landmarks(points: np.ndarray) -> np.ndarray:
    wrist = points[0:1, :]
    centered = points - wrist
    xy = centered[:, :2]
    span = np.max(xy, axis=0) - np.min(xy, axis=0)
    scale = float(max(np.max(span), 1e-6))
    normalized = centered / scale
    return normalized.astype(np.float32)


def extract_feature_vector(mp, hands, image_path: Path) -> tuple[np.ndarray, int]:
    image = np.asarray(Image.open(image_path).convert("RGB"), dtype=np.uint8)
    result = hands.process(image)
    if not result.multi_hand_landmarks:
        return np.zeros((63,), dtype=np.float32), 0
    landmarks = result.multi_hand_landmarks[0]
    points = np.asarray(
        [[lm.x, lm.y, lm.z] for lm in landmarks.landmark],
        dtype=np.float32,
    )
    normalized = normalize_landmarks(points)
    return normalized.reshape(-1), 1


def main() -> None:
    args = parse_args()
    mp = require_mediapipe()

    data_dir = Path(args.data_dir).resolve()
    out_path = Path(args.out).resolve()
    report_path = Path(args.report_out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    per_split_arrays: dict[str, np.ndarray] = {}
    class_names: list[str] | None = None
    report: dict[str, object] = {
        "data_dir": str(data_dir),
        "max_per_class": args.max_per_class,
        "min_detection_confidence": args.min_detection_confidence,
        "min_tracking_confidence": args.min_tracking_confidence,
        "splits": {},
    }

    with mp.solutions.hands.Hands(
        static_image_mode=True,
        max_num_hands=1,
        min_detection_confidence=args.min_detection_confidence,
        min_tracking_confidence=args.min_tracking_confidence,
    ) as hands:
        for split in SPLITS:
            split_dir = data_dir / split
            split_class_names, split_samples = list_split_samples(split_dir)
            if not split_samples:
                continue
            if class_names is None:
                class_names = split_class_names
            elif class_names != split_class_names:
                raise SystemExit(f"Class mismatch in split {split}: {split_class_names} vs {class_names}")
            split_samples = maybe_limit_per_class(split_samples, args.max_per_class)

            x_rows: list[np.ndarray] = []
            y_rows: list[int] = []
            detected_rows: list[int] = []
            by_class_total: dict[str, int] = defaultdict(int)
            by_class_detected: dict[str, int] = defaultdict(int)

            for image_path, label_index in split_samples:
                feature_vector, detected = extract_feature_vector(mp, hands, image_path)
                label_name = split_class_names[label_index]
                by_class_total[label_name] += 1
                by_class_detected[label_name] += detected
                x_rows.append(feature_vector)
                y_rows.append(label_index)
                detected_rows.append(detected)

            x_array = np.stack(x_rows, axis=0).astype(np.float32)
            y_array = np.asarray(y_rows, dtype=np.int64)
            detected_array = np.asarray(detected_rows, dtype=np.int8)
            per_split_arrays[f"x_{split}"] = x_array
            per_split_arrays[f"y_{split}"] = y_array
            per_split_arrays[f"detected_{split}"] = detected_array

            split_report = {
                "num_samples": int(len(split_samples)),
                "num_detected": int(detected_array.sum()),
                "detection_rate": float(detected_array.mean()) if len(detected_array) else None,
                "per_class": {},
            }
            for label_name in split_class_names:
                total = int(by_class_total[label_name])
                detected = int(by_class_detected[label_name])
                split_report["per_class"][label_name] = {
                    "total": total,
                    "detected": detected,
                    "detection_rate": detected / total if total else None,
                }
            report["splits"][split] = split_report

    if class_names is None:
        raise SystemExit(f"No valid images found under {data_dir}")

    np.savez_compressed(
        out_path,
        class_names=np.asarray(class_names, dtype=object),
        **per_split_arrays,
    )
    report["class_names"] = class_names
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")
    print(f"Wrote {report_path}")


if __name__ == "__main__":
    main()
