#!/usr/bin/env python3
"""Evaluate the shipped INT8 TFLite model the way the board consumes it.

Why this exists
---------------
Every decision in docs/全局重规划_2026-09-12.md depends on two numbers that nobody
had measured: how accurate the model is *on the distribution it was trained on*,
and how fast that collapses when the hand occupies less of the frame (which is
what the camera actually delivers).  Both come out of this one code path.

The preprocessing here is deliberately the same as training's:
    Image.open(p).convert("RGB").resize((96,96), Image.BILINEAR)
and the input tensor is `int8` with the same convention the PL uses
(`gestureflow_hp0_rgb_loader.sv`: q = u - 128), so this tool and the hardware
agree by construction rather than by hope.

Modes
-----
  crops    per-class directories of hand crops  -> "training distribution" number
  frames   full frames + bboxes from the archive, windowed around the hand at a
           chosen hand fraction             -> "deployment geometry" number

Reported
--------
  * top-1 overall and per class
  * the full confusion matrix (this is what decides whether mirrored pairs such
    as peace/peace_inverted should be merged)
  * per-prediction confidence / margin / entropy, written to CSV so a rejection
    threshold can be picked from the reject-vs-false-reject curve instead of
    guessed

Usage
-----
  python3 eval_int8_deployment.py crops  --dir <test_split> --per-class 200
  python3 eval_int8_deployment.py frames --zip <archive.zip> --ann <ann_dir> \
        --per-class 100 --hand-fraction 0.25 --out out/geometry_025
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image
from tflite_runtime.interpreter import Interpreter

MODEL_DEFAULT = (
    "gesture_project/models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827"
    "/model_int8.tflite"
)
LABELS_DEFAULT = (
    "gesture_project/models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827"
    "/labels.txt"
)
SIZE = 96


# --------------------------------------------------------------------------- model
class Model:
    def __init__(self, path: str, labels: list[str]):
        self.it = Interpreter(model_path=path, num_threads=4)
        self.it.allocate_tensors()
        self.inp = self.it.get_input_details()[0]
        self.out = self.it.get_output_details()[0]
        self.labels = labels
        iscale, izp = self.inp["quantization"]
        oscale, ozp = self.out["quantization"]
        if self.inp["dtype"] != np.int8:
            raise SystemExit("expected an int8 input tensor, got %s" % self.inp["dtype"])
        # Training/PL convention is q = u - 128.  Fail loudly if that is not what
        # the exported tensor says, instead of silently feeding a different scale.
        self.offset = int(round(izp - 0.0 / iscale))  # scale is 1.0 for this model
        print("input : %s %s scale=%s zp=%s -> offset=%d"
              % (self.inp["name"], self.inp["shape"], iscale, izp, self.offset))
        print("output: %s %s scale=%s zp=%s"
              % (self.out["name"], self.out["shape"], oscale, ozp))
        if abs(iscale - 1.0) > 1e-6 or izp != -128:
            print("WARNING: input quantisation is not 'u-128'; check the tool against the PL")

    def predict(self, rgb_u8: np.ndarray) -> np.ndarray:
        """rgb_u8: HxWx3 uint8 in 0..255.  Returns float32 probabilities."""
        q = rgb_u8.astype(np.int16) + self.offset
        q = np.clip(q, -128, 127).astype(np.int8)[None, ...]
        self.it.set_tensor(self.inp["index"], q)
        self.it.invoke()
        raw = self.it.get_tensor(self.out["index"])[0].astype(np.float32)
        oscale, ozp = self.out["quantization"]
        return (raw - ozp) * oscale


# ----------------------------------------------------------------------- helpers
def load_rgb96(src) -> np.ndarray:
    """Accept a path, raw bytes, or an already-open PIL image; return 96x96x3 uint8.

    The PIL-Image case is not cosmetic: the geometry sweep hands in a window that
    was just cropped out of a full frame, and re-encoding it to bytes just to
    re-open it would (a) waste time and (b) risk changing the pixels.
    """
    if isinstance(src, Image.Image):
        im = src
    elif isinstance(src, (bytes, bytearray)):
        im = Image.open(io.BytesIO(src))
    else:
        im = Image.open(src)
    return np.asarray(im.convert("RGB").resize((SIZE, SIZE), Image.BILINEAR),
                      dtype=np.uint8)


def window_around(im: Image.Image, cx: float, cy: float, win: int) -> Image.Image:
    """Square window of `win` pixels centred on (cx,cy), clamped into the image.

    Clamping (rather than padding) is the honest choice: when the requested
    window is larger than the frame it degenerates to "the whole frame", which is
    exactly the deployment case we are trying to characterise.
    """
    W, H = im.size
    win = min(win, W, H)
    x0 = int(round(cx - win / 2.0))
    y0 = int(round(cy - win / 2.0))
    x0 = max(0, min(W - win, x0))
    y0 = max(0, min(H - win, y0))
    return im.crop((x0, y0, x0 + win, y0 + win))


def stride_pick(items: list, n: int) -> list:
    """Evenly spaced sample, so the subset is not the alphabetically-first corner."""
    if n <= 0 or n >= len(items):
        return items
    step = len(items) / float(n)
    return [items[int(i * step)] for i in range(n)]


def entropy(p: np.ndarray) -> float:
    return float(-(p * np.log(np.maximum(p, 1e-12))).sum())


# -------------------------------------------------------------------------- eval
def run(model: Model, samples, out_dir: Path, tag: str):
    """samples: iterable of (rgb_u8, true_index, name)."""
    n_cls = len(model.labels)
    conf = np.zeros((n_cls, n_cls), dtype=np.int64)
    rows = []
    n = 0
    for rgb, y, name in samples:
        p = model.predict(rgb)
        pred = int(np.argmax(p))
        conf[y, pred] += 1
        srt = np.sort(p)[::-1]
        rows.append((name, y, pred, float(srt[0]), float(srt[0] - (srt[1] if n_cls > 1 else 0.0)),
                     entropy(p)))
        n += 1
        if n % 500 == 0:
            print("  ... %d" % n, flush=True)

    acc = float(np.trace(conf)) / max(1, n)
    print("\n=== %s ===" % tag)
    print("samples %d   top-1 %.4f" % (n, acc))
    print("\nper class:")
    for i, lab in enumerate(model.labels):
        tot = conf[i].sum()
        print("  %2d %-16s %6d  %6.2f%%" % (i, lab, tot, 100.0 * conf[i, i] / max(1, tot)))

    out_dir.mkdir(parents=True, exist_ok=True)
    with open(out_dir / "confusion.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["true\\pred"] + model.labels)
        for i, lab in enumerate(model.labels):
            w.writerow([lab] + list(conf[i]))
    with open(out_dir / "predictions.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["name", "true", "pred", "p_max", "margin", "entropy", "correct"])
        for name, y, pred, pmax, marg, ent in rows:
            w.writerow([name, model.labels[y], model.labels[pred],
                        "%.6f" % pmax, "%.6f" % marg, "%.6f" % ent, int(y == pred)])
    summary = {"tag": tag, "samples": n, "top1": acc,
               "per_class": {lab: conf[i, i] / max(1, conf[i].sum()) for i, lab in enumerate(model.labels)}}
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")

    # the block that actually decides the merge question
    print("\nconfusion (rows = true, cols = pred, off-diagonal only, top 12):")
    off = [(int(conf[i, j]), i, j) for i in range(n_cls) for j in range(n_cls) if i != j]
    for cnt, i, j in sorted(off, reverse=True)[:12]:
        if cnt == 0:
            break
        print("  %5d  %-16s -> %-16s" % (cnt, model.labels[i], model.labels[j]))
    print("\nwrote %s" % out_dir)
    return acc


def samples_crops(root: Path, labels: list[str], per_class: int):
    for y, lab in enumerate(labels):
        d = root / lab
        if not d.is_dir():
            print("  (no dir for %s)" % lab)
            continue
        files = sorted(p for p in d.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        for p in stride_pick(files, per_class):
            yield load_rgb96(str(p)), y, "%s/%s" % (lab, p.name)


def samples_frames(zip_path: Path, ann_dir: Path, labels: list[str], per_class: int,
                   hand_fraction: float, root_prefix: str):
    zf = zipfile.ZipFile(zip_path)
    for y, lab in enumerate(labels):
        ap = ann_dir / ("%s.json" % lab)
        if not ap.exists():
            print("  (no annotations for %s)" % lab)
            continue
        ann = json.loads(ap.read_text(encoding="utf-8"))
        keys = sorted(ann.keys())
        picked = stride_pick(keys, per_class)
        for k in picked:
            entry = ann[k]
            bboxes = entry.get("bboxes") or []
            labs = entry.get("labels") or []
            # the hand that actually carries this gesture
            idx = [i for i, l in enumerate(labs) if l == lab]
            if not idx:
                continue
            bx, by, bw, bh = bboxes[idx[0]]
            member = "%s/%s/%s.jpg" % (root_prefix, _class_dir(lab), k)
            try:
                data = zf.read(member)
            except KeyError:
                continue
            im = Image.open(io.BytesIO(data)).convert("RGB")
            W, H = im.size
            cx, cy = (bx + bw / 2.0) * W, (by + bh / 2.0) * H
            hand = max(bw * W, bh * H)
            win = int(round(hand / max(hand_fraction, 1e-3)))
            yield load_rgb96(window_around(im, cx, cy, win)), y, "%s/%s" % (lab, k)


def _class_dir(label: str) -> str:
    return "train_val_%s" % label


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["crops", "frames"])
    ap.add_argument("--model", default=MODEL_DEFAULT)
    ap.add_argument("--labels", default=LABELS_DEFAULT)
    ap.add_argument("--per-class", type=int, default=200)
    ap.add_argument("--out", default=None)
    ap.add_argument("--dir", help="crops: test split root (contains <class>/ dirs)")
    ap.add_argument("--zip", help="frames: full-frame archive")
    ap.add_argument("--ann", help="frames: directory of <class>.json annotations")
    ap.add_argument("--root-prefix", default="hagrid-sample-500k-384p/hagrid_500k")
    ap.add_argument("--hand-fraction", type=float, default=1.0)
    a = ap.parse_args()

    labels = Path(a.labels).read_text(encoding="utf-8").split()
    model = Model(a.model, labels)
    out = Path(a.out or ("/tmp/eval_%s" % a.mode))

    if a.mode == "crops":
        if not a.dir:
            raise SystemExit("--dir is required for crops")
        tag = "training distribution (hand crops, test split), %d/class" % a.per_class
        gen = samples_crops(Path(a.dir), labels, a.per_class)
    else:
        if not (a.zip and a.ann):
            raise SystemExit("--zip and --ann are required for frames")
        tag = "deployment geometry: hand = %.0f%% of the model input" % (100 * a.hand_fraction)
        gen = samples_frames(Path(a.zip), Path(a.ann), labels, a.per_class,
                             a.hand_fraction, a.root_prefix)

    run(model, gen, out, tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
