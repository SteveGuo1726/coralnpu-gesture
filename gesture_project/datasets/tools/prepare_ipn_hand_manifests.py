"""Build reproducible IPN Hand clip manifests from the upstream annotations.

PROJECT_LOCAL_MOD: IPN Hand data stay under the ignored ``datasets/raw`` tree.
This project-side script only converts the official text annotations into small
JSONL manifests, retaining the original subject-disjoint split and frame range.
It does not copy, relabel, or redistribute the dataset videos.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


UPSTREAM_ANNOTATION_URL = (
    "https://github.com/GibranBenitez/IPN-hand/tree/master/annotation_ipnGesture"
)
SPLIT_FILES = {
    "train": "trainlistall.txt",
    "val": "vallistall.txt",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--annotation_dir",
        type=Path,
        required=True,
        help="Directory containing official classIndAll.txt and *listall.txt files.",
    )
    parser.add_argument(
        "--out_dir",
        type=Path,
        required=True,
        help="Output directory for labels.txt, dataset_info.json, and split JSONL files.",
    )
    parser.add_argument(
        "--frames_root",
        type=Path,
        help=(
            "Optional root containing the extracted IPN frames. When supplied, every "
            "annotation path is checked before manifests are written."
        ),
    )
    parser.add_argument(
        "--test_annotation",
        type=Path,
        help=(
            "Optional project-held-out annotation file with the same four-column format. "
            "The upstream IPN-hand repository does not provide testlistall.txt."
        ),
    )
    return parser.parse_args()


def load_labels(path: Path) -> dict[int, str]:
    labels: dict[int, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 2:
            raise SystemExit(f"{path}:{line_number}: expected '<index> <label>'.")
        index, label = fields
        try:
            index_int = int(index)
        except ValueError as exc:
            raise SystemExit(f"{path}:{line_number}: invalid class index {index!r}.") from exc
        if index_int in labels:
            raise SystemExit(f"{path}:{line_number}: duplicate class index {index_int}.")
        labels[index_int] = label
    expected_indices = list(range(1, len(labels) + 1))
    if sorted(labels) != expected_indices:
        raise SystemExit(f"{path}: class indices must be contiguous from 1.")
    return labels


def parse_split(path: Path, labels: dict[int, str], frames_root: Path | None) -> list[dict]:
    samples = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 4:
            raise SystemExit(
                f"{path}:{line_number}: expected '<frame_dir> <class> <start> <end>'."
            )
        frame_dir, class_index, start_frame, end_frame = fields
        try:
            class_index_int = int(class_index)
            start_frame_int = int(start_frame)
            end_frame_int = int(end_frame)
        except ValueError as exc:
            raise SystemExit(f"{path}:{line_number}: non-integer class or frame index.") from exc
        if class_index_int not in labels:
            raise SystemExit(f"{path}:{line_number}: unknown class index {class_index_int}.")
        if start_frame_int < 1 or end_frame_int < start_frame_int:
            raise SystemExit(f"{path}:{line_number}: invalid inclusive frame range.")
        relative_dir = Path(frame_dir).as_posix().removeprefix("./")
        if frames_root is not None and not (frames_root / relative_dir).is_dir():
            raise SystemExit(
                f"{path}:{line_number}: missing extracted frame directory "
                f"{frames_root / relative_dir}"
            )
        samples.append(
            {
                "frame_dir": relative_dir,
                "label_index": class_index_int - 1,
                "label": labels[class_index_int],
                "start_frame": start_frame_int,
                "end_frame": end_frame_int,
                "num_frames": end_frame_int - start_frame_int + 1,
            }
        )
    if not samples:
        raise SystemExit(f"{path}: no annotated clips.")
    return samples


def main() -> None:
    args = parse_args()
    annotation_dir = args.annotation_dir.resolve()
    out_dir = args.out_dir.resolve()
    frames_root = args.frames_root.resolve() if args.frames_root else None
    labels = load_labels(annotation_dir / "classIndAll.txt")

    split_stats = {}
    parsed_splits: dict[str, list[dict]] = {}
    for split, filename in SPLIT_FILES.items():
        samples = parse_split(annotation_dir / filename, labels, frames_root)
        parsed_splits[split] = samples
        split_stats[split] = {
            "clips": len(samples),
            "frames": sum(sample["num_frames"] for sample in samples),
        }

    if args.test_annotation:
        test_annotation = args.test_annotation.resolve()
        samples = parse_split(test_annotation, labels, frames_root)
        parsed_splits["test"] = samples
        split_stats["test"] = {
            "clips": len(samples),
            "frames": sum(sample["num_frames"] for sample in samples),
            "source": str(test_annotation),
        }

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "labels.txt").write_text(
        "\n".join(labels[index] for index in sorted(labels)) + "\n", encoding="utf-8"
    )
    for split, samples in parsed_splits.items():
        output = out_dir / f"{split}.jsonl"
        output.write_text(
            "".join(json.dumps(sample, ensure_ascii=False) + "\n" for sample in samples),
            encoding="utf-8",
        )

    info = {
        "dataset": "IPN Hand",
        "annotation_source": UPSTREAM_ANNOTATION_URL,
        "annotation_format": "official classIndAll + *listall; inclusive start/end frames",
        "upstream_has_official_test_split": False,
        "labels": [labels[index] for index in sorted(labels)],
        "splits": split_stats,
        "frames_root_verified": str(frames_root) if frames_root else None,
    }
    (out_dir / "dataset_info.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(info, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
