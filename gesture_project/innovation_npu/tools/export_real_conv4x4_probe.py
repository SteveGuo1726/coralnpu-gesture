#!/usr/bin/env python3
"""Export a deterministic first-layer INT8 window from a real TFLite model.

This is a project-local hardware golden generator.  It intentionally checks
the raw INT32 convolution accumulator before requantization; the latter is a
separate hardware stage and must not be silently folded into this check.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np


def quantize_multiplier(real_multiplier: float) -> tuple[int, int]:
    """Match TensorFlow Lite's QuantizeMultiplier for a positive scale."""
    significand, shift = math.frexp(real_multiplier)
    quantized = int(round(significand * (1 << 31)))
    if quantized == (1 << 31):
        quantized //= 2
        shift += 1
    if not (0 < quantized < (1 << 31)):
        raise ValueError(f"invalid TFLite multiplier {real_multiplier}")
    return quantized, shift


def trunc_divide(numerator: int, denominator: int) -> int:
    """C++ signed integer division, which truncates toward zero."""
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def saturating_rounding_doubling_high_mul(left: int, right: int) -> int:
    product = left * right
    nudge = (1 << 30) if product >= 0 else (1 - (1 << 30))
    return trunc_divide(product + nudge, 1 << 31)


def rounding_divide_by_pot(value: int, exponent: int) -> int:
    if exponent < 0:
        raise ValueError(f"negative right shift {exponent}")
    if exponent == 0:
        return value
    mask = (1 << exponent) - 1
    remainder = value & mask
    threshold = (mask >> 1) + (1 if value < 0 else 0)
    return (value >> exponent) + (1 if remainder > threshold else 0)


