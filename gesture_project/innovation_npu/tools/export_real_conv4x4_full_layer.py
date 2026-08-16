#!/usr/bin/env python3
"""Export a real full first-layer TFLite golden for GestureFlow-NPU.

This is project-local validation data, not Google CoralNPU source or output.
It deliberately uses camera-domain RGB bytes and proves the required folded
bias identity before emitting the compact data used by the RTL regression:

  sum((q - zp) * w) + b == sum(q * w) + (b - zp * sum(w)).

For SAME padding the padded q value is zp.  The stream front end must receive
that value as ``input_zero_point``; using byte zero would make border outputs
mathematically different from TFLite whenever zp is non-zero.
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
    if not (0 < multiplier < (1 << 31)):
        raise ValueError(f"Invalid TFLite multiplier: {real_multiplier}")
    return multiplier, shift


def trunc_divide(numerator: int, denominator: int) -> int:
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def saturating_rounding_doubling_high_mul(left: int, right: int) -> int:
    if left == -(1 << 31) and right == -(1 << 31):
        return (1 << 31) - 1
    product = left * right
    nudge = (1 << 30) if product >= 0 else (1 - (1 << 30))
    return trunc_divide(product + nudge, 1 << 31)


def rounding_divide_by_pot(value: int, exponent: int) -> int:
    if exponent == 0:
        return value
    mask = (1 << exponent) - 1
    remainder = value & mask
    threshold = (mask >> 1) + (1 if value < 0 else 0)
    return (value >> exponent) + int(remainder > threshold)


def requantize(value: int, multiplier: int, shift: int, zero_point: int) -> int:
    if shift > 0:
        value *= 1 << shift
        shift = 0
    result = rounding_divide_by_pot(
        saturating_rounding_doubling_high_mul(value, multiplier), -shift
    ) + zero_point
    # The first model tensor is fused with ReLU and its quantized floor is zp.
    return max(zero_point, min(127, result))


def fnv1a32(array: np.ndarray) -> int:
    value = 0x811C9DC5
    for byte in np.ascontiguousarray(array).view(np.uint8).reshape(-1):
        value = ((value ^ int(byte)) * 0x01000193) & 0xFFFFFFFF
    return value


def c_array(values: np.ndarray, c_type: str, name: str, columns: int = 16) -> str:
    flat = values.reshape(-1).tolist()
    rows = [
        "    " + ", ".join(str(int(item)) for item in flat[index : index + columns])
        for index in range(0, len(flat), columns)
    ]
    return f"static const {c_type} {name}[{len(flat)}] = {{\n" + ",\n".join(rows) + "\n};\n"


def sv_array(values: np.ndarray, name: str, columns: int = 16) -> str:
    def signed_literal(value: int, width: int = 8) -> str:
        # Unary minus precedes a sized literal in legal SystemVerilog. The
        # tempting `8'sd-36` form is rejected by Verilator and Vivado.
        return f"-{width}'sd{-value}" if value < 0 else f"{width}'sd{value}"

    flat = values.reshape(-1).tolist()
    rows = [
        "  " + ", ".join(signed_literal(int(item)) for item in flat[index : index + columns])
        for index in range(0, len(flat), columns)
    ]
    return (
        f"localparam logic signed [7:0] {name} [0:{len(flat) - 1}] = '{{\n"
        + ",\n".join(rows) + "\n};\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--c-out", required=True, type=Path)
    parser.add_argument("--svh-out", required=True, type=Path)
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    interpreter = Interpreter(model_path=str(args.model.resolve()))
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    if tuple(input_detail["shape"]) != (1, 96, 96, 3) or input_detail["dtype"] != np.int8:
        raise SystemExit(f"Unexpected first-layer input: {input_detail}")
    ops = interpreter._get_ops_details()  # pylint: disable=protected-access
    conv = next(item for item in ops if item["op_name"] == "CONV_2D")
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    weights = np.asarray(interpreter.get_tensor(conv["inputs"][1]), dtype=np.int8)
    bias = np.asarray(interpreter.get_tensor(conv["inputs"][2]), dtype=np.int32)
    output_index = int(conv["outputs"][0])
    output_detail = details[output_index]
    if weights.shape != (16, 4, 4, 3):
        raise SystemExit(f"Unexpected first-layer weights: {weights.shape}")

    input_scale, input_zp = input_detail["quantization"]
    output_scale, output_zp = output_detail["quantization"]
    input_zp = int(input_zp)
    output_zp = int(output_zp)
    weight_scales = details[conv["inputs"][1]]["quantization_parameters"]["scales"]

    # A deterministic full-range camera byte payload. It is intentionally not
    # a pre-selected negative tensor: hardware receives actual uint8 RGB and
    # applies q = u - 128 at the camera/stream boundary.
    y, x, channel = np.indices((96, 96, 3))
    camera_rgb = ((y * 17 + x * 5 + channel * 29 + 37) & 0xFF).astype(np.uint8)
    q_input = (camera_rgb.astype(np.int16) - 128).astype(np.int8)
    interpreter.set_tensor(input_detail["index"], q_input[np.newaxis, ...])
    interpreter.invoke()
    tflite_output = np.asarray(interpreter.get_tensor(output_index), dtype=np.int8)[0]

    padded = np.full((99, 99, 3), input_zp, dtype=np.int8)
    padded[1:97, 1:97, :] = q_input
    raw_standard = np.broadcast_to(bias.astype(np.int64), (96, 96, 16)).copy()
    raw_folded = np.broadcast_to(
        (bias.astype(np.int64) - input_zp * weights.astype(np.int64).sum(axis=(1, 2, 3))),
        (96, 96, 16),
    ).copy()
    for kernel_y in range(4):
        for kernel_x in range(4):
            pixels = padded[kernel_y : kernel_y + 96, kernel_x : kernel_x + 96, :].astype(np.int64)
            kernel = weights[:, kernel_y, kernel_x, :].astype(np.int64)
            raw_standard += np.tensordot(pixels - input_zp, kernel, axes=([2], [1]))
            raw_folded += np.tensordot(pixels, kernel, axes=([2], [1]))
    if not np.array_equal(raw_standard, raw_folded):
        raise SystemExit("Folded-bias proof failed: raw INT32 tensors differ")
    if raw_folded.min() < np.iinfo(np.int32).min or raw_folded.max() > np.iinfo(np.int32).max:
        raise SystemExit("First-layer folded accumulator exceeds INT32")

    multipliers = np.empty(16, dtype=np.int32)
    right_shifts = np.empty(16, dtype=np.uint8)
    quantized = np.empty_like(tflite_output)
    for lane in range(16):
        multiplier, shift = quantize_multiplier(float(input_scale) * float(weight_scales[lane]) / float(output_scale))
        if shift > 0 or -shift > 31:
            raise SystemExit(f"Unsupported first-layer requant shift {shift} for lane {lane}")
        multipliers[lane] = multiplier
        right_shifts[lane] = -shift
        for row in range(96):
            for column in range(96):
                quantized[row, column, lane] = np.int8(
                    requantize(int(raw_folded[row, column, lane]), multiplier, shift, output_zp)
                )
    if not np.array_equal(quantized, tflite_output):
        mismatch = np.argwhere(quantized != tflite_output)[0]
        raise SystemExit(
            "TFLite first-layer requant mismatch at "
            f"{mismatch.tolist()}: generated={int(quantized[tuple(mismatch)])} "
            f"tflite={int(tflite_output[tuple(mismatch)])}"
        )

    folded_bias = (bias.astype(np.int64) - input_zp * weights.astype(np.int64).sum(axis=(1, 2, 3))).astype(np.int32)
    probes = np.asarray([(0, 0), (0, 95), (1, 1), (31, 63), (48, 48), (95, 0), (95, 95)], dtype=np.uint16)
    probe_quant = np.asarray([quantized[row, column] for row, column in probes], dtype=np.int8)
    probe_raw = np.asarray([raw_folded[row, column] for row, column in probes], dtype=np.int32)

    args.c_out.parent.mkdir(parents=True, exist_ok=True)
    args.svh_out.parent.mkdir(parents=True, exist_ok=True)
    c_text = """/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated by export_real_conv4x4_full_layer.py. Do not hand edit. */
