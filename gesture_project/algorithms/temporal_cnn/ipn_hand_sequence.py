"""IPN Hand RGB window loading for the project temporal model.

PROJECT_LOCAL_MOD: This loader consumes project-generated JSONL manifests and
does not alter the upstream IPN files or redistribute dataset images.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image

try:
    import tensorflow as _tf

    _SequenceBase = _tf.keras.utils.Sequence
except ImportError:
    _SequenceBase = object


def read_manifest(path: Path) -> list[dict]:
    samples = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        sample = json.loads(line)
        required = {"frame_dir", "label_index", "start_frame", "end_frame"}
        missing = required.difference(sample)
        if missing:
            raise ValueError(f"{path}:{line_number}: missing fields {sorted(missing)}")
        if sample["start_frame"] < 1 or sample["end_frame"] < sample["start_frame"]:
            raise ValueError(f"{path}:{line_number}: invalid frame range")
        samples.append(sample)
    if not samples:
        raise ValueError(f"{path}: empty manifest")
    return samples


def sample_frame_indices(
    start_frame: int,
    end_frame: int,
    sequence_length: int,
    frame_stride: int,
    training: bool,
    rng: np.random.Generator,
) -> np.ndarray:
    """Choose a fixed window, padding at the clip boundary when necessary."""
    if sequence_length <= 0 or frame_stride <= 0:
        raise ValueError("sequence_length and frame_stride must be positive")
    span = (sequence_length - 1) * frame_stride + 1
    available = end_frame - start_frame + 1
    if available < span:
        first = start_frame
    else:
        max_first = end_frame - span + 1
        first = int(rng.integers(start_frame, max_first + 1)) if training else (start_frame + max_first) // 2
    indices = first + np.arange(sequence_length, dtype=np.int64) * frame_stride
    return np.clip(indices, start_frame, end_frame)


def _find_frame(frame_dir: Path, frame_index: int) -> Path:
    prefix = frame_dir.name
    candidates = (
        frame_dir / f"{prefix}_{frame_index:06d}.jpg",
        frame_dir / f"{prefix}_{frame_index:06d}.png",
        frame_dir / f"{frame_index:06d}.jpg",
        frame_dir / f"{frame_index:06d}.png",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(
        f"No frame {frame_index} found in {frame_dir}; tried "
        + ", ".join(path.name for path in candidates)
    )


def load_rgb_window(
    frames_root: Path,
    sample: dict,
    image_size: int,
    sequence_length: int,
    frame_stride: int,
    training: bool,
    rng: np.random.Generator,
) -> np.ndarray:
    indices = sample_frame_indices(
        int(sample["start_frame"]),
        int(sample["end_frame"]),
        sequence_length,
        frame_stride,
        training,
        rng,
    )
    frame_dir = frames_root / sample["frame_dir"]
    frames = []
    for frame_index in indices:
        with Image.open(_find_frame(frame_dir, int(frame_index))) as image:
            image = image.convert("RGB").resize((image_size, image_size), Image.Resampling.BILINEAR)
            frames.append(np.asarray(image, dtype=np.float32))
    return np.stack(frames, axis=0)


class IPNWindowSequence(_SequenceBase):
    """Small dependency-light batch sequence used by the TensorFlow trainer."""

    def __init__(
        self,
        samples: list[dict],
        frames_root: Path,
        batch_size: int,
        image_size: int = 96,
        sequence_length: int = 8,
        frame_stride: int = 2,
        training: bool = False,
        seed: int = 20260814,
    ) -> None:
        super().__init__()
        if batch_size <= 0:
            raise ValueError("batch_size must be positive")
        self.samples = samples
        self.frames_root = frames_root
        self.batch_size = batch_size
        self.image_size = image_size
        self.sequence_length = sequence_length
        self.frame_stride = frame_stride
        self.training = training
        self.rng = np.random.default_rng(seed)
        self.order = np.arange(len(samples), dtype=np.int64)

    def __len__(self) -> int:
        return (len(self.samples) + self.batch_size - 1) // self.batch_size

    def on_epoch_end(self) -> None:
        if self.training:
            self.rng.shuffle(self.order)

    def __getitem__(self, batch_index: int) -> tuple[np.ndarray, np.ndarray]:
        start = batch_index * self.batch_size
        selected = self.order[start : start + self.batch_size]
        frames = [
            load_rgb_window(
                self.frames_root,
                self.samples[int(index)],
                self.image_size,
                self.sequence_length,
                self.frame_stride,
                self.training,
                self.rng,
            )
            for index in selected
        ]
        labels = [int(self.samples[int(index)]["label_index"]) for index in selected]
        return np.stack(frames, axis=0), np.asarray(labels, dtype=np.int32)
