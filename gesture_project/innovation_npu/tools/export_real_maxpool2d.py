#!/usr/bin/env python3
"""Export a real TFLite MAX_POOL_2D tensor for GestureFlow-NPU.

This is project-local validation data.  It proves the pool result from the
actual INT8 TFLite interpreter before RTL is allowed to fuse pool and DDR
writeback.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np


def fnv1a32(array: np.ndarray) -> int:
    value = 0x811C9DC5
    for byte in np.ascontiguousarray(array).view(np.uint8).reshape(-1):
        value = ((value ^ int(byte)) * 0x01000193) & 0xFFFFFFFF
    return value


def c_array(values: np.ndarray, name: str, columns: int = 16) -> str:
    flat = values.reshape(-1).tolist()
    lines = [
        "    " + ", ".join(str(int(value)) for value in flat[index:index + columns])
        for index in range(0, len(flat), columns)
    ]
    return "static const int8_t %s[%d] = {\n%s\n};\n" % (name, len(flat), ",\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--c-out", required=True, type=Path)
    parser.add_argument("--svh-out", required=True, type=Path)
    parser.add_argument(
        "--pool-index", type=int, default=0,
        help="Zero-based MAX_POOL_2D operator index in TFLite execution order.",
    )
    parser.add_argument(
        "--prefix", default="GF_POOL",
        help="C/SV symbol prefix, for example GF_POOL2.",
    )
    parser.add_argument(
        "--include-input", action="store_true",
        help="Emit the real pool input as well as the output for DDR handoff checks.",
    )
    args = parser.parse_args()

    from tflite_runtime.interpreter import Interpreter  # pylint: disable=import-outside-toplevel

    # Keep the pool input tensor alive after invoke. Without this option the
    # TFLite arena may reuse conv output storage for later operators, making a
    # post-invoke software reference silently compare unrelated bytes.
    interpreter = Interpreter(
        model_path=str(args.model.resolve()), experimental_preserve_all_tensors=True
    )
    interpreter.allocate_tensors()
    details = {item["index"]: item for item in interpreter.get_tensor_details()}
    pool_ops = [op for op in interpreter._get_ops_details() if op["op_name"] == "MAX_POOL_2D"]  # pylint: disable=protected-access
    if not pool_ops:
        raise SystemExit("Model has no MAX_POOL_2D operator")
    if args.pool_index < 0 or args.pool_index >= len(pool_ops):
        raise SystemExit("pool-index %d is outside [0, %d)" % (args.pool_index, len(pool_ops)))
    pool = pool_ops[args.pool_index]
    source_detail = details[int(pool["inputs"][0])]
    output_detail = details[int(pool["outputs"][0])]
    source_shape = tuple(int(value) for value in source_detail["shape"])
    output_shape = tuple(int(value) for value in output_detail["shape"])
    if len(source_shape) != 4 or len(output_shape) != 4 or source_shape[0] != 1 or output_shape[0] != 1:
        raise SystemExit("Expected rank-4 batch-one pool tensors, got %s -> %s" % (source_shape, output_shape))
    if source_shape[1] != output_shape[1] * 2 or source_shape[2] != output_shape[2] * 2 or source_shape[3] != output_shape[3]:
        raise SystemExit("Expected 2x2 stride-2 channel-preserving pool, got %s -> %s" % (source_shape, output_shape))
    if source_detail["dtype"] != np.int8 or output_detail["dtype"] != np.int8:
        raise SystemExit("Expected INT8 pool tensors")
    if source_detail["quantization"] != output_detail["quantization"]:
        raise SystemExit("MAX_POOL_2D quantization changes; fusion needs requant support")

    y, x, channel = np.indices((96, 96, 3))
    camera_rgb = ((y * 17 + x * 5 + channel * 29 + 37) & 0xFF).astype(np.uint8)
    interpreter.set_tensor(interpreter.get_input_details()[0]["index"], (camera_rgb.astype(np.int16) - 128).astype(np.int8)[np.newaxis, ...])
    interpreter.invoke()
    source = np.asarray(interpreter.get_tensor(source_detail["index"]), dtype=np.int8)[0]
    pooled = np.asarray(interpreter.get_tensor(output_detail["index"]), dtype=np.int8)[0]
    input_height, input_width, channels = source.shape
    output_height, output_width, output_channels = pooled.shape
    reference = source.reshape(output_height, 2, output_width, 2, channels).max(axis=(1, 3))
    if not np.array_equal(reference, pooled):
        mismatch = np.argwhere(reference != pooled)[0]
        raise SystemExit("MAX_POOL_2D mismatch at %s" % mismatch.tolist())

    probes = np.asarray(
        [(0, 0), (0, output_width - 1), (1, 1), (output_height // 2, output_width // 2),
         (output_height - 1, 0), (output_height - 1, output_width - 1)], dtype=np.uint16
    )
    probe_values = np.asarray([pooled[row, col] for row, col in probes], dtype=np.int8)
    args.c_out.parent.mkdir(parents=True, exist_ok=True)
    args.svh_out.parent.mkdir(parents=True, exist_ok=True)
    guard = "%s_REAL_MAXPOOL2D_H" % args.prefix.upper()
    input_array = c_array(source, "%s_input" % args.prefix.lower()) if args.include_input else ""
    c_text = """/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* Generated by export_real_maxpool2d.py. Do not hand edit. */
