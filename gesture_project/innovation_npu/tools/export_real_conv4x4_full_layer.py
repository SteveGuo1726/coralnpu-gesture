#!/usr/bin/env python3
"""Export a real full 4x4 TFLite convolution golden for GestureFlow-NPU.

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
    # This model's exported convolution tensors are fused with ReLU, so their
    # quantized floor is the output zero point.
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
    parser.add_argument(
        "--conv-index", type=int, default=0,
        help="Zero-based CONV_2D ordinal to export (default: first convolution).",
    )
    parser.add_argument(
        "--tag", default="full",
        help="C symbol tag; use a distinct tag when exporting another layer.",
    )
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    # Later tensors can reuse an earlier activation's arena allocation.  A
    # layer beyond conv1 must therefore preserve intermediates before reading
    # its real DDR-equivalent input and golden output.
    interpreter = Interpreter(
        model_path=str(args.model.resolve()), experimental_preserve_all_tensors=True
    )
    interpreter.allocate_tensors()
    model_input_detail = interpreter.get_input_details()[0]
    if tuple(model_input_detail["shape"]) != (1, 96, 96, 3) or model_input_detail["dtype"] != np.int8:
        raise SystemExit(f"Unexpected model input: {model_input_detail}")
    ops = interpreter._get_ops_details()  # pylint: disable=protected-access
    convs = [item for item in ops if item["op_name"] == "CONV_2D"]
    if not 0 <= args.conv_index < len(convs):
        raise SystemExit(f"conv-index {args.conv_index} is outside 0..{len(convs) - 1}")
    conv = convs[args.conv_index]
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    input_detail = details[int(conv["inputs"][0])]
    weights = np.asarray(interpreter.get_tensor(conv["inputs"][1]), dtype=np.int8)
    bias = np.asarray(interpreter.get_tensor(conv["inputs"][2]), dtype=np.int32)
    output_index = int(conv["outputs"][0])
    output_detail = details[output_index]
    if len(weights.shape) != 4 or tuple(weights.shape[1:3]) != (4, 4):
        raise SystemExit(f"Expected 4x4 CONV_2D weights, received {weights.shape}")
    output_lanes, kernel_height, kernel_width, input_channels = weights.shape
    input_shape = tuple(int(item) for item in input_detail["shape"])
    output_shape = tuple(int(item) for item in output_detail["shape"])
    if input_shape[0] != 1 or output_shape[0] != 1 or input_shape[1:3] != output_shape[1:3]:
        raise SystemExit(f"Only stride-1 SAME tensors are supported: {input_shape} -> {output_shape}")
    image_height, image_width = input_shape[1:3]
    if input_shape[3] != input_channels or output_shape[3] != output_lanes:
        raise SystemExit(f"Tensor/channel mismatch {input_shape}, {weights.shape}, {output_shape}")

    input_scale, input_zp = input_detail["quantization"]
    output_scale, output_zp = output_detail["quantization"]
    input_zp = int(input_zp)
    output_zp = int(output_zp)
    weight_scales = details[conv["inputs"][1]]["quantization_parameters"]["scales"]

    # A deterministic full-range camera payload drives the model. For later
    # convolutions, the interpreter provides the preceding quantized tensor;
    # that is precisely the feature-map format a future DDR/BRAM handoff sees.
    y, x, channel = np.indices((96, 96, 3))
    camera_rgb = ((y * 17 + x * 5 + channel * 29 + 37) & 0xFF).astype(np.uint8)
    q_input = (camera_rgb.astype(np.int16) - 128).astype(np.int8)
    interpreter.set_tensor(model_input_detail["index"], q_input[np.newaxis, ...])
    interpreter.invoke()
    layer_input = np.asarray(interpreter.get_tensor(input_detail["index"]), dtype=np.int8)[0]
    tflite_output = np.asarray(interpreter.get_tensor(output_index), dtype=np.int8)[0]

    padded = np.full((image_height + 3, image_width + 3, input_channels), input_zp, dtype=np.int8)
    padded[1:image_height + 1, 1:image_width + 1, :] = layer_input
    raw_standard = np.broadcast_to(bias.astype(np.int64), (image_height, image_width, output_lanes)).copy()
    raw_folded = np.broadcast_to(
        (bias.astype(np.int64) - input_zp * weights.astype(np.int64).sum(axis=(1, 2, 3))),
        (image_height, image_width, output_lanes),
    ).copy()
    for kernel_y in range(kernel_height):
        for kernel_x in range(kernel_width):
            pixels = padded[kernel_y : kernel_y + image_height, kernel_x : kernel_x + image_width, :].astype(np.int64)
            kernel = weights[:, kernel_y, kernel_x, :].astype(np.int64)
            raw_standard += np.tensordot(pixels - input_zp, kernel, axes=([2], [1]))
            raw_folded += np.tensordot(pixels, kernel, axes=([2], [1]))
    if not np.array_equal(raw_standard, raw_folded):
        raise SystemExit("Folded-bias proof failed: raw INT32 tensors differ")
    if raw_folded.min() < np.iinfo(np.int32).min or raw_folded.max() > np.iinfo(np.int32).max:
        raise SystemExit("Folded convolution accumulator exceeds INT32")

    multipliers = np.empty(output_lanes, dtype=np.int32)
    right_shifts = np.empty(output_lanes, dtype=np.uint8)
    quantized = np.empty_like(tflite_output)
    for lane in range(output_lanes):
        multiplier, shift = quantize_multiplier(float(input_scale) * float(weight_scales[lane]) / float(output_scale))
        if shift > 0 or -shift > 31:
            raise SystemExit(f"Unsupported convolution requant shift {shift} for lane {lane}")
        multipliers[lane] = multiplier
        right_shifts[lane] = -shift
        for row in range(image_height):
            for column in range(image_width):
                quantized[row, column, lane] = np.int8(
                    requantize(int(raw_folded[row, column, lane]), multiplier, shift, output_zp)
                )
    if not np.array_equal(quantized, tflite_output):
        mismatch = np.argwhere(quantized != tflite_output)[0]
        raise SystemExit(
            "TFLite convolution requant mismatch at "
            f"{mismatch.tolist()}: generated={int(quantized[tuple(mismatch)])} "
            f"tflite={int(tflite_output[tuple(mismatch)])}"
        )

    folded_bias = (bias.astype(np.int64) - input_zp * weights.astype(np.int64).sum(axis=(1, 2, 3))).astype(np.int32)
    # Preserve the original first-layer probe coordinates so recreating the
    # committed HP0 baseline does not create irrelevant golden churn.
    if args.conv_index == 0 and (image_height, image_width) == (96, 96):
        probes = np.asarray([(0, 0), (0, 95), (1, 1), (31, 63), (48, 48), (95, 0), (95, 95)], dtype=np.uint16)
    else:
        probes = np.asarray([
            (0, 0), (0, image_width - 1), (1, 1),
            (image_height // 3, (image_width * 2) // 3),
            (image_height // 2, image_width // 2),
            (image_height - 1, 0), (image_height - 1, image_width - 1),
        ], dtype=np.uint16)
    probe_quant = np.asarray([quantized[row, column] for row, column in probes], dtype=np.int8)
    probe_raw = np.asarray([raw_folded[row, column] for row, column in probes], dtype=np.int32)

    args.c_out.parent.mkdir(parents=True, exist_ok=True)
    args.svh_out.parent.mkdir(parents=True, exist_ok=True)
    c_text = """/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated by export_real_conv4x4_full_layer.py. Do not hand edit. */