#ifndef GESTUREFLOW_REAL_CONV4X4_FULL_LAYER_H
#define GESTUREFLOW_REAL_CONV4X4_FULL_LAYER_H
#include <stdint.h>
#define GF_FULL_IMAGE_WIDTH 96U
#define GF_FULL_IMAGE_HEIGHT 96U
#define GF_FULL_INPUT_CHANNELS 3U
#define GF_FULL_OUTPUT_LANES 16U
#define GF_FULL_INPUT_ZERO_POINT %d
#define GF_FULL_OUTPUT_ZERO_POINT %d
#define GF_FULL_OUTPUT_FNV1A 0x%08XU
#define GF_FULL_RAW_FNV1A 0x%08XU
\n""" % (input_zp, output_zp, fnv1a32(quantized), fnv1a32(raw_folded.astype('<i4')))
    c_text += c_array(camera_rgb, "uint8_t", "gf_full_camera_rgb")
    c_text += c_array(weights, "int8_t", "gf_full_weights")
    c_text += c_array(bias, "int32_t", "gf_full_original_bias")
    c_text += c_array(folded_bias, "int32_t", "gf_full_folded_bias")
    c_text += c_array(multipliers, "int32_t", "gf_full_requant_multiplier")
    c_text += c_array(right_shifts, "uint8_t", "gf_full_requant_right_shift")
    c_text += c_array(probes, "uint16_t", "gf_full_probe_yx", columns=14)
    c_text += c_array(probe_raw, "int32_t", "gf_full_probe_raw")
    c_text += c_array(probe_quant, "int8_t", "gf_full_probe_quant")
    c_text += "\n#endif\n"
    args.c_out.write_text(c_text, encoding="ascii")

    svh_text = """// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Generated by export_real_conv4x4_full_layer.py. Do not hand edit.
