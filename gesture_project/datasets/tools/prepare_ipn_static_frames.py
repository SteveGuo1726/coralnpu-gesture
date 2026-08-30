"""Build a static interaction subset from official IPN Hand segments.

PROJECT_LOCAL_MOD: IPN Hand is a video benchmark. This script deliberately
keeps only labels whose intent is visible in a single frame and samples the
middle frame of each annotated segment. It preserves the official train/val
lists and creates a video-disjoint test holdout from the official training
videos. It never mixes frames from one video across splits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image


STATIC_LABELS = {
    1: "D0X",
    2: "B0A",
    3: "B0B",
    4: "G01",
    5: "G02",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames_root", type=Path, required=True)
    parser.add_argument("--annotation_dir", type=Path, required=True)
    parser.add_argument("--out_dir", type=Path, required=True)
    parser.add_argument(
        "--labels",
        nargs="+",
        choices=sorted(set(STATIC_LABELS.values())),
        default=list(STATIC_LABELS.values()),
        help="Labels whose intent is visible in one frame.",
    )
    parser.add_argument("--test_video_fraction", type=float, default=0.15)
    parser.add_argument("--jpeg_quality", type=int, default=95)
    return parser.parse_args()


def read_segments(path: Path, selected_indices: set[int]) -> list[tuple[str, int, int, int]]:
    segments = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 4:
            raise ValueError(f"{path}:{line_number}: expected 4 fields")
        frame_dir, label_index, start, end = fields
        label_index = int(label_index)
        if label_index not in selected_indices:
            continue
        segments.append((frame_dir.removeprefix("./frames/"), label_index, int(start), int(end)))
    return segments


def belongs_to_test(video_dir: str, fraction: float) -> bool:
    digest = hashlib.sha256(video_dir.encode("utf-8")).digest()
    value = int.from_bytes(digest[:8], "big") / float(1 << 64)
    return value < fraction


def frame_path(frames_root: Path, video_dir: str, frame_number: int) -> Path:
    folder = frames_root / video_dir
    candidates = sorted(folder.glob(f"*_{frame_number:06d}.jpg"))
    if len(candidates) != 1:
        raise FileNotFoundError(
            f"expected one frame for {video_dir} #{frame_number}, found {len(candidates)}"
        )
    return candidates[0]


def copy_segment(
    frames_root: Path,
    out_dir: Path,
    split: str,
    video_dir: str,
    label: str,
    start: int,
    end: int,
    quality: int,
) -> None:
    middle = start + (end - start) // 2
    source = frame_path(frames_root, video_dir, middle)
    video_token = video_dir.replace("/", "_").replace("#", "num")
    destination = out_dir / split / label / f"{video_token}_{middle:06d}.jpg"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as image:
        image.convert("RGB").save(destination, format="JPEG", quality=quality, optimize=True)


def main() -> None:
    args = parse_args()
    frames_root = args.frames_root.resolve()
    annotation_dir = args.annotation_dir.resolve()
    out_dir = args.out_dir.resolve()
    if not frames_root.is_dir():
        raise SystemExit(f"Missing frames root: {frames_root}")
    if not annotation_dir.is_dir():
        raise SystemExit(f"Missing annotation directory: {annotation_dir}")
    if out_dir.exists():
        raise SystemExit(f"Refusing to overwrite existing output: {out_dir}")
    if not 0.0 < args.test_video_fraction < 1.0:
        raise SystemExit("--test_video_fraction must be between 0 and 1")

    selected_indices = {index for index, label in STATIC_LABELS.items() if label in args.labels}
    train_segments = read_segments(annotation_dir / "trainlistall.txt", selected_indices)
    val_segments = read_segments(annotation_dir / "vallistall.txt", selected_indices)
    selected = [("train", item) for item in train_segments] + [("val", item) for item in val_segments]

    # The holdout is selected by complete video directory, never by frame.
    test_videos = {
        video_dir
        for split, (video_dir, _label_index, _start, _end) in selected
        if split == "train" and belongs_to_test(video_dir, args.test_video_fraction)
    }
    counts = defaultdict(Counter)
    source_segments = 0
    for official_split, item in selected:
        video_dir, label_index, start, end = item
        split = "test" if official_split == "train" and video_dir in test_videos else official_split
        label = STATIC_LABELS[label_index]
        copy_segment(
            frames_root,
            out_dir,
            split,
            video_dir,
            label,
            start,
            end,
            args.jpeg_quality,
        )
        source_segments += 1
        counts[split][label] += 1

    summary = {
        "dataset": "IPN Hand static interaction subset",
        "source": "https://github.com/GibranBenitez/IPN-hand",
        "source_data_license": "CC BY 4.0",
        "source_code_license": "MIT",
        "project_local_mod": True,
        "selected_labels": {str(index): STATIC_LABELS[index] for index in sorted(selected_indices)},
        "excluded_temporal_only_labels": ["G03", "G04", "G05", "G06", "G07", "G08", "G09", "G10", "G11"],
        "sampling": "one middle frame per annotated segment",
        "official_train_val_preserved": True,
        "test_holdout": "stable hash of complete video directory from official training list",
        "test_video_fraction": args.test_video_fraction,
        "source_segments": source_segments,
        "test_videos": len(test_videos),
        "splits": {
            split: {"images": sum(values.values()), "classes": dict(sorted(values.items()))}
            for split, values in sorted(counts.items())
        },
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "dataset_info.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