#ifndef GESTUREFLOW_REAL_CONV4X4_FULL_LAYER_H
#define GESTUREFLOW_REAL_CONV4X4_FULL_LAYER_H
#include <stdint.h>
#define GF_FULL_IMAGE_WIDTH %dU
#define GF_FULL_IMAGE_HEIGHT %dU
#define GF_FULL_INPUT_CHANNELS %dU
#define GF_FULL_OUTPUT_LANES %dU
#define GF_FULL_INPUT_ZERO_POINT %d
#define GF_FULL_OUTPUT_ZERO_POINT %d
#define GF_FULL_OUTPUT_FNV1A 0x%08XU
#define GF_FULL_RAW_FNV1A 0x%08XU
\n""" % (image_width, image_height, input_channels, output_lanes, input_zp, output_zp, fnv1a32(quantized), fnv1a32(raw_folded.astype('<i4')))
    if args.conv_index == 0:
        c_text += c_array(camera_rgb, "uint8_t", "gf_full_camera_rgb")
    else:
        c_text += c_array(layer_input, "int8_t", "gf_full_layer_input")
    c_text += c_array(weights, "int8_t", "gf_full_weights")
    c_text += c_array(bias, "int32_t", "gf_full_original_bias")
    c_text += c_array(folded_bias, "int32_t", "gf_full_folded_bias")
    c_text += c_array(multipliers, "int32_t", "gf_full_requant_multiplier")
    c_text += c_array(right_shifts, "uint8_t", "gf_full_requant_right_shift")
    c_text += c_array(probes, "uint16_t", "gf_full_probe_yx", columns=14)
    c_text += c_array(probe_raw, "int32_t", "gf_full_probe_raw")
    c_text += c_array(probe_quant, "int8_t", "gf_full_probe_quant")
    c_text += "\n#endif\n"
    # Keep generated layers linkable in one ARM application. The original
    # baseline deliberately retains the historical gf_full_* names; later
    # layers receive an explicit tag instead of colliding silently.
    if args.tag != "full":
        macro_tag = args.tag.upper()
        c_text = c_text.replace("GESTUREFLOW_REAL_CONV4X4_FULL_LAYER_H", f"GESTUREFLOW_REAL_CONV4X4_{macro_tag}_LAYER_H")
        c_text = c_text.replace("GF_FULL", f"GF_{macro_tag}")
        c_text = c_text.replace("gf_full", f"gf_{args.tag}")
    args.c_out.write_text(c_text, encoding="ascii")

    svh_text = """// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Generated by export_real_conv4x4_full_layer.py. Do not hand edit.
