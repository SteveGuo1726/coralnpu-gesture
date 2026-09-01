#!/usr/bin/env python3
"""Export a complete DMP full-layer golden for Verilator regression.

Unlike export_dmp_conv_layer.py, this tool emits everything a self-contained
full-layer testbench needs: the real layer input, DMP-packed weights, folded
bias, raw INT32 golden hash and a set of probe vectors.  It therefore proves
the whole DMP software/hardware data path against one real TFLite layer, not
just a synthetic packing identity.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from export_dmp_conv_layer import (
    fold_dmp_bias,
    pack_dmp_weights,
)


def fnv1a32(array: np.ndarray) -> int:
    value = 0x811C9DC5
    for byte in np.ascontiguousarray(array).view(np.uint8).reshape(-1):
        value = ((value ^ int(byte)) * 0x01000193) & 0xFFFFFFFF
    return value


def sv_signed8(value: int) -> str:
    return f"-8'sd{-int(value)}" if value < 0 else f"8'sd{int(value)}"


def sv_signed32(value: int) -> str:
    return f"-32'sd{-int(value)}" if value < 0 else f"32'sd{int(value)}"


def sv_uint32(value: int) -> str:
    return f"32'h{int(value) & 0xFFFFFFFF:08X}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--conv-index", type=int, default=1)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--svh-out", required=True, type=Path)
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    interpreter = Interpreter(
        model_path=str(args.model.resolve()), experimental_preserve_all_tensors=True
    )
    interpreter.allocate_tensors()
    model_input_detail = interpreter.get_input_details()[0]
    ops = interpreter._get_ops_details()  # pylint: disable=protected-access
    convs = [item for item in ops if item["op_name"] == "CONV_2D"]
    if not 0 <= args.conv_index < len(convs):
        raise SystemExit(f"conv-index {args.conv_index} is outside 0..{len(convs)-1}")
    conv = convs[args.conv_index]
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    input_detail = details[int(conv["inputs"][0])]
    weights = np.asarray(interpreter.get_tensor(conv["inputs"][1]), dtype=np.int8)
    bias = np.asarray(interpreter.get_tensor(conv["inputs"][2]), dtype=np.int32)
    output_lanes, kernel_height, kernel_width, real_input_channels = weights.shape
    if tuple(weights.shape[1:3]) not in ((4, 4), (1, 1)):
        raise SystemExit(f"Expected 4x4 or 1x1 CONV_2D weights, received {weights.shape}")
    if real_input_channels % 8:
        raise SystemExit("Golden full-layer test requires input channels divisible by 8")
    input_zp = int(input_detail["quantization"][1])
    pointwise = tuple(weights.shape[1:3]) == (1, 1)
    active_taps = 1 if pointwise else kernel_height * kernel_width
    padded_channels = real_input_channels
    padded = np.zeros((output_lanes, 16, padded_channels), dtype=np.int8)
    if pointwise:
        padded[:, 0, :] = weights[:, 0, 0, :]
    else:
        for tap in range(active_taps):
            ky, kx = divmod(tap, kernel_width)
            padded[:, tap, :] = weights[:, ky, kx, :]

    y, x, channel = np.indices((96, 96, 3))
    camera_rgb = ((y * 17 + x * 5 + channel * 29 + 37) & 0xFF).astype(np.uint8)
    q_input = (camera_rgb.astype(np.int16) - 128).astype(np.int8)
    interpreter.set_tensor(model_input_detail["index"], q_input[np.newaxis, ...])
    interpreter.invoke()
    layer_input = np.asarray(interpreter.get_tensor(input_detail["index"]), dtype=np.int8)[0]
    image_height, image_width, _ = layer_input.shape

    if pointwise:
        raw = np.broadcast_to(bias.astype(np.int64), (image_height, image_width, output_lanes)).copy()
        raw += np.tensordot(
            layer_input.astype(np.int64) - input_zp,
            weights[:, 0, 0, :].astype(np.int64),
            axes=([2], [1]),
        )
    else:
        padded_input = np.full(
            (image_height + 3, image_width + 3, padded_channels), input_zp, dtype=np.int8
        )
        padded_input[1 : image_height + 1, 1 : image_width + 1, :] = layer_input
        raw = np.broadcast_to(bias.astype(np.int64), (image_height, image_width, output_lanes)).copy()
        for tap in range(active_taps):
            ky, kx = divmod(tap, kernel_width)
            pixels = padded_input[
                ky : ky + image_height, kx : kx + image_width, :
            ].astype(np.int64)
            raw += np.tensordot(pixels - input_zp, padded[:, tap, :].astype(np.int64), axes=([2], [1]))
    if raw.min() < np.iinfo(np.int32).min or raw.max() > np.iinfo(np.int32).max:
        raise SystemExit("DMP full-layer raw accumulator exceeds INT32")

    packed = pack_dmp_weights(padded)
    folded_bias = fold_dmp_bias(padded, bias, input_zp, active_taps, real_input_channels)
    word_count = packed.size

    probes = np.asarray(
        [
            (0, 0),
            (0, image_width - 1),
            (1, 1),
            (image_height // 3, (image_width * 2) // 3),
            (image_height // 2, image_width // 2),
            (image_height - 1, 0),
            (image_height - 1, image_width - 1),
        ],
        dtype=np.uint16,
    )
    probe_raw = np.asarray([raw[row, column] for row, column in probes], dtype=np.int32)
    raw_fnv = fnv1a32(raw.astype("<i4"))
    tag_upper = args.tag.upper()

    def array_text(values: np.ndarray, formatter, columns: int = 12) -> str:
        flat = values.reshape(-1).tolist()
        rows = [
            "  " + ", ".join(formatter(int(item)) for item in flat[index : index + columns])
            for index in range(0, len(flat), columns)
        ]
        return ",\n".join(rows)

    text = f"""// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Generated by export_dmp_conv_golden.py. Do not hand edit.
