#!/usr/bin/env python3
"""Export DMP (Dual-Multiply Packing) convolution weights and folded bias.

This tool is the software half of GestureFlow-NPU's DMP data path.  It reads a
TFLite CONV_2D, pads input channels to a multiple of eight, packs every pair
of output-channel weights into 24-bit DSP A operands, and folds the signed
INT8 offset corrections into one INT32 bias per output channel.

The emitted packed word for output channels (2p, 2p+1) and input lane ci is:

    A_word[ci] = ((w[2p+1,ci] + 128) << 16) | (w[2p,ci] + 128)

Six 32-bit words store eight 24-bit A_words contiguously, matching the 192-bit
DMP weight-bank word.  The folded bias identity is:

    sum((q - zp) * w) + b
  = sum((q + 128) * (w + 128)) - 128*sum(q)
    + (b - (zp + 128)*sum(w) - 16384*N)

where N is the number of products per output channel (active taps times real
input channels).  This script validates that identity on randomized data
before writing any generated file.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np


def int8_unsigned(value: int) -> int:
    """Return the unsigned byte image of a signed INT8 value."""
    return int(np.uint8(np.int8(value)))


def pack_word(w_even: int, w_odd: int) -> int:
    """Pack two signed INT8 weights into one positive 24-bit DSP A word."""
    return (int8_unsigned(w_odd) << 16) | int8_unsigned(w_even)


def pack_dmp_weights(weights: np.ndarray, input_lanes: int = 8) -> np.ndarray:
    """Pack an (OC, taps, padded_C) weight tensor into six 32-bit words per
    (output pair, tap, eight-channel group).

    Parameters
    ----------
    weights:
        Shape ``(OC, taps, padded_C)``, where ``padded_C`` is a multiple of
        ``input_lanes``.  Missing input channels must already be zero.

    Returns
    -------
    np.ndarray of dtype uint32 and shape ``(OC//2, taps, groups, 6)``.
    """
    output_lanes, taps, padded_channels = weights.shape
    if output_lanes % 2:
        raise ValueError("DMP requires an even number of output lanes")
    if padded_channels % input_lanes:
        raise ValueError("padded input channels must be a multiple of input_lanes")
    groups = padded_channels // input_lanes
    pairs = output_lanes // 2
    packed = np.zeros((pairs, taps, groups, 6), dtype=np.uint32)
    for pair in range(pairs):
        for tap in range(taps):
            for group in range(groups):
                words = [0, 0, 0, 0, 0, 0]
                for lane in range(input_lanes):
                    ci = group * input_lanes + lane
                    w_even = int(weights[2 * pair, tap, ci])
                    w_odd = int(weights[2 * pair + 1, tap, ci])
                    value = pack_word(w_even, w_odd)
                    bit_offset = lane * 24
                    word_index = bit_offset // 32
                    shift = bit_offset % 32
                    words[word_index] = (words[word_index] | (value << shift)) & 0xFFFFFFFF
                    if shift + 24 > 32:
                        words[word_index + 1] = (
                            words[word_index + 1] | (value >> (32 - shift))
                        ) & 0xFFFFFFFF
                packed[pair, tap, group] = np.asarray(words, dtype=np.uint32)
    return packed


def fold_dmp_bias(
    weights: np.ndarray,
    bias: np.ndarray,
    input_zero_point: int,
    active_taps: int,
    real_input_channels: int,
) -> np.ndarray:
    """Fold the DMP weight and bias offset corrections into INT32 biases."""
    output_lanes = weights.shape[0]
    sum_w = weights[:, :active_taps, :real_input_channels].astype(np.int64).sum(axis=(1, 2))
    product_count = active_taps * real_input_channels
    folded = (
        bias.astype(np.int64)
        - (int(input_zero_point) + 128) * sum_w
        - 16384 * product_count
    )
    if folded.min() < np.iinfo(np.int32).min or folded.max() > np.iinfo(np.int32).max:
        raise SystemExit("DMP folded bias exceeds INT32 range")
    return folded.astype(np.int32)


def validate_identity(
    weights: np.ndarray,
    bias: np.ndarray,
    input_zero_point: int,
    active_taps: int,
    real_input_channels: int,
) -> None:
    """Prove the DMP offset identity on deterministic pseudo-random data."""
    rng = np.random.default_rng(20260901)
    output_lanes, taps, padded_channels = weights.shape
    if active_taps > taps or real_input_channels > padded_channels:
        raise ValueError("active taps/channels exceed padded tensor")
    q = rng.integers(-128, 128, size=(active_taps, real_input_channels), dtype=np.int64)
    w = weights[:, :active_taps, :real_input_channels].astype(np.int64)
    folded = fold_dmp_bias(weights, bias, input_zero_point, active_taps, real_input_channels)
    reference = (q - input_zero_point).reshape(-1) @ w.reshape(output_lanes, -1).T + bias.astype(np.int64)
    dmp = ((q + 128).reshape(-1) @ (w + 128).reshape(output_lanes, -1).T
           - 128 * int(q.sum())
           + folded.astype(np.int64))
    if not np.array_equal(reference, dmp):
        raise SystemExit("DMP bias/packing identity validation failed")


def c_array(values: np.ndarray, c_type: str, name: str, columns: int = 16) -> str:
    flat = values.reshape(-1).tolist()
    rows = [
        "    " + ", ".join(str(int(item)) for item in flat[index : index + columns])
        for index in range(0, len(flat), columns)
    ]
    return f"static const {c_type} {name}[{len(flat)}] = {{\n" + ",\n".join(rows) + "\n};\n"


def sv32(value: int) -> str:
    return f"-32'sd{-int(value)}" if value < 0 else f"32'sd{int(value)}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--conv-index", type=int, default=0)
    parser.add_argument("--tag", default="full", help="C/SV symbol tag.")
    parser.add_argument("--c-out", required=True, type=Path)
    parser.add_argument("--svh-out", required=True, type=Path)
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    interpreter = Interpreter(model_path=str(args.model.resolve()))
    interpreter.allocate_tensors()
    ops = interpreter._get_ops_details()  # pylint: disable=protected-access
    convs = [item for item in ops if item["op_name"] == "CONV_2D"]
    if not 0 <= args.conv_index < len(convs):
        raise SystemExit(f"conv-index {args.conv_index} is outside 0..{len(convs)-1}")
    conv = convs[args.conv_index]
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    weights = np.asarray(interpreter.get_tensor(conv["inputs"][1]), dtype=np.int8)
    bias = np.asarray(interpreter.get_tensor(conv["inputs"][2]), dtype=np.int32)
    input_detail = details[int(conv["inputs"][0])]
    output_lanes, kernel_height, kernel_width, real_input_channels = weights.shape
    if tuple(weights.shape[1:3]) not in ((4, 4), (1, 1)):
        raise SystemExit(f"Expected 4x4 or 1x1 CONV_2D weights, received {weights.shape}")
    input_zp = int(input_detail["quantization"][1])

    pointwise = tuple(weights.shape[1:3]) == (1, 1)
    padded_channels = ((real_input_channels + 7) // 8) * 8
    active_taps = 1 if pointwise else kernel_height * kernel_width
    padded = np.zeros((output_lanes, 16, padded_channels), dtype=np.int8)
    if pointwise:
        padded[:, 0, :real_input_channels] = weights[:, 0, 0, :]
    else:
        for tap in range(active_taps):
            ky, kx = divmod(tap, kernel_width)
            padded[:, tap, :real_input_channels] = weights[:, ky, kx, :]

    validate_identity(padded, bias, input_zp, active_taps, real_input_channels)
    packed = pack_dmp_weights(padded)
    folded_bias = fold_dmp_bias(padded, bias, input_zp, active_taps, real_input_channels)
    pairs, _, groups, words_per_entry = packed.shape
    word_count = packed.size

    tag_upper = args.tag.upper()
    c_text = f"""/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated by export_dmp_conv_layer.py. Do not hand edit. */
#ifndef GESTUREFLOW_DMP_{tag_upper}_LAYER_H
#define GESTUREFLOW_DMP_{tag_upper}_LAYER_H
#include <stdint.h>
#define GF_DMP_{tag_upper}_REAL_INPUT_CHANNELS {real_input_channels}U
#define GF_DMP_{tag_upper}_PADDED_INPUT_CHANNELS {padded_channels}U
#define GF_DMP_{tag_upper}_INPUT_GROUPS {groups}U
#define GF_DMP_{tag_upper}_OUTPUT_LANES {output_lanes}U
#define GF_DMP_{tag_upper}_OUTPUT_PAIRS {pairs}U
#define GF_DMP_{tag_upper}_ACTIVE_TAPS {active_taps}U
#define GF_DMP_{tag_upper}_WEIGHT_WORDS_PER_ENTRY {words_per_entry}U
#define GF_DMP_{tag_upper}_INPUT_ZERO_POINT {input_zp}

"""
    c_text += c_array(packed, "uint32_t", f"gf_dmp_{args.tag}_weights_dma")
    c_text += c_array(folded_bias, "int32_t", f"gf_dmp_{args.tag}_folded_bias")
    c_text += f"\n#endif\n"

    args.c_out.parent.mkdir(parents=True, exist_ok=True)
    args.svh_out.parent.mkdir(parents=True, exist_ok=True)
    args.c_out.write_text(c_text, encoding="ascii")

    svh = f"""// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Generated by export_dmp_conv_layer.py. Do not hand edit.
localparam int GF_DMP_{tag_upper}_REAL_INPUT_CHANNELS = {real_input_channels};
localparam int GF_DMP_{tag_upper}_PADDED_INPUT_CHANNELS = {padded_channels};
localparam int GF_DMP_{tag_upper}_INPUT_GROUPS = {groups};
localparam int GF_DMP_{tag_upper}_OUTPUT_LANES = {output_lanes};
localparam int GF_DMP_{tag_upper}_OUTPUT_PAIRS = {pairs};
localparam int GF_DMP_{tag_upper}_ACTIVE_TAPS = {active_taps};
localparam int GF_DMP_{tag_upper}_WEIGHT_DMA_WORDS = {word_count};
localparam logic signed [31:0] gf_dmp_{args.tag}_folded_bias [0:{output_lanes-1}] = '{{
  """ + ", ".join(sv32(int(value)) for value in folded_bias) + """
};
"""
    args.svh_out.write_text(svh, encoding="ascii")

    print(f"Wrote {args.c_out.resolve()}")
    print(f"Wrote {args.svh_out.resolve()}")
    print(
        "DMP export PASS "
        f"conv_index={args.conv_index} oc={output_lanes} taps={active_taps} "
        f"cin={real_input_channels} padded_cin={padded_channels} pairs={pairs} "
        f"words={word_count} input_zp={input_zp}"
    )


if __name__ == "__main__":
    main()