localparam int GF_FULL_WIDTH = %d;
localparam int GF_FULL_HEIGHT = %d;
localparam int GF_FULL_LANES = %d;
localparam logic [31:0] GF_FULL_QUANT_FNV1A = 32'h%08X;
localparam int GF_FULL_PROBE_COUNT = %d;
""" % (image_width, image_height, output_lanes, fnv1a32(quantized), len(probes))
    if args.conv_index != 0:
        svh_text = svh_text.replace(
            f"localparam int GF_FULL_LANES = {output_lanes};\n",
            f"localparam int GF_FULL_INPUT_CHANNELS = {input_channels};\n"
            f"localparam int GF_FULL_LANES = {output_lanes};\n",
        )
    svh_text += sv_array(layer_input, "gf_full_input_q")
    svh_text += sv_array(weights, "gf_full_weights")
    if args.tag != "full":
        svh_text += sv_array(quantized, f"gf_{args.tag}_output_q")
    def sv32(value: int) -> str:
        return f"-32'sd{-value}" if value < 0 else f"32'sd{value}"
    svh_text += "localparam logic signed [31:0] gf_full_folded_bias [0:%d] = '{\n  " % (output_lanes - 1) + ", ".join(sv32(int(value)) for value in folded_bias) + "\n};\n"
    svh_text += "localparam logic signed [31:0] gf_full_multiplier [0:%d] = '{\n  " % (output_lanes - 1) + ", ".join(sv32(int(value)) for value in multipliers) + "\n};\n"
    svh_text += "localparam logic [5:0] gf_full_right_shift [0:%d] = '{\n  " % (output_lanes - 1) + ", ".join(f"6'd{int(value)}" for value in right_shifts) + "\n};\n"
    svh_text += "localparam logic [15:0] gf_full_probe_y [0:%d] = '{\n  %s\n};\n" % (len(probes) - 1, ", ".join(f"16'd{int(row)}" for row, _ in probes))
    svh_text += "localparam logic [15:0] gf_full_probe_x [0:%d] = '{\n  %s\n};\n" % (len(probes) - 1, ", ".join(f"16'd{int(column)}" for _, column in probes))
    svh_text += "localparam logic signed [7:0] gf_full_probe_quant [0:%d][0:%d] = '{\n" % (len(probes) - 1, output_lanes - 1)
    svh_text += ",\n".join("  '{" + ", ".join((f"-8'sd{-int(value)}" if value < 0 else f"8'sd{int(value)}") for value in vector) + "}" for vector in probe_quant)
    svh_text += "\n};\n"
    if args.tag != "full":
        svh_text = svh_text.replace("GF_FULL", f"GF_{args.tag.upper()}")
        svh_text = svh_text.replace("gf_full", f"gf_{args.tag}")
    args.svh_out.write_text(svh_text, encoding="ascii")

    print(f"Wrote {args.c_out.resolve()}")
    print(f"Wrote {args.svh_out.resolve()}")
    print("interpreter=tflite_runtime conv_index=%d tensor=%d" % (args.conv_index, output_index))
    print(f"input_quant=(scale={input_scale}, zero_point={input_zp})")
    print(f"output_quant=(scale={output_scale}, zero_point={output_zp})")
    print(f"folded_bias={folded_bias.tolist()}")
    print(f"quant_fnv1a=0x{fnv1a32(quantized):08X} raw_fnv1a=0x{fnv1a32(raw_folded.astype('<i4')):08X}")
    print(f"probes_yx={probes.tolist()}")


if __name__ == "__main__":
    main()
