"""Bounded local test for the IPN frame-window reader.

PROJECT_LOCAL_MOD: The test uses temporary synthetic RGB files and is only a
format/shape test. It is not an IPN accuracy measurement.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

from ipn_hand_sequence import IPNWindowSequence, load_rgb_window, read_manifest


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="ipn-window-test-") as root_text:
        root = Path(root_text)
        frame_dir = root / "frames" / "clip_001"
        frame_dir.mkdir(parents=True)
        for frame_index in range(1, 17):
            pixels = np.full((24, 32, 3), frame_index, dtype=np.uint8)
            Image.fromarray(pixels, mode="RGB").save(
                frame_dir / f"clip_001_{frame_index:06d}.jpg"
            )
        manifest = root / "train.jsonl"
        manifest.write_text(
            json.dumps(
                {
                    "frame_dir": "frames/clip_001",
                    "label_index": 3,
                    "label": "G03",
                    "start_frame": 1,
                    "end_frame": 16,
                    "num_frames": 16,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        samples = read_manifest(manifest)
        rng = np.random.default_rng(1)
        dynamic = load_rgb_window(root, samples[0], 96, 8, 2, False, rng)
        static = load_rgb_window(root, samples[0], 96, 1, 1, False, rng)
        if dynamic.shape != (8, 96, 96, 3) or static.shape != (1, 96, 96, 3):
            raise SystemExit(f"unexpected window shapes: {dynamic.shape}, {static.shape}")
        sequence = IPNWindowSequence(
            samples,
            root,
            batch_size=1,
            image_size=96,
            sequence_length=8,
            frame_stride=2,
            training=False,
        )
        batch, labels = sequence[0]
        if batch.shape != (1, 8, 96, 96, 3) or labels.tolist() != [3]:
            raise SystemExit(f"unexpected batch: {batch.shape}, {labels.tolist()}")
        print(
            json.dumps(
                {
                    "status": "PASS",
                    "dynamic_shape": list(dynamic.shape),
                    "static_shape": list(static.shape),
                    "batch_shape": list(batch.shape),
                    "labels": labels.tolist(),
                    "center_frame_pixel": int(dynamic[0, 0, 0, 0]),
                }
            )
        )


if __name__ == "__main__":
    main()
