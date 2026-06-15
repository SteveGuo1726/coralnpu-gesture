"""Prepare Sign Language Digits Dataset into image-folder splits."""

from __future__ import annotations

import argparse
import random
import shutil
from pathlib import Path


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--raw_dir",
        default="raw/sign_language_digits_dataset/Dataset",
        help="Raw dataset directory containing class folders 0-9.",
    )
    parser.add_argument(
        "--out_dir",
        default="processed/sign_language_digits",
        help="Output image-folder dataset directory.",
    )
    parser.add_argument("--train_ratio", type=float, default=0.70)
    parser.add_argument("--val_ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=20260601)
    return parser.parse_args()


def class_files(class_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in class_dir.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
    )


def split_files(files: list[Path], train_ratio: float, val_ratio: float) -> dict[str, list[Path]]:
    train_count = int(len(files) * train_ratio)
    val_count = int(len(files) * val_ratio)
    return {
        "train": files[:train_count],
        "val": files[train_count : train_count + val_count],
        "test": files[train_count + val_count :],
    }


def copy_split(split: str, class_name: str, files: list[Path], out_dir: Path) -> None:
    target_dir = out_dir / split / class_name
    target_dir.mkdir(parents=True, exist_ok=True)
    for src in files:
        shutil.copy2(src, target_dir / src.name)


def main() -> None:
    args = parse_args()
    base_dir = Path(__file__).resolve().parents[1]
    raw_dir = (base_dir / args.raw_dir).resolve()
    out_dir = (base_dir / args.out_dir).resolve()
    if not raw_dir.is_dir():
        raise SystemExit(f"Missing raw dataset directory: {raw_dir}")
    if out_dir.exists():
        raise SystemExit(f"Output directory already exists, refusing to overwrite: {out_dir}")

    rng = random.Random(args.seed)
    summary = []
    for class_dir in sorted(path for path in raw_dir.iterdir() if path.is_dir()):
        files = class_files(class_dir)
        rng.shuffle(files)
        splits = split_files(files, args.train_ratio, args.val_ratio)
        for split, split_files_ in splits.items():
            copy_split(split, class_dir.name, split_files_, out_dir)
        summary.append(
            {
                "class": class_dir.name,
                "total": len(files),
                "train": len(splits["train"]),
                "val": len(splits["val"]),
                "test": len(splits["test"]),
            }
        )

    print(f"Wrote {out_dir}")
    for item in summary:
        print(
            "{class}: total={total} train={train} val={val} test={test}".format(
                **item
            )
        )


if __name__ == "__main__":
    main()
