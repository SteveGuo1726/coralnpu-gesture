#!/usr/bin/env python3
"""Run a real quantized 3x3 layer across multiple output rows on-board via ARM baremetal."""

from __future__ import annotations

import argparse
import time
import zlib
from pathlib import Path

import numpy as np

from run_win3_real_layer_fragment import (
    DEFAULT_IMAGE,
    DEFAULT_MODEL,
    build_run_payload,
    load_interpreter,
    load_quantized_input,
    parse_output_channels,
)
from run_win3_real_layer_fragment_arm import (
    MEMORY_PROFILES,
    execute_payloads_chunked,
    fnv1a_hash_int32_row,
)


def log(line: str) -> None:
    print(line, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a real quantized 3x3 layer across multiple output rows on WIN3 via ARM baremetal."
    )
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL, help="INT8 TFLite model path.")
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE, help="Input RGB image path.")
    parser.add_argument(
        "--layer",
        choices=["conv2_3x3_a", "conv2_3x3_b", "conv3_3x3_a", "conv3_3x3_b"],
        default="conv2_3x3_b",
        help="Target 3x3 layer name.",
    )
    parser.add_argument("--output_channel", type=int, default=0, help="Output channel index to replay.")
    parser.add_argument(
        "--output_channels",
        type=str,
        default="",
        help="Comma-separated output channel list. If set, it overrides --output_channel.",
    )
    parser.add_argument(
        "--memory-profile",
        choices=sorted(MEMORY_PROFILES),
        default="ocm",
        help="Execution memory profile.",
    )
    parser.add_argument(
        "--readback-mode",
        choices=["full", "summary"],
        default="summary",
        help="summary is faster for large layer sweeps; full reads back every int32 result.",
    )
    parser.add_argument(
        "--xsdb-retries",
        type=int,
        default=2,
        help="Retry count for transient XSDB/DAP transport failures.",
    )
    parser.add_argument("--row-start", type=int, default=0, help="Inclusive output row start.")
    parser.add_argument("--row-end", type=int, default=-1, help="Inclusive output row end. -1 means last row.")
    parser.add_argument(
        "--full-layer",
        action="store_true",
        help="Sweep all rows of the target output feature map.",
    )
    return parser.parse_args()


def summary_digest(row_summaries: list[dict]) -> int:
    digest = 0
    for entry in row_summaries:
        packed = np.asarray(
            [
                entry["int32_hash"],
                entry["int32_sum"] & 0xFFFFFFFF,
                entry["int32_min"] & 0xFFFFFFFF,
                entry["int32_max"] & 0xFFFFFFFF,
            ],
            dtype=np.uint32,
        )
        digest = zlib.crc32(packed.tobytes(), digest)
    return digest & 0xFFFFFFFF


def determine_rows(args: argparse.Namespace, output_height: int) -> list[int]:
    if args.full_layer:
        return list(range(output_height))

    row_end = args.row_end
    if row_end < 0:
        row_end = output_height - 1
    if not (0 <= args.row_start < output_height):
        raise ValueError(f"row-start out of range: {args.row_start}, output_height={output_height}")
    if not (args.row_start <= row_end < output_height):
        raise ValueError(f"row-end out of range: {row_end}, output_height={output_height}")
    return list(range(args.row_start, row_end + 1))


def build_payloads_for_row(interpreter, image_q: np.ndarray, layer_name: str, output_channels: list[int], output_row: int):
    payloads = []
    for output_channel in output_channels:
        payloads.append(
            build_run_payload(
                interpreter=interpreter,
                layer_name=layer_name,
                image_q=image_q,
                output_channel=output_channel,
                output_row=output_row,
                start_col=0,
                full_row=True,
            )
        )
    return payloads


def validate_payload_results(payloads: list[dict], chunk_results: list[dict], readback_mode: str) -> tuple[int, int]:
    if readback_mode == "summary":
        board_row_summaries = []
        for chunk in chunk_results:
            board_row_summaries.extend(chunk["board_row_summaries"])
        for index, payload in enumerate(payloads):
            expected_row = payload["final_row_int32"]
            expected_summary = {
                "int32_hash": fnv1a_hash_int32_row(expected_row),
                "int32_sum": sum(expected_row),
                "int32_min": min(expected_row),
                "int32_max": max(expected_row),
            }
            if board_row_summaries[index] != expected_summary:
                raise RuntimeError(
                    "Board summary mismatch.\n"
                    f"output_row={payload['output_row']}\n"
                    f"output_channel={payload['output_channel']}\n"
                    f"board={board_row_summaries[index]}\n"
                    f"golden={expected_summary}\n"
                )
        return summary_digest(board_row_summaries), len(board_row_summaries)

    board_rows_int32 = []
    board_rows_int8_q = []
    for chunk in chunk_results:
        board_rows_int32.extend(chunk["board_rows_int32"])
        board_rows_int8_q.extend(chunk["board_rows_int8_q"])
    for index, payload in enumerate(payloads):
        board_row_int32 = board_rows_int32[index]
        board_row_int8_q = board_rows_int8_q[index]
        if board_row_int32 != payload["final_row_int32"]:
            raise RuntimeError(
                "Board int32 row mismatch.\n"
                f"output_row={payload['output_row']}\n"
                f"output_channel={payload['output_channel']}\n"
            )
        if board_row_int8_q != payload["final_row_int8_q"]:
            raise RuntimeError(
                "Board requant row mismatch.\n"
                f"output_row={payload['output_row']}\n"
                f"output_channel={payload['output_channel']}\n"
            )
    digest = zlib.crc32(np.asarray(board_rows_int32, dtype=np.int32).tobytes()) & 0xFFFFFFFF
    return digest, len(board_rows_int32)


