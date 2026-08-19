#!/usr/bin/env python3
"""Export exact TFLite INT8 GAP and fully-connected data for GestureFlow.

PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL

This exporter deliberately follows LiteRT's integer ReduceMean reference
algorithm, including its integration of the division by the reduction size
into a Q31 multiplier.  A floating point average is not bit exact for the
current model and must not be used as a hardware golden.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np


def quantize_multiplier(real_multiplier: float) -> tuple[int, int]:
    significand, shift = math.frexp(real_multiplier)
    multiplier = int(round(significand * (1 << 31)))
    if multiplier == (1 << 31):
        multiplier //= 2
        shift += 1
    if not 0 < multiplier < (1 << 31):
        raise ValueError(f"Invalid quantized multiplier {real_multiplier}")
    return multiplier, shift


def trunc_divide(numerator: int, denominator: int) -> int:
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def high_mul(left: int, right: int) -> int:
    if left == -(1 << 31) and right == -(1 << 31):
        return (1 << 31) - 1
    product = left * right
    nudge = (1 << 30) if product >= 0 else 1 - (1 << 30)
    return trunc_divide(product + nudge, 1 << 31)


def round_divide_by_pot(value: int, exponent: int) -> int:
    if exponent == 0:
        return value
    mask = (1 << exponent) - 1
    remainder = value & mask
    threshold = (mask >> 1) + (1 if value < 0 else 0)
    return (value >> exponent) + int(remainder > threshold)


def multiply_by_quantized_multiplier(value: int, multiplier: int, shift: int) -> int:
    if shift > 0:
        value *= 1 << shift
        shift = 0
    return round_divide_by_pot(high_mul(value, multiplier), -shift)


def mean_multiplier(input_scale: float, output_scale: float, elements: int) -> tuple[int, int]:
    """Reproduce `reference_ops::QuantizedMeanOrSum` exactly."""
    multiplier, output_shift = quantize_multiplier(input_scale / output_scale)
    adjustment = min(elements.bit_length() - 1, 32, 31 + output_shift)
    adjusted_multiplier = (multiplier << adjustment) // elements
    return adjusted_multiplier, output_shift - adjustment


def saturate_int8(value: int) -> int:
    return max(-128, min(127, value))


def fnv1a32(values: np.ndarray) -> int:
    value = 0x811C9DC5
    for byte in np.ascontiguousarray(values).view(np.uint8).reshape(-1):
        value = ((value ^ int(byte)) * 0x01000193) & 0xFFFFFFFF
    return value


def c_array(values: np.ndarray, c_type: str, name: str, columns: int = 16) -> str:
    values = np.asarray(values).reshape(-1)
    rows = [
        "    " + ", ".join(str(int(item)) for item in values[offset : offset + columns])
        for offset in range(0, values.size, columns)
    ]
    return f"static const {c_type} {name}[{values.size}] = {{\n" + ",\n".join(rows) + "\n};\n"


def deterministic_input() -> np.ndarray:
    row, column, channel = np.indices((96, 96, 3))
    return (((row * 17 + column * 5 + channel * 29 + 37) & 0xFF).astype(np.uint8)
            .astype(np.int16) - 128).astype(np.int8)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--c-out", required=True, type=Path)
    parser.add_argument("--head-mem-out", type=Path)
    parser.add_argument("--fc-mem-out", type=Path)
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    interpreter = Interpreter(model_path=str(args.model.resolve()), experimental_preserve_all_tensors=True)
    interpreter.allocate_tensors()
    interpreter.set_tensor(interpreter.get_input_details()[0]["index"], deterministic_input()[np.newaxis, ...])
    interpreter.invoke()
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    ops = interpreter._get_ops_details()  # pylint: disable=protected-access
    mean = next(item for item in ops if item["op_name"] == "MEAN")
    fc = next(item for item in ops if item["op_name"] == "FULLY_CONNECTED")
    head_index = int(mean["inputs"][0])
    gap_index = int(mean["outputs"][0])
    q27 = np.asarray(interpreter.get_tensor(head_index), dtype=np.int8)[0]
    q28 = np.asarray(interpreter.get_tensor(gap_index), dtype=np.int8)[0]
    q29 = np.asarray(interpreter.get_tensor(int(fc["outputs"][0])), dtype=np.int8)[0]
    if q27.shape != (12, 12, 112) or q28.shape != (112,) or q29.shape != (6,):
        raise SystemExit(f"Unexpected postprocess tensors: {q27.shape}, {q28.shape}, {q29.shape}")

    head_scale, head_zp = details[head_index]["quantization"]
    gap_scale, gap_zp = details[gap_index]["quantization"]
    gap_multiplier, gap_shift = mean_multiplier(float(head_scale), float(gap_scale), 144)
    gap_sums = q27.astype(np.int64).sum(axis=(0, 1)).astype(np.int32)
    gap_values = np.asarray([
        saturate_int8(multiply_by_quantized_multiplier(int(total) - int(head_zp) * 144,
                                                        gap_multiplier, gap_shift) + int(gap_zp))
        for total in gap_sums
    ], dtype=np.int8)
    if not np.array_equal(gap_values, q28):
        bad = int(np.flatnonzero(gap_values != q28)[0])
        raise SystemExit(f"TFLite GAP mismatch channel={bad}: {gap_values[bad]} != {q28[bad]}")

    fc_weights = np.asarray(interpreter.get_tensor(int(fc["inputs"][1])), dtype=np.int8)
    fc_bias = np.asarray(interpreter.get_tensor(int(fc["inputs"][2])), dtype=np.int32)
    if fc_weights.shape != (6, 112) or fc_bias.shape != (6,):
        raise SystemExit(f"Unexpected FC parameter shapes {fc_weights.shape}, {fc_bias.shape}")
    fc_scale, fc_zp = details[int(fc["outputs"][0])]["quantization"]
    fc_weight_scales = details[int(fc["inputs"][1])]["quantization_parameters"]["scales"]
    fc_weight_zps = details[int(fc["inputs"][1])]["quantization_parameters"]["zero_points"]
    if not np.all(fc_weight_zps == 0):
        raise SystemExit(f"Unsupported nonzero FC weight zero points {fc_weight_zps}")
    fc_multipliers = np.empty(6, dtype=np.int32)
    fc_right_shifts = np.empty(6, dtype=np.uint8)
    fc_folded_bias = fc_bias.astype(np.int64) - int(gap_zp) * fc_weights.astype(np.int64).sum(axis=1)
    fc_quantized = np.empty(6, dtype=np.int8)
    for output in range(6):
        multiplier, shift = quantize_multiplier(float(gap_scale) * float(fc_weight_scales[output]) / float(fc_scale))
        if shift > 0 or shift < -31:
            raise SystemExit(f"Unsupported FC shift {shift} for output {output}")
        fc_multipliers[output] = multiplier
        fc_right_shifts[output] = -shift
        raw = int(fc_folded_bias[output] + np.dot(q28.astype(np.int64), fc_weights[output].astype(np.int64)))
        fc_quantized[output] = saturate_int8(multiply_by_quantized_multiplier(raw, multiplier, shift) + int(fc_zp))
    if not np.array_equal(fc_quantized, q29):
        bad = int(np.flatnonzero(fc_quantized != q29)[0])
        raise SystemExit(f"TFLite FC mismatch class={bad}: {fc_quantized[bad]} != {q29[bad]}")
    if fc_folded_bias.min() < -(1 << 31) or fc_folded_bias.max() >= (1 << 31):
        raise SystemExit("FC folded bias overflows INT32")

    text = """/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated by export_real_gap_fc.py. Do not hand edit. */
