"""Export one real quantized stage-3b convolution case for the 7020 board IP.

This is project-local data preparation. It reads the selected TFLite model and
image, then emits the exact tensors around ``conv3_3x3_b``:
tensor24 -> tensor25 -> maxpool -> tensor26.  The generated header is used by
the PL tensor-engine integration and its board-level software regression.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def quantize_multiplier(real_multiplier: float) -> tuple[int, int]:
    """Mirror TFLite's QuantizeMultiplier for positive per-channel scales."""
    significand, shift = math.frexp(real_multiplier)
    q_fixed = int(round(significand * (1 << 31)))
    if q_fixed == (1 << 31):
        q_fixed //= 2
        shift += 1
    if not (0 <= q_fixed < (1 << 31)):
        raise ValueError(f"Invalid quantized multiplier for {real_multiplier}")
    return q_fixed, shift


def format_values(values: np.ndarray, indent: str = "    ", width: int = 12) -> str:
    flat = values.reshape(-1)
    rows = []
    for start in range(0, len(flat), width):
        rows.append(indent + ", ".join(str(int(item)) for item in flat[start:start + width]) + ",")
    return "\n".join(rows)


def emit_array(name: str, ctype: str, values: np.ndarray) -> str:
    return (
        f"static const {ctype} {name}[{values.size}] = {{\n"
        f"{format_values(values)}\n"
        "};\n"
    )


def main() -> None:
    args = parse_args()
    import tensorflow as tf  # pylint: disable=import-outside-toplevel

    model_path = Path(args.model).resolve()
    image_path = Path(args.image).resolve()
    out_path = Path(args.out).resolve()

    interpreter = tf.lite.Interpreter(
        model_path=str(model_path), experimental_preserve_all_tensors=True
    )
    interpreter.allocate_tensors()
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    image = np.asarray(Image.open(image_path).convert("RGB").resize((96, 96), Image.BILINEAR), dtype=np.float32)
    input_detail = details[0]
    input_scale, input_zp = input_detail["quantization"]
    quant_input = np.clip(np.round(image / input_scale + input_zp), -128, 127).astype(np.int8)[None, ...]
    interpreter.set_tensor(0, quant_input)
    interpreter.invoke()

    tensor24 = interpreter.get_tensor(24).astype(np.int8)
    tensor25 = interpreter.get_tensor(25).astype(np.int8)
    tensor26 = interpreter.get_tensor(26).astype(np.int8)
    weights = interpreter.get_tensor(7).astype(np.int8)
    bias = interpreter.get_tensor(6).astype(np.int32)

    in_scale = float(details[24]["quantization"][0])
    out_scale = float(details[25]["quantization"][0])
    weight_scales = details[7]["quantization_parameters"]["scales"]
    multipliers, shifts = zip(*(quantize_multiplier(in_scale * float(scale) / out_scale)
                                for scale in weight_scales))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "#ifndef STATIC_CNN_STAGE3B_REAL_FIST_INT8_H",
        "#define STATIC_CNN_STAGE3B_REAL_FIST_INT8_H",
        "",
        "/* PROJECT_LOCAL_MOD: generated from the fixed real fist sample and model_int8.tflite. */",
        "#define STAGE3B_H 24",
        "#define STAGE3B_W 24",
        "#define STAGE3B_C 64",
        "#define STAGE3B_KERNEL 3",
        "#define STAGE3B_INPUT_ZP (-128)",
        "#define STAGE3B_OUTPUT_ZP (-128)",
        "#define STAGE3B_INPUT_BYTES (STAGE3B_H * STAGE3B_W * STAGE3B_C)",
        "#define STAGE3B_WEIGHT_BYTES (STAGE3B_C * STAGE3B_KERNEL * STAGE3B_KERNEL * STAGE3B_C)",
        "#define STAGE3B_OUTPUT_BYTES STAGE3B_INPUT_BYTES",
        "#define STAGE3B_POOL_BYTES ((STAGE3B_H / 2) * (STAGE3B_W / 2) * STAGE3B_C)",
        "",
        emit_array("kStage3bTensor24", "s8", tensor24),
        emit_array("kStage3bWeights", "s8", weights),
        emit_array("kStage3bBias", "s32", bias),
        emit_array("kStage3bMultiplier", "s32", np.asarray(multipliers, dtype=np.int32)),
        emit_array("kStage3bShift", "s32", np.asarray(shifts, dtype=np.int32)),
        emit_array("kStage3bTensor25Expected", "s8", tensor25),
        emit_array("kStage3bTensor26Expected", "s8", tensor26),
        "#endif",
        "",
    ]
    out_path.write_text("\n".join(lines), encoding="ascii")
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)")
    print(f"tensor24={tensor24.shape} weights={weights.shape} tensor25={tensor25.shape} tensor26={tensor26.shape}")
    print(f"input_scale={in_scale:.12g} output_scale={out_scale:.12g}")
    print(f"multiplier0={multipliers[0]} shift0={shifts[0]}")
    print(f"tensor26_checksum={int(np.sum(tensor26.astype(np.int64)))}")


if __name__ == "__main__":
    main()