def main() -> None:
    args = parse_args()
    profile = MEMORY_PROFILES[args.memory_profile]
    interpreter = load_interpreter(args.model)
    image_q = load_quantized_input(args.image)
    output_channels = parse_output_channels(args)

    probe_payload = build_payloads_for_row(
        interpreter=interpreter,
        image_q=image_q,
        layer_name=args.layer,
        output_channels=[output_channels[0]],
        output_row=0,
    )[0]
    output_height = probe_payload["output_shape"][0]
    output_width = probe_payload["output_shape"][1]
    rows = determine_rows(args, output_height)

    log(f"LAYER {args.layer}")
    log(f"IMAGE {args.image}")
    log(f"OUTPUT_CHANNELS {output_channels}")
    log(f"ROWS {rows[0]}..{rows[-1]} COUNT={len(rows)}")
    log(f"OUTPUT_SHAPE {probe_payload['output_shape']}")
    log(f"ARM_MEMORY_PROFILE {profile.name}")
    log(f"ARM_READBACK_MODE {args.readback_mode}")
    log(f"ARM_LOAD_ADDR 0x{profile.load_addr:08X}")
    log(f"ARM_MAILBOX_BASE 0x{profile.mailbox_base:08X}")
    log(f"ARM_STACK_ADDR 0x{profile.stack_addr:08X}")

    total_start = time.perf_counter()
    layer_digest = 0
    total_cases = 0
    max_program_bytes = 0
    total_chunk_count = 0
    for row in rows:
        row_start = time.perf_counter()
        payloads = build_payloads_for_row(
            interpreter=interpreter,
            image_q=image_q,
            layer_name=args.layer,
            output_channels=output_channels,
            output_row=row,
        )
        chunk_results = execute_payloads_chunked(
            payloads,
            xsdb_retries=args.xsdb_retries,
            profile=profile,
            readback_mode=args.readback_mode,
        )
        digest, validated_items = validate_payload_results(payloads, chunk_results, args.readback_mode)
        chunk_program_sizes = [chunk["program_size"] for chunk in chunk_results]
        chunk_statuses = [chunk["mailbox"][15] for chunk in chunk_results]
        total_cases += sum(chunk["mailbox"][10] for chunk in chunk_results)
        total_chunk_count += len(chunk_results)
        max_program_bytes = max(max_program_bytes, max(chunk_program_sizes))
        layer_digest = zlib.crc32(np.asarray([row, digest], dtype=np.uint32).tobytes(), layer_digest) & 0xFFFFFFFF
        elapsed_s = time.perf_counter() - row_start
        log(
            f"ROW {row} PASS "
            f"ELAPSED_S={elapsed_s:.2f} "
            f"CHUNKS={len(chunk_results)} "
            f"PROGRAM_BYTES_MAX={max(chunk_program_sizes)} "
            f"CASES={sum(chunk['mailbox'][10] for chunk in chunk_results)} "
            f"STATUS_LIST={[f'0x{status:08X}' for status in chunk_statuses]} "
            f"VALIDATED_ITEMS={validated_items} "
            f"ROW_DIGEST=0x{digest:08X}"
        )

    total_elapsed_s = time.perf_counter() - total_start
    log(
        "WIN3_REAL_LAYER_ARM_ROW_SWEEP_PASS "
        f"LAYER={args.layer} "
        f"ROWS={len(rows)} "
        f"ROW_WIDTH={output_width} "
        f"CHANNELS={len(output_channels)} "
        f"TOTAL_CHUNKS={total_chunk_count} "
        f"TOTAL_CASES={total_cases} "
        f"PROGRAM_BYTES_MAX={max_program_bytes} "
        f"LAYER_DIGEST=0x{layer_digest:08X} "
        f"TOTAL_ELAPSED_S={total_elapsed_s:.2f}"
    )


if __name__ == "__main__":
    main()
