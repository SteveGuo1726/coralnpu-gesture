#!/usr/bin/env python3
"""Prepare a reproducible subject-separated NUS Hand Posture II subset.

The official archive contains 40 subjects x 5 captures for each of 10 classes,
but does not ship a separate subject manifest.  This project-side tool records
the explicit reconstruction rule: numeric file order within each class is
grouped into consecutive blocks of five captures.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from collections import Counter
from pathlib import Path


CLASS_NAMES = tuple("abcdefghij")
MAIN_PATTERN = re.compile(r"^(?P<label>[a-j])(?: \((?P<index>\d+)\))?\.jpg$", re.IGNORECASE)
NOISE_PATTERN = re.compile(
    r"^(?P<label>[a-j])_HN(?: \((?P<index>\d+)\))?\.jpg$", re.IGNORECASE
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source_root", type=Path, required=True)
    parser.add_argument("--output_dir", type=Path, required=True)
    parser.add_argument("--train_subjects", type=int, default=28)
    parser.add_argument("--val_subjects", type=int, default=6)
    parser.add_argument("--test_subjects", type=int, default=6)
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace only the generated output directory after confirmation by the caller.",
    )
    return parser.parse_args()


def indexed_files(directory: Path, pattern: re.Pattern[str]) -> dict[str, list[tuple[int, Path]]]:
    grouped: dict[str, list[tuple[int, Path]]] = {label: [] for label in CLASS_NAMES}
    for path in directory.iterdir():
        if not path.is_file():
            continue
        match = pattern.match(path.name)
        if not match:
            continue
        label = match.group("label").lower()
        index = int(match.group("index") or 0)
        grouped[label].append((index, path))
    for label in CLASS_NAMES:
        grouped[label].sort(key=lambda item: item[0])
    return grouped


def make_output_dir(path: Path, overwrite: bool) -> None:
    if path.exists():
        if not overwrite:
            raise SystemExit(f"Output exists; pass --overwrite to replace it: {path}")
        for child in path.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    path.mkdir(parents=True, exist_ok=True)


def copy_split(
    grouped: dict[str, list[tuple[int, Path]]],
    output_dir: Path,
    split_name: str,
    subject_range: range,
    manifest: list[dict[str, object]],
) -> None:
    for label in CLASS_NAMES:
        destination = output_dir / split_name / label
        destination.mkdir(parents=True, exist_ok=True)
        for index, source in grouped[label]:
            subject = index // 5
            if subject not in subject_range:
                continue
            target = destination / f"{label}_{index:03d}.jpg"
            shutil.copy2(source, target)
            manifest.append(
                {
                    "split": split_name,
                    "label": label,
                    "source": str(source),
                    "source_index": index,
                    "inferred_subject": subject,
                    "target": str(target),
                }
            )


def copy_noise(
    grouped: dict[str, list[tuple[int, Path]]],
    output_dir: Path,
    manifest: list[dict[str, object]],
) -> None:
    for label in CLASS_NAMES:
        destination = output_dir / "noise_test" / label
        destination.mkdir(parents=True, exist_ok=True)
        for index, source in grouped[label]:
            target = destination / f"{label}_hn_{index:03d}.jpg"
            shutil.copy2(source, target)
            manifest.append(
                {
                    "split": "noise_test",
                    "label": label,
                    "source": str(source),
                    "source_index": index,
                    "target": str(target),
                }
            )


def main() -> None:
    args = parse_args()
    if args.train_subjects <= 0 or args.val_subjects <= 0 or args.test_subjects <= 0:
        raise SystemExit("All subject split sizes must be positive.")
    if args.train_subjects + args.val_subjects + args.test_subjects != 40:
        raise SystemExit("The NUS-II reconstruction must partition exactly 40 subjects.")

    source_root = args.source_root
    main_dir = source_root / "Hand Postures"
    noise_dir = source_root / "Hand Postures with human noise"
    if not main_dir.is_dir() or not noise_dir.is_dir():
        raise SystemExit(f"Expected official NUS-II directories below {source_root}")

    grouped = indexed_files(main_dir, MAIN_PATTERN)
    noise_grouped = indexed_files(noise_dir, NOISE_PATTERN)
    for label in CLASS_NAMES:
        if len(grouped[label]) != 200:
            raise SystemExit(f"Expected 200 main images for {label}, found {len(grouped[label])}")
        if len(noise_grouped[label]) != 75:
            raise SystemExit(f"Expected 75 noise images for {label}, found {len(noise_grouped[label])}")

    make_output_dir(args.output_dir, args.overwrite)
    manifest: list[dict[str, object]] = []
    train_end = args.train_subjects
    val_end = train_end + args.val_subjects
    copy_split(grouped, args.output_dir, "train", range(0, train_end), manifest)
    copy_split(grouped, args.output_dir, "val", range(train_end, val_end), manifest)
    copy_split(grouped, args.output_dir, "test", range(val_end, 40), manifest)
    copy_noise(noise_grouped, args.output_dir, manifest)

    counts = Counter((item["split"], item["label"]) for item in manifest)
    metadata = {
        "dataset": "NUS Hand Posture Dataset II",
        "source": "https://www.ece.nus.edu.sg/stfpage/elepv/NUS-HandSet/",
        "source_archive": "NUS-Hand-Posture-Dataset-II.zip",
        "classes": list(CLASS_NAMES),
        "official_main_images": 2000,
        "official_human_noise_images": 750,
        "official_subjects": 40,
        "official_captures_per_class_and_subject": 5,
        "project_split_rule": "Within each class, sorted numeric filenames are grouped into consecutive blocks of five.",
        "train_subjects": list(range(0, train_end)),
        "val_subjects": list(range(train_end, val_end)),
        "test_subjects": list(range(val_end, 40)),
        "counts": {f"{split}/{label}": count for (split, label), count in sorted(counts.items())},
        "warning": "The archive has no separate subject manifest; inferred_subject is a project-side reconstruction and must not be called an official split.",
    }
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output_dir / "dataset_metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
