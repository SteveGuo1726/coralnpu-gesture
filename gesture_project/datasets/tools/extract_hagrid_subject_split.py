"""Extract a subject-disjoint static HaGRID v1 dataset from an archive.

PROJECT_LOCAL_MOD: HaGRID is an external dataset. This script only prepares a
local experiment copy and does not modify the upstream archive or annotations.
The older ``extract_hagrid_sample_subset.py`` makes a random image split; this
entry point uses the archive's ``user_id`` metadata so one person cannot occur
in more than one split. It automatically detects the 120k or 500k archive
layout and, unless a class list is supplied, keeps every annotated class.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import zipfile
from collections import defaultdict
from io import BytesIO
from pathlib import Path, PurePosixPath

from PIL import Image


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip_path", type=Path, required=True)
    parser.add_argument("--out_dir", type=Path, required=True)
    parser.add_argument(
        "--classes",
        nargs="+",
        default=[],
        help="Optional class subset. Omit to use every class in the archive.",
    )
    parser.add_argument(
        "--max_per_class",
        type=int,
        default=0,
        help="Per-class cap after subject split. Zero keeps the complete archive.",
    )
    parser.add_argument("--train_ratio", type=float, default=0.70)
    parser.add_argument("--val_ratio", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=20260814)
    parser.add_argument(
        "--image_mode",
        choices=["full_frame", "target_hand_crop"],
        default="full_frame",
        help=(
            "full_frame copies archive images unchanged. target_hand_crop extracts only "
            "the bounding box whose annotation label equals the target class."
        ),
    )
    parser.add_argument(
        "--crop_context",
        type=float,
        default=0.25,
        help=(
            "Relative margin added to every target-hand bounding-box side. Used only "
            "when --image_mode=target_hand_crop."
        ),
    )
    parser.add_argument(
        "--missing_target_policy",
        choices=["error", "exclude"],
        default="error",
        help=(
            "How target_hand_crop handles an archive-directory image with no box "
            "whose label matches that directory. exclude records it in metadata; "
            "error stops preparation."
        ),
    )
    parser.add_argument(
        "--progress_every",
        type=int,
        default=0,
        help="Write progress every N output images. Zero disables progress output.",
    )
    return parser.parse_args()


def split_users(users: set[str], train_ratio: float, val_ratio: float, seed: int) -> dict[str, str]:
    if not 0 < train_ratio < 1 or not 0 <= val_ratio < 1 or train_ratio + val_ratio >= 1:
        raise ValueError("train_ratio and val_ratio must leave a non-empty test split")
    ordered = sorted(users)
    random.Random(seed).shuffle(ordered)
    train_end = int(len(ordered) * train_ratio)
    val_end = train_end + int(len(ordered) * val_ratio)
    if train_end <= 0 or val_end <= train_end or val_end >= len(ordered):
        raise ValueError("too few users for the requested split")
    return {
        user: ("train" if index < train_end else "val" if index < val_end else "test")
        for index, user in enumerate(ordered)
    }


def stable_image_order(image_ids: list[str], seed: int) -> list[str]:
    return sorted(
        image_ids,
        key=lambda image_id: hashlib.sha256(f"{seed}:{image_id}".encode()).digest(),
    )


def archive_layout(names: set[str]) -> tuple[str, list[str], dict[tuple[str, str], str]]:
    """Discover archive root, labels, and image member paths once per archive."""

    annotation_paths = [
        name for name in names if "/ann_train_val/" in name and name.endswith(".json")
    ]
    roots = {name.split("/ann_train_val/", 1)[0] for name in annotation_paths}
    if len(roots) != 1:
        raise SystemExit(f"Cannot determine one archive root from annotations: {sorted(roots)}")
    root = next(iter(roots))
    labels = sorted(PurePosixPath(name).stem for name in annotation_paths)

    members: dict[tuple[str, str], str] = {}
    for name in names:
        if not name.lower().endswith(".jpg"):
            continue
        parts = PurePosixPath(name).parts
        source_dir = next((part for part in parts if part.startswith("train_val_")), None)
        if source_dir is None:
            continue
        label = source_dir.removeprefix("train_val_")
        members[(label, PurePosixPath(name).stem)] = name
    return root, labels, members


def target_box(annotation: dict, label: str) -> tuple[float, float, float, float] | None:
    """Return the union of target-class boxes, excluding no-gesture hands.

    HaGRID boxes are normalized ``x, y, width, height`` values. A frame can
    contain a second hand marked ``no_gesture``; using only the matching target
    label prevents that unrelated hand from becoming part of the classifier crop.
    """

    boxes = annotation.get("bboxes", [])
    labels = annotation.get("labels", [])
    if len(boxes) != len(labels):
        raise SystemExit(f"Mismatched HaGRID labels and boxes for target {label}.")
    matches = [box for box, box_label in zip(boxes, labels) if box_label == label]
    if not matches:
        return None
    normalized = [tuple(float(value) for value in box) for box in matches]
    if any(width <= 0 or height <= 0 for _x, _y, width, height in normalized):
        raise SystemExit(f"Invalid non-positive target box for {label}: {matches}")
    left = min(x for x, _y, _width, _height in normalized)
    top = min(y for _x, y, _width, _height in normalized)
    right = max(x + width for x, _y, width, _height in normalized)
    bottom = max(y + height for _x, y, _width, height in normalized)
    return left, top, right - left, bottom - top


def crop_target_hand(image_bytes: bytes, box: tuple[float, float, float, float], context: float) -> bytes:
    """Crop a normalized HaGRID box with context and return a deterministic JPEG."""

    if context < 0:
        raise SystemExit("--crop_context must be non-negative.")
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    image.load()
    image_width, image_height = image.size
    x, y, width, height = box
    left = max(0.0, x - width * context)
    top = max(0.0, y - height * context)
    right = min(1.0, x + width * (1.0 + context))
    bottom = min(1.0, y + height * (1.0 + context))
    pixel_box = (
        int(left * image_width),
        int(top * image_height),
        max(int(right * image_width), int(left * image_width) + 1),
        max(int(bottom * image_height), int(top * image_height) + 1),
    )
    cropped = image.crop(pixel_box)
    encoded = BytesIO()
    cropped.save(encoded, format="JPEG", quality=95, subsampling=0, optimize=False)
    return encoded.getvalue()


def main() -> None:
    args = parse_args()
    zip_path = args.zip_path.resolve()
    out_dir = args.out_dir.resolve()
    if not zip_path.is_file():
        raise SystemExit(f"Missing archive: {zip_path}")
    if out_dir.exists():
        raise SystemExit(f"Refusing to overwrite existing output: {out_dir}")
    if args.crop_context < 0:
        raise SystemExit("--crop_context must be non-negative.")
    if args.progress_every < 0:
        raise SystemExit("--progress_every must be non-negative.")
    print(
        f"prepare archive={zip_path} image_mode={args.image_mode} out_dir={out_dir}",
        flush=True,
    )
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
        archive_root, archive_classes, image_members = archive_layout(names)
        classes = tuple(
            dict.fromkeys(value.strip() for value in args.classes if value.strip())
        ) or tuple(archive_classes)
        unknown = sorted(set(classes) - set(archive_classes))
        if unknown:
            raise SystemExit(f"Classes absent from archive annotations: {unknown}")

        by_class: dict[str, list[tuple[str, str, str, tuple[float, float, float, float] | None]]] = defaultdict(list)
        all_users: set[str] = set()
        excluded_missing_target: dict[str, list[str]] = defaultdict(list)
        for label in classes:
            annotation_name = f"{archive_root}/ann_train_val/{label}.json"
            if annotation_name not in names:
                raise SystemExit(f"Missing class annotation: {annotation_name}")
            annotation = json.loads(archive.read(annotation_name))
            for image_id, image_info in annotation.items():
                user_id = image_info.get("user_id")
                if not user_id:
                    raise SystemExit(f"Missing user_id metadata for {label}/{image_id}")
                all_users.add(str(user_id))
                member = image_members.get((label, image_id))
                if member is None:
                    raise SystemExit(f"Missing image member for {label}/{image_id}")
                box = target_box(image_info, label) if args.image_mode == "target_hand_crop" else None
                if args.image_mode == "target_hand_crop" and box is None:
                    if args.missing_target_policy == "error":
                        raise SystemExit(f"No target-class box for {label}/{image_id}")
                    excluded_missing_target[label].append(image_id)
                    continue
                by_class[label].append((image_id, str(user_id), member, box))

        split_by_user = split_users(all_users, args.train_ratio, args.val_ratio, args.seed)
        selected: dict[str, dict[str, list[tuple[str, str]]]] = defaultdict(
            lambda: defaultdict(list)
        )
        for label in classes:
            candidates_by_split: dict[str, list[tuple[str, str, tuple[float, float, float, float] | None]]] = defaultdict(list)
            for image_id, user, member, box in by_class[label]:
                candidates_by_split[split_by_user[user]].append((image_id, member, box))
            for split, items in candidates_by_split.items():
                ordered_ids = stable_image_order(
                    [image_id for image_id, _member, _box in items], args.seed
                )
                member_by_id = {image_id: (member, box) for image_id, member, box in items}
                if args.max_per_class > 0:
                    ordered_ids = ordered_ids[: args.max_per_class]
                selected[split][label] = [
                    (image_id, *member_by_id[image_id]) for image_id in ordered_ids
                ]

        written_images = 0
        planned_images = sum(
            len(items) for class_map in selected.values() for items in class_map.values()
        )
        for split, class_map in selected.items():
            for label, items in class_map.items():
                target = out_dir / split / label
                target.mkdir(parents=True, exist_ok=True)
                for image_id, member, box in items:
                    with archive.open(member) as src:
                        image_bytes = src.read()
                    if args.image_mode == "target_hand_crop":
                        if box is None:
                            raise SystemExit(f"Missing target box for {label}/{image_id}")
                        image_bytes = crop_target_hand(image_bytes, box, args.crop_context)
                    (target / f"{image_id}.jpg").write_bytes(image_bytes)
                    written_images += 1
                    if args.progress_every and written_images % args.progress_every == 0:
                        print(
                            f"progress images={written_images}/{planned_images} split={split} class={label}",
                            flush=True,
                        )

    summary = {
        "dataset": "HaGRID v1 384p archive",
        "archive": str(zip_path),
        "archive_root": archive_root,
        "subject_disjoint": True,
        "classes": list(classes),
        "class_count": len(classes),
        "max_per_class": args.max_per_class,
        "image_mode": args.image_mode,
        "crop_context": args.crop_context if args.image_mode == "target_hand_crop" else None,
        "missing_target_policy": (
            args.missing_target_policy if args.image_mode == "target_hand_crop" else None
        ),
        "excluded_missing_target": {
            label: len(image_ids) for label, image_ids in sorted(excluded_missing_target.items())
        },
        "excluded_missing_target_total": sum(
            len(image_ids) for image_ids in excluded_missing_target.values()
        ),
        "seed": args.seed,
        "splits": {
            split: {
                "images": sum(len(items) for items in class_map.values()),
                "classes": {label: len(items) for label, items in sorted(class_map.items())},
                "users": len(
                    {
                        user
                        for label in classes
                        for _image_id, user, _member, _box in by_class[label]
                        if split_by_user[user] == split
                    }
                ),
            }
            for split, class_map in sorted(selected.items())
        },
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "dataset_info.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