localparam int GF_FULL_WIDTH = 96;
localparam int GF_FULL_HEIGHT = 96;
localparam int GF_FULL_LANES = 16;
localparam logic [31:0] GF_FULL_QUANT_FNV1A = 32'h%08X;
localparam int GF_FULL_PROBE_COUNT = %d;
""" % (fnv1a32(quantized), len(probes))
    svh_text += sv_array(q_input, "gf_full_input_q")
    svh_text += sv_array(weights, "gf_full_weights")
    def sv32(value: int) -> str:
        return f"-32'sd{-value}" if value < 0 else f"32'sd{value}"
    svh_text += "localparam logic signed [31:0] gf_full_folded_bias [0:15] = '{\n  " + ", ".join(sv32(int(value)) for value in folded_bias) + "\n};\n"
    svh_text += "localparam logic signed [31:0] gf_full_multiplier [0:15] = '{\n  " + ", ".join(sv32(int(value)) for value in multipliers) + "\n};\n"
    svh_text += "localparam logic [5:0] gf_full_right_shift [0:15] = '{\n  " + ", ".join(f"6'd{int(value)}" for value in right_shifts) + "\n};\n"
    svh_text += "localparam logic [15:0] gf_full_probe_y [0:%d] = '{\n  %s\n};\n" % (len(probes) - 1, ", ".join(f"16'd{int(row)}" for row, _ in probes))
    svh_text += "localparam logic [15:0] gf_full_probe_x [0:%d] = '{\n  %s\n};\n" % (len(probes) - 1, ", ".join(f"16'd{int(column)}" for _, column in probes))
    svh_text += "localparam logic signed [7:0] gf_full_probe_quant [0:%d][0:15] = '{\n" % (len(probes) - 1)
    svh_text += ",\n".join("  '{" + ", ".join((f"-8'sd{-int(value)}" if value < 0 else f"8'sd{int(value)}") for value in vector) + "}" for vector in probe_quant)
    svh_text += "\n};\n"
    args.svh_out.write_text(svh_text, encoding="ascii")

    print(f"Wrote {args.c_out.resolve()}")
    print(f"Wrote {args.svh_out.resolve()}")
    print("interpreter=tflite_runtime first_layer_tensor=%d" % output_index)
    print(f"input_quant=(scale={input_scale}, zero_point={input_zp})")
    print(f"output_quant=(scale={output_scale}, zero_point={output_zp})")
    print(f"folded_bias={folded_bias.tolist()}")
    print(f"quant_fnv1a=0x{fnv1a32(quantized):08X} raw_fnv1a=0x{fnv1a32(raw_folded.astype('<i4')):08X}")
    print(f"probes_yx={probes.tolist()}")


if __name__ == "__main__":
    main()