#ifndef %s
#define %s
#include <stdint.h>
#define %s_INPUT_WIDTH %dU
#define %s_INPUT_HEIGHT %dU
#define %s_OUTPUT_WIDTH %dU
#define %s_OUTPUT_HEIGHT %dU
#define %s_CHANNELS %dU
#define %s_INPUT_BYTES %dU
#define %s_OUTPUT_BYTES %dU
#define %s_INPUT_FNV1A 0x%08XU
#define %s_OUTPUT_FNV1A 0x%08XU
%s%s
#endif
""" % (
        guard, guard, args.prefix, input_width, args.prefix, input_height, args.prefix, output_width,
        args.prefix, output_height, args.prefix, channels, args.prefix, source.nbytes, args.prefix,
        pooled.nbytes, args.prefix, fnv1a32(source), args.prefix, fnv1a32(pooled), input_array,
        c_array(pooled, "%s_output" % args.prefix.lower()),
    )
    args.c_out.write_text(c_text, encoding="ascii")

    signed = lambda value: "-8'sd%d" % -int(value) if value < 0 else "8'sd%d" % int(value)
    flat = pooled.reshape(-1)
    sv_rows = [
        "  " + ", ".join(signed(value) for value in flat[index:index + 16])
        for index in range(0, len(flat), 16)
    ]
    svh_text = """// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
// Generated by export_real_maxpool2d.py. Do not hand edit.
localparam int %s_INPUT_WIDTH = %d;
localparam int %s_INPUT_HEIGHT = %d;
localparam int %s_OUTPUT_WIDTH = %d;
localparam int %s_OUTPUT_HEIGHT = %d;
localparam int %s_LANES = %d;
localparam logic [31:0] %s_INPUT_FNV1A = 32'h%08X;
localparam logic [31:0] %s_OUTPUT_FNV1A = 32'h%08X;
localparam logic signed [7:0] %s_output_q [0:%d] = '{
  %s
};
""" % (
        args.prefix, input_width, args.prefix, input_height, args.prefix, output_width, args.prefix,
        output_height, args.prefix, channels, args.prefix, fnv1a32(source), args.prefix,
        fnv1a32(pooled), args.prefix.lower(), len(flat) - 1, ",\n".join(sv_rows),
    )
    args.svh_out.write_text(svh_text, encoding="ascii")
    print("MAXPOOL_EXPORT_PASS input_fnv1a=0x%08X output_fnv1a=0x%08X bytes=%d" % (fnv1a32(source), fnv1a32(pooled), pooled.nbytes))
    print("input_quant=%s output_quant=%s probes=%s" % (source_detail["quantization"], output_detail["quantization"], probes.tolist()))


if __name__ == "__main__":
    main()