#ifndef GESTUREFLOW_REAL_GAP_FC_H
#define GESTUREFLOW_REAL_GAP_FC_H
#include <stdint.h>
#define GF_POST_HEAD_HEIGHT 12U
#define GF_POST_HEAD_WIDTH 12U
#define GF_POST_GAP_CHANNELS 112U
#define GF_POST_GAP_ELEMENTS 144U
#define GF_POST_FC_OUTPUTS 6U
#define GF_POST_GAP_INPUT_ZERO_POINT (%d)
#define GF_POST_GAP_OUTPUT_ZERO_POINT (%d)
#define GF_POST_FC_OUTPUT_ZERO_POINT (%d)
#define GF_POST_GAP_MULTIPLIER (%d)
#define GF_POST_GAP_RIGHT_SHIFT (%dU)
#define GF_POST_HEAD_EXPECTED_FNV1A 0x%08XU
#define GF_POST_GAP_EXPECTED_FNV1A 0x%08XU
#define GF_POST_FC_EXPECTED_FNV1A 0x%08XU
#define GF_POST_EXPECTED_CLASS (%dU)
""" % (int(head_zp), int(gap_zp), int(fc_zp), gap_multiplier, -gap_shift,
       fnv1a32(q27), fnv1a32(q28), fnv1a32(q29), int(np.argmax(q29)))
    text += c_array(fc_weights, "int8_t", "gf_post_fc_weights")
    text += c_array(fc_folded_bias.astype(np.int32), "int32_t", "gf_post_fc_folded_bias")
    text += c_array(fc_multipliers, "int32_t", "gf_post_fc_requant_multiplier")
    text += c_array(fc_right_shifts, "uint8_t", "gf_post_fc_requant_right_shift")
    text += c_array(q28, "int8_t", "gf_post_gap_golden")
    text += c_array(q29, "int8_t", "gf_post_fc_golden")
    text += "#endif\n"
    args.c_out.parent.mkdir(parents=True, exist_ok=True)
    args.c_out.write_text(text, encoding="ascii")
    if args.head_mem_out:
        args.head_mem_out.parent.mkdir(parents=True, exist_ok=True)
        args.head_mem_out.write_text("\n".join(f"{int(value) & 0xff:02x}" for value in q27.reshape(-1)) + "\n", encoding="ascii")
    if args.fc_mem_out:
        args.fc_mem_out.parent.mkdir(parents=True, exist_ok=True)
        args.fc_mem_out.write_text("\n".join(f"{int(value) & 0xff:02x}" for value in fc_weights.reshape(-1)) + "\n", encoding="ascii")
    print("GESTUREFLOW_REAL_GAP_FC_EXPORT_PASS "
          f"head=0x{fnv1a32(q27):08X} gap=0x{fnv1a32(q28):08X} "
          f"fc=0x{fnv1a32(q29):08X} class={int(np.argmax(q29))} "
          f"gap_multiplier={gap_multiplier} gap_right_shift={-gap_shift}")


if __name__ == "__main__":
    main()