localparam int GF_DMP_{tag_upper}_WIDTH = {image_width};
localparam int GF_DMP_{tag_upper}_HEIGHT = {image_height};
localparam int GF_DMP_{tag_upper}_INPUT_CHANNELS = {padded_channels};
localparam int GF_DMP_{tag_upper}_INPUT_GROUPS = {padded_channels // 8};
localparam int GF_DMP_{tag_upper}_OUTPUT_LANES = {output_lanes};
localparam int GF_DMP_{tag_upper}_ACTIVE_TAPS = {active_taps};
localparam int GF_DMP_{tag_upper}_INPUT_ZERO_POINT = {input_zp};
localparam int GF_DMP_{tag_upper}_WEIGHT_DMA_WORDS = {word_count};
localparam int GF_DMP_{tag_upper}_PROBE_COUNT = {len(probes)};
localparam logic [31:0] GF_DMP_{tag_upper}_RAW_FNV1A = 32'h{raw_fnv:08X};
"""
    text += (
        f"localparam logic signed [7:0] gf_dmp_{args.tag}_input_q [0:{image_height*image_width*padded_channels-1}] = '{{\n"
        + array_text(layer_input, sv_signed8)
        + "\n};\n"
    )
    text += (
        f"localparam logic [31:0] gf_dmp_{args.tag}_weights_dma [0:{word_count-1}] = '{{\n"
        + array_text(packed, sv_uint32)
        + "\n};\n"
    )
    text += (
        f"localparam logic signed [31:0] gf_dmp_{args.tag}_folded_bias [0:{output_lanes-1}] = '{{\n"
        + array_text(folded_bias, sv_signed32)
        + "\n};\n"
    )
    text += (
        f"localparam logic [15:0] gf_dmp_{args.tag}_probe_y [0:{len(probes)-1}] = '{{\n  "
        + ", ".join(f"16'd{int(row)}" for row, _ in probes)
        + "\n};\n"
    )
    text += (
        f"localparam logic [15:0] gf_dmp_{args.tag}_probe_x [0:{len(probes)-1}] = '{{\n  "
        + ", ".join(f"16'd{int(column)}" for _, column in probes)
        + "\n};\n"
    )
    text += (
        f"localparam logic signed [31:0] gf_dmp_{args.tag}_probe_raw "
        f"[0:{len(probes)-1}][0:{output_lanes-1}] = '{{\n"
    )
    text += ",\n".join(
        "  '{" + ", ".join(sv_signed32(int(value)) for value in vector) + "}"
        for vector in probe_raw
    )
    text += "\n};\n"

    args.svh_out.parent.mkdir(parents=True, exist_ok=True)
    args.svh_out.write_text(text, encoding="ascii")
    print(f"Wrote {args.svh_out.resolve()}")
    print(
        "DMP full-layer golden PASS "
        f"conv_index={args.conv_index} h={image_height} w={image_width} "
        f"cin={padded_channels} oc={output_lanes} taps={active_taps} "
        f"words={word_count} raw_fnv=0x{raw_fnv:08X}"
    )


if __name__ == "__main__":
    main()
