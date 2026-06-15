"""Prepare a HaGRID-style static gesture subset into image-folder splits.

This script keeps all project-specific dataset handling under gesture_project/.
It supports two annotation layouts:

1. Official HaGRID layout:
   hagrid_annotations/{train,val,test}/<gesture>.json
2. Flat CSV with at least `image_id,label` columns.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import shutil
from collections import defaultdict
from pathlib import Path


IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
DEFAULT_CLASSES = ("palm", "fist", "ok", "thumb_up", "peace", "stop")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--images_dir",
        required=True,
        help="Raw HaGRID image root. Can contain nested directories.",
    )
    parser.add_argument(
        "--annotations",
        required=True,
        help="Annotation path. Supports official HaGRID annotation root or flat CSV.",
    )
    parser.add_argument(
        "--out_dir",
        required=True,
        help="Output image-folder dataset directory.",
    )
    parser.add_argument(
        "--classes",
        nargs="+",
        default=list(DEFAULT_CLASSES),
        help="Gesture labels to keep.",
    )
    parser.add_argument(
        "--max_per_class",
        type=int,
        default=2500,
        help="Upper bound of samples per class before split.",
    )
    parser.add_argument("--train_ratio", type=float, default=0.70)
    parser.add_argument("--val_ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=20260602)
    return parser.parse_args()


def normalize_image_id(value: str) -> str:
    value = value.strip()
    return Path(value).stem


def discover_images(images_dir: Path) -> dict[str, Path]:
    mapping: dict[str, Path] = {}
    for path in sorted(images_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        mapping[path.stem] = path
    return mapping


def load_csv_rows(annotations_path: Path) -> list[dict[str, str]]:
    with annotations_path.open("r", encoding="utf-8", newline="") as fp:
        reader = csv.DictReader(fp)
        required = {"image_id", "label"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(
                f"Missing required annotation columns {sorted(missing)} in {annotations_path}"
            )
        return list(reader)


def load_official_json_rows(annotations_dir: Path, classes: set[str]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    phases = ("train", "val", "test")
    for phase in phases:
        phase_dir = annotations_dir / phase
        if not phase_dir.is_dir():
            continue
        for label in sorted(classes):
            json_path = phase_dir / f"{label}.json"
            if not json_path.is_file():
                continue
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            for image_id in payload.keys():
                rows.append({"image_id": image_id, "label": label})
    return rows


def load_rows(annotations_path: Path, classes: set[str]) -> list[dict[str, str]]:
    if annotations_path.is_dir():
        return load_official_json_rows(annotations_path, classes)
    return load_csv_rows(annotations_path)


def split_counts(total: int, train_ratio: float, val_ratio: float) -> tuple[int, int]:
    train_count = int(total * train_ratio)
    val_count = int(total * val_ratio)
    if train_count + val_count >= total:
        val_count = max(0, total - train_count - 1)
    return train_count, val_count


def copy_files(split: str, label: str, files: list[Path], out_dir: Path) -> None:
    target_dir = out_dir / split / label
    target_dir.mkdir(parents=True, exist_ok=True)
    for src in files:
        shutil.copy2(src, target_dir / src.name)


def main() -> None:
    args = parse_args()
    base_dir = Path(__file__).resolve().parents[1]
    images_dir = Path(args.images_dir).resolve()
    annotations_path = Path(args.annotations).resolve()
    out_dir = (base_dir / args.out_dir).resolve()
    if not images_dir.is_dir():
        raise SystemExit(f"Missing images directory: {images_dir}")
    if not annotations_path.exists():
        raise SystemExit(f"Missing annotation path: {annotations_path}")
    if out_dir.exists():
        raise SystemExit(f"Output directory already exists, refusing to overwrite: {out_dir}")

    classes = {value.strip() for value in args.classes if value.strip()}
    if not classes:
        raise SystemExit("No classes requested.")

    image_map = discover_images(images_dir)
    rows = load_rows(annotations_path, classes)
    rng = random.Random(args.seed)

    grouped: dict[str, list[Path]] = defaultdict(list)
    missing_images: list[str] = []

    for row in rows:
        label = row["label"].strip()
        if label not in classes:
            continue
        image_id = normalize_image_id(row["image_id"])
        image_path = image_map.get(image_id)
        if image_path is None:
            missing_images.append(image_id)
            continue
        grouped[label].append(image_path)

    if not grouped:
        raise SystemExit("No matching samples found. Check classes, images_dir, and annotations.")

    summary: list[dict[str, int | str]] = []
    for label in sorted(grouped):
        files = list(dict.fromkeys(grouped[label]))
        rng.shuffle(files)
        if args.max_per_class > 0:
            files = files[: args.max_per_class]
        train_count, val_count = split_counts(len(files), args.train_ratio, args.val_ratio)
        train_files = files[:train_count]
        val_files = files[train_count : train_count + val_count]
        test_files = files[train_count + val_count :]
        copy_files("train", label, train_files, out_dir)
        copy_files("val", label, val_files, out_dir)
        copy_files("test", label, test_files, out_dir)
        summary.append(
            {
                "class": label,
                "total": len(files),
                "train": len(train_files),
                "val": len(val_files),
                "test": len(test_files),
            }
        )

    print(f"Wrote {out_dir}")
    for item in summary:
        print(
            "{class}: total={total} train={train} val={val} test={test}".format(
                **item
            )
        )
    print(f"Matched classes: {', '.join(sorted(grouped))}")
    if missing_images:
        print(f"Warning: {len(missing_images)} annotation rows had no matching image file.")


if __name__ == "__main__":
    main()