def multiply_by_quantized_multiplier(value: int, multiplier: int, shift: int) -> int:
    if shift > 0:
        value *= 1 << shift
        shift = 0
    return rounding_divide_by_pot(
        saturating_rounding_doubling_high_mul(value, multiplier), -shift
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--output_y", type=int, default=32)
    parser.add_argument("--output_x", type=int, default=32)
    args = parser.parse_args()

    # TensorFlow's reference resolver is preferred for a software golden.
    # A clean board-development WSL installation does not need the full
    # training stack, however, so retain a tflite-runtime fallback for model
    # inspection and deterministic integer reference generation.
    try:
        import tensorflow as tf  # pylint: disable=import-outside-toplevel

        interpreter = tf.lite.Interpreter(
            model_path=str(Path(args.model).resolve()),
            experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF,
        )
        interpreter_backend = "tensorflow_builtin_ref"
    except ModuleNotFoundError:
        from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

        interpreter = Interpreter(model_path=str(Path(args.model).resolve()))
        interpreter_backend = "tflite_runtime"
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    conv = next(
        op for op in interpreter._get_ops_details()  # pylint: disable=protected-access
        if op["op_name"] == "CONV_2D"
    )
    tensor_details = {item["index"]: item for item in interpreter.get_tensor_details()}
    weight_detail = tensor_details[conv["inputs"][1]]
    bias_detail = tensor_details[conv["inputs"][2]]
    output_conv_detail = tensor_details[conv["outputs"][0]]

    weights = np.asarray(interpreter.get_tensor(weight_detail["index"]), dtype=np.int8)
    bias = np.asarray(interpreter.get_tensor(bias_detail["index"]), dtype=np.int32)
    if weights.shape[1:3] != (4, 4) or weights.shape[3] != 3:
        raise SystemExit(f"Expected first 4x4 RGB convolution, got {weights.shape}")
    if weights.shape[0] != 16:
        raise SystemExit(f"Probe expects one 16-lane output tile, got {weights.shape[0]}")

    input_shape = tuple(int(value) for value in input_detail["shape"])
    if input_shape != (1, 96, 96, 3):
        raise SystemExit(f"Expected input shape (1,96,96,3), got {input_shape}")
    if not (1 <= args.output_y < 95 and 1 <= args.output_x < 95):
        raise SystemExit("Probe coordinate must leave the 4x4 SAME window in bounds")

    # Avoid image preprocessing ambiguity: this is a deterministic quantized
    # input tensor. Keep q values below zero so subtracting the input
    # zero-point remains representable as an INT8 operand for this first MAC.
    input_tensor = np.empty(input_shape, dtype=np.int8)
    for y in range(96):
        for x in range(96):
            for channel in range(3):
                input_tensor[0, y, x, channel] = np.int8(((y * 17 + x * 5 + channel * 29) % 127) - 127)
    interpreter.set_tensor(input_detail["index"], input_tensor)
    interpreter.invoke()
    conv_output = np.asarray(interpreter.get_tensor(output_conv_detail["index"]))

    # SAME stride-1 4x4 at an interior output uses [y-1:y+3, x-1:x+3].
    window = input_tensor[0, args.output_y - 1 : args.output_y + 3, args.output_x - 1 : args.output_x + 3, :]
    input_zero_point = int(input_detail["quantization"][1])
    hardware_window = window.astype(np.int16) - input_zero_point
    if hardware_window.min() < -128 or hardware_window.max() > 127:
        raise SystemExit("zero-point-adjusted activation does not fit INT8")
    expected = np.empty(16, dtype=np.int64)
    for output_channel in range(16):
        expected[output_channel] = int(bias[output_channel]) + int(
            np.sum(hardware_window.astype(np.int64) * weights[output_channel].astype(np.int64))
        )

    input_scale = float(input_detail["quantization"][0])
    output_scale, output_zero_point = output_conv_detail["quantization"]
    weight_scales = weight_detail["quantization_parameters"]["scales"]
    if len(weight_scales) != 16:
        raise SystemExit(f"Expected 16 per-channel weight scales, got {len(weight_scales)}")
    requant_multiplier = np.empty(16, dtype=np.int32)
    requant_shift = np.empty(16, dtype=np.int32)
    expected_quantized = np.empty(16, dtype=np.int8)
    for output_channel in range(16):
        multiplier, shift = quantize_multiplier(
            input_scale * float(weight_scales[output_channel]) / float(output_scale)
        )
        requant_multiplier[output_channel] = multiplier
        requant_shift[output_channel] = shift
        quantized = multiply_by_quantized_multiplier(
            int(expected[output_channel]), multiplier, shift) + int(output_zero_point)
        # This operator's output tensor name records the converter-fused ReLU.
        quantized = max(int(output_zero_point), min(127, quantized))
        expected_quantized[output_channel] = np.int8(quantized)

    tflite_quantized = conv_output[0, args.output_y, args.output_x, :16]
    if not np.array_equal(expected_quantized, tflite_quantized):
        raise SystemExit(
            "TFLite requant mismatch: "
            f"expected={expected_quantized.tolist()} "
            f"tflite={tflite_quantized.tolist()}"
        )

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    def c_array(values: np.ndarray, c_type: str, name: str) -> str:
        flat = values.reshape(-1).tolist()
        rows = []
        for index in range(0, len(flat), 16):
            rows.append("    " + ", ".join(str(int(value)) for value in flat[index : index + 16]))
        return f"static const {c_type} {name}[{len(flat)}] = {{\n" + ",\n".join(rows) + "\n};\n"

    text = """/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated from a real project-local TFLite INT8 model. */
#ifndef GESTUREFLOW_REAL_CONV4X4_PROBE_H
#define GESTUREFLOW_REAL_CONV4X4_PROBE_H
#include <stdint.h>

#define GF_REAL_PROBE_TAPS 16U
#define GF_REAL_PROBE_GROUPS 1U
#define GF_REAL_PROBE_OUTPUT_LANES 16U
#define GF_REAL_PROBE_INPUT_MASK 0x7U
#define GF_REAL_PROBE_OUTPUT_Y %dU
#define GF_REAL_PROBE_OUTPUT_X %dU
#define GF_REAL_PROBE_OUTPUT_ZERO_POINT %d

""" % (args.output_y, args.output_x, int(output_zero_point))
    text += c_array(weights.reshape(16, 16, 3), "int8_t", "gf_real_probe_weights")
    text += c_array(hardware_window.reshape(16, 3), "int8_t", "gf_real_probe_activation")
    text += c_array(bias[:16], "int32_t", "gf_real_probe_bias")
    text += c_array(expected.astype(np.int32), "int32_t", "gf_real_probe_expected_accum")
    text += c_array(requant_multiplier, "int32_t", "gf_real_probe_requant_multiplier")
    text += c_array(requant_shift, "int32_t", "gf_real_probe_requant_shift")
    text += c_array(expected_quantized, "int8_t", "gf_real_probe_expected_quantized")
    text += "\n#endif\n"
    out_path.write_text(text, encoding="ascii")

    print(f"Wrote {out_path}")
    print(f"interpreter_backend={interpreter_backend}")
    print(f"model_input_quant={input_detail['quantization']} conv_output_quant={output_conv_detail['quantization']}")
    print(f"tflite_input_window={window.reshape(-1).tolist()}")
    print(f"hardware_zero_point_adjusted_window={hardware_window.reshape(-1).tolist()}")
    print(f"expected_accum={expected.tolist()}")
    print(f"requant_multiplier={requant_multiplier.tolist()}")
    print(f"requant_shift={requant_shift.tolist()}")
    print(f"tflite_conv_output={tflite_quantized.tolist()}")


if __name__ == "__main__":
    main()
