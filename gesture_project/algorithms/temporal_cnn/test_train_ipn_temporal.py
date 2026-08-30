"""Bounded integration test for the IPN temporal trainer.

PROJECT_LOCAL_MOD: Synthetic files exercise the training plumbing only; the
reported value is not a model-quality result.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image


def _write_sample(root: Path, name: str, label: int) -> dict:
    frame_dir = root / "frames" / name
    frame_dir.mkdir(parents=True, exist_ok=True)
    for frame_index in range(1, 5):
        pixels = np.full((24, 24, 3), label * 80 + frame_index, dtype=np.uint8)
        Image.fromarray(pixels, mode="RGB").save(
            frame_dir / f"{name}_{frame_index:06d}.jpg"
        )
    return {
        "frame_dir": f"frames/{name}",
        "label_index": label,
        "label": f"class_{label}",
        "start_frame": 1,
        "end_frame": 4,
        "num_frames": 4,
    }


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="ipn-train-test-") as root_text:
        root = Path(root_text)
        train = [_write_sample(root, f"train_{index}", index % 2) for index in range(4)]
        val = [_write_sample(root, f"val_{index}", index % 2) for index in range(2)]
        manifest_dir = root / "manifests"
        manifest_dir.mkdir()
        for name, samples in (("train", train), ("val", val)):
            (manifest_dir / f"{name}.jsonl").write_text(
                "".join(json.dumps(sample) + "\n" for sample in samples), encoding="utf-8"
            )
        (manifest_dir / "labels.txt").write_text("class_0\nclass_1\n", encoding="utf-8")
        output_dir = root / "output"
        script = Path(__file__).with_name("train_ipn_temporal.py")
        env = dict(os.environ)
        env["PYTHONPATH"] = str(script.parent)
        result = subprocess.run(
            [
                sys.executable,
                str(script),
                "--frames_root",
                str(root),
                "--manifest_dir",
                str(manifest_dir),
                "--output_dir",
                str(output_dir),
                "--sequence_length",
                "1",
                "--frame_stride",
                "1",
                "--image_size",
                "32",
                "--batch_size",
                "2",
                "--epochs",
                "1",
                "--early_stop_patience",
                "1",
            ],
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise SystemExit(result.stdout + "\n" + result.stderr)
        summary = json.loads((output_dir / "training_summary.json").read_text(encoding="utf-8"))
        if not (output_dir / "best.weights.h5").is_file() or summary["epochs_run"] != 1:
            raise SystemExit("trainer did not produce the bounded checkpoint and summary")
        print(json.dumps({"status": "PASS", "epochs_run": summary["epochs_run"]}))


if __name__ == "__main__":
    main()
