"""Build a hand-cropped image dataset with MediaPipe Hands."""

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
    parser.add_argument("--data_dir", required=True, help="Input dataset root with train/val/test folders.")
    parser.add_argument("--out_dir", required=True, help="Output cropped dataset root.")
    parser.add_argument("--report_out", required=True, help="Output JSON report path.")
    parser.add_argument(
        "--crop_scale",
        type=float,
        default=1.9,
        help="Square crop scale relative to the detected hand box.",
    )
    parser.add_argument(
        "--min_detection_confidence",
        type=float,
        default=0.45,
        help="MediaPipe Hands detection confidence threshold.",
    )
    parser.add_argument(
        "--min_tracking_confidence",
        type=float,
        default=0.45,
        help="MediaPipe Hands tracking confidence threshold.",
    )
    parser.add_argument(
        "--fallback_mode",
        choices=["copy", "center_crop"],
        default="center_crop",
        help="Fallback used when MediaPipe fails to detect a hand.",
    )
    parser.add_argument(
        "--max_per_class",
        type=int,
        default=0,
        help="Optional cap per class per split. Use 0 to process all images.",
    )
    return parser.parse_args()


def require_mediapipe():
    try:
        import mediapipe as mp  # pylint: disable=import-outside-toplevel
    except ImportError as exc:
        raise SystemExit(
            "MediaPipe is not installed. Use gesture_project/algorithms/.venv/bin/python "
            "after installing mediapipe."
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


def maybe_limit_per_class(samples: list[tuple[Path, int]], max_per_class: int) -> list[tuple[Path, int]]:
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


def compute_square_crop(
    image_width: int,
    image_height: int,
    points_xy: np.ndarray,
    crop_scale: float,
) -> tuple[int, int, int, int]:
    x_min = float(points_xy[:, 0].min())
    x_max = float(points_xy[:, 0].max())
    y_min = float(points_xy[:, 1].min())
    y_max = float(points_xy[:, 1].max())

    center_x = 0.5 * (x_min + x_max)
    center_y = 0.5 * (y_min + y_max)
    box_w = max(x_max - x_min, 2.0)
    box_h = max(y_max - y_min, 2.0)
    size = max(box_w, box_h) * crop_scale

    x0 = int(round(center_x - 0.5 * size))
    y0 = int(round(center_y - 0.5 * size))
    x1 = int(round(center_x + 0.5 * size))
    y1 = int(round(center_y + 0.5 * size))

    if x0 < 0:
        x1 -= x0
        x0 = 0
    if y0 < 0:
        y1 -= y0
        y0 = 0
    if x1 > image_width:
        shift = x1 - image_width
        x0 = max(0, x0 - shift)
        x1 = image_width
    if y1 > image_height:
        shift = y1 - image_height
        y0 = max(0, y0 - shift)
        y1 = image_height

    width = x1 - x0
    height = y1 - y0
    size = min(width, height)
    x1 = x0 + size
    y1 = y0 + size
    return x0, y0, x1, y1


def center_square_crop(image: Image.Image) -> Image.Image:
    width, height = image.size
    size = min(width, height)
    x0 = (width - size) // 2
    y0 = (height - size) // 2
    return image.crop((x0, y0, x0 + size, y0 + size))


def extract_hand_crop(
    hands,
    image_path: Path,
    crop_scale: float,
    fallback_mode: str,
) -> tuple[Image.Image, bool, dict[str, float | int]]:
    image = Image.open(image_path).convert("RGB")
    image_np = np.asarray(image, dtype=np.uint8)
    result = hands.process(image_np)
    meta: dict[str, float | int] = {
        "width": image.width,
        "height": image.height,
    }
    if not result.multi_hand_landmarks:
        if fallback_mode == "copy":
            return image, False, meta
        return center_square_crop(image), False, meta

    landmarks = result.multi_hand_landmarks[0]
    points = np.asarray(
        [[lm.x * image.width, lm.y * image.height] for lm in landmarks.landmark],
        dtype=np.float32,
    )
    x0, y0, x1, y1 = compute_square_crop(image.width, image.height, points, crop_scale)
    meta.update(
        {
            "crop_x0": x0,
            "crop_y0": y0,
            "crop_x1": x1,
            "crop_y1": y1,
            "crop_size": x1 - x0,
        }
    )
    return image.crop((x0, y0, x1, y1)), True, meta


def main() -> None:
    args = parse_args()
    mp = require_mediapipe()

    data_dir = Path(args.data_dir).resolve()
    out_dir = Path(args.out_dir).resolve()
    report_out = Path(args.report_out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    report_out.parent.mkdir(parents=True, exist_ok=True)

    report: dict[str, object] = {
        "data_dir": str(data_dir),
        "out_dir": str(out_dir),
        "crop_scale": args.crop_scale,
        "fallback_mode": args.fallback_mode,
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
        class_names: list[str] | None = None
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

            split_total = 0
            split_detected = 0
            split_by_class_total: dict[str, int] = defaultdict(int)
            split_by_class_detected: dict[str, int] = defaultdict(int)
            crop_sizes: list[int] = []

            for image_path, label_index in split_samples:
                label_name = split_class_names[label_index]
                split_total += 1
                split_by_class_total[label_name] += 1

                cropped, detected, meta = extract_hand_crop(
                    hands=hands,
                    image_path=image_path,
                    crop_scale=args.crop_scale,
                    fallback_mode=args.fallback_mode,
                )
                if detected:
                    split_detected += 1
                    split_by_class_detected[label_name] += 1
                    crop_size = int(meta.get("crop_size", 0))
                    if crop_size > 0:
                        crop_sizes.append(crop_size)

                dest_dir = out_dir / split / label_name
                dest_dir.mkdir(parents=True, exist_ok=True)
                out_path = dest_dir / image_path.name
                cropped.save(out_path, quality=95)

            per_class = {}
            for label_name in split_class_names:
                total = int(split_by_class_total[label_name])
                detected = int(split_by_class_detected[label_name])
                per_class[label_name] = {
                    "total": total,
                    "detected": detected,
                    "detection_rate": detected / total if total else None,
                }

            report["splits"][split] = {
                "num_samples": split_total,
                "num_detected": split_detected,
                "detection_rate": split_detected / split_total if split_total else None,
                "mean_detected_crop_size_px": float(np.mean(crop_sizes)) if crop_sizes else None,
                "median_detected_crop_size_px": float(np.median(crop_sizes)) if crop_sizes else None,
                "per_class": per_class,
            }

    report_out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote cropped dataset to {out_dir}")
    print(f"Wrote report to {report_out}")


if __name__ == "__main__":
    main()
