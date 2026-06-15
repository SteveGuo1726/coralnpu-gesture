"""Extract a class subset from the HF HaGRID sample zip into image-folder splits."""

from __future__ import annotations

import argparse
import json
import random
import zipfile
from pathlib import Path


DEFAULT_CLASSES = ("palm", "fist", "ok", "peace", "stop", "like")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip_path", required=True, help="Path to hagrid-sample-120k-384p.zip.")
    parser.add_argument(
        "--out_dir",
        required=True,
        help="Output image-folder dataset directory, relative to gesture_project/datasets or absolute.",
    )
    parser.add_argument(
        "--classes",
        nargs="+",
        default=list(DEFAULT_CLASSES),
        help="Gesture classes to keep. Use 'like' as thumb_up proxy when needed.",
    )
    parser.add_argument("--max_per_class", type=int, default=2500)
    parser.add_argument("--train_ratio", type=float, default=0.70)
    parser.add_argument("--val_ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=20260602)
    return parser.parse_args()


def split_counts(total: int, train_ratio: float, val_ratio: float) -> tuple[int, int]:
    train_count = int(total * train_ratio)
    val_count = int(total * val_ratio)
    if train_count + val_count >= total:
        val_count = max(0, total - train_count - 1)
    return train_count, val_count


def resolve_out_dir(out_arg: str) -> Path:
    out_path = Path(out_arg)
    if out_path.is_absolute():
        return out_path
    base_dir = Path(__file__).resolve().parents[1]
    return (base_dir / out_path).resolve()


def main() -> None:
    args = parse_args()
    zip_path = Path(args.zip_path).resolve()
    out_dir = resolve_out_dir(args.out_dir)
    if not zip_path.is_file():
        raise SystemExit(f"Missing zip file: {zip_path}")
    if out_dir.exists():
        raise SystemExit(f"Output directory already exists, refusing to overwrite: {out_dir}")

    rng = random.Random(args.seed)
    classes = [value.strip() for value in args.classes if value.strip()]
    if not classes:
        raise SystemExit("No classes requested.")

    with zipfile.ZipFile(zip_path) as zf:
        root = "hagrid-sample-120k-384p"
        names = set(zf.namelist())
        summary = []
        for cls in classes:
            ann_name = f"{root}/ann_train_val/{cls}.json"
            if ann_name not in zf.namelist():
                raise SystemExit(f"Missing annotation entry for class {cls}: {ann_name}")
            ann = json.loads(zf.read(ann_name))
            zip_dir = f"{root}/hagrid_120k/train_val_{cls}"
            image_ids = [
                image_id
                for image_id in ann.keys()
                if f"{zip_dir}/{image_id}.jpg" in names
            ]
            rng.shuffle(image_ids)
            if args.max_per_class > 0:
                image_ids = image_ids[: args.max_per_class]

            train_count, val_count = split_counts(len(image_ids), args.train_ratio, args.val_ratio)
            split_map = {
                "train": image_ids[:train_count],
                "val": image_ids[train_count : train_count + val_count],
                "test": image_ids[train_count + val_count :],
            }

            for split, ids in split_map.items():
                target_dir = out_dir / split / cls
                target_dir.mkdir(parents=True, exist_ok=True)
                for image_id in ids:
                    zip_member = f"{zip_dir}/{image_id}.jpg"
                    with zf.open(zip_member) as src, (target_dir / f"{image_id}.jpg").open("wb") as dst:
                        dst.write(src.read())

            summary.append(
                {
                    "class": cls,
                    "total": len(image_ids),
                    "train": len(split_map["train"]),
                    "val": len(split_map["val"]),
                    "test": len(split_map["test"]),
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
