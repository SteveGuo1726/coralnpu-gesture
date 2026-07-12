#!/usr/bin/env python3
"""Run a real quantized 3x3 layer fragment on the WIN3 board kernel.

This script keeps the current 7Z010 cfg9 + WIN3 bitstream unchanged.
It extracts a real quantized layer slice from the formal static CNN TFLite model,
feeds each input-channel window triplet to the board, accumulates the returned
partial sums on the host, and compares the final int32 totals against a local
software golden computed from the same quantized tensors.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image
import tensorflow as tf


REPO_ROOT = Path("/home/steveguo/coralnpu-gesture")
PROJECT_ROOT = REPO_ROOT / "gesture_project"
BOARD_ROOT = PROJECT_ROOT / "board_validation" / "zynqmini_7z010"
COMMON_XSDB_TCL = BOARD_ROOT / "xsdb_cfg9_common.tcl"
DEFAULT_MODEL = PROJECT_ROOT / "models" / "static_cnn_regularized_3x3_i96_e70_hagrid6_sample" / "model_int8.tflite"
DEFAULT_IMAGE = PROJECT_ROOT / "datasets" / "processed" / "hagrid_sample_static_6cls" / "train" / "palm" / "b3394b6f-4d2b-4281-ab8a-67b675cd4473.jpg"
WINDOW_DELAY_MS = 40


@dataclass(frozen=True)
class LayerBinding:
    input_index: int
    weight_index: int
    bias_index: int
    output_index: int


LAYER_BINDINGS: dict[str, LayerBinding] = {
    "conv2_3x3_a": LayerBinding(input_index=20, weight_index=13, bias_index=12, output_index=21),
    "conv2_3x3_b": LayerBinding(input_index=21, weight_index=11, bias_index=10, output_index=22),
    "conv3_3x3_a": LayerBinding(input_index=23, weight_index=9, bias_index=8, output_index=24),
    "conv3_3x3_b": LayerBinding(input_index=24, weight_index=7, bias_index=6, output_index=25),
}


PARTIAL_RE = re.compile(
    r"WIN3_PARTIAL ic=(?P<ic>\d+) result0=0x(?P<r0>[0-9A-Fa-f]{8}) "
    r"result1=0x(?P<r1>[0-9A-Fa-f]{8}) result2=0x(?P<r2>[0-9A-Fa-f]{8})"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a real quantized 3x3 layer fragment on WIN3.")
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL, help="INT8 TFLite model path.")
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE, help="Input RGB image path.")
    parser.add_argument(
        "--layer",
        choices=sorted(LAYER_BINDINGS),
        default="conv2_3x3_b",
        help="Target 3x3 layer name.",
    )
    parser.add_argument("--output_channel", type=int, default=0, help="Output channel index to replay.")
    parser.add_argument("--output_row", type=int, default=0, help="Output row index.")
    parser.add_argument(
        "--start_col",
        type=int,
        default=0,
        help="Start output column. The board computes three adjacent windows: start_col..start_col+2.",
    )
    parser.add_argument(
        "--delay_ms",
        type=int,
        default=WINDOW_DELAY_MS,
        help="Per-channel board settle delay in milliseconds.",
    )
    return parser.parse_args()


def to_windows_unc(path: Path) -> str:
    return "//wsl.localhost/Ubuntu-22.04" + path.as_posix()


def sign32(value: int) -> int:
    return value - (1 << 32) if value & 0x80000000 else value


def relu8_sat(value: int) -> int:
    if value < 0:
        return 0
    if value > 255:
        return 255
    return value


def pack_i8_bytes(values: list[int], width: int) -> int:
    if len(values) > width:
        raise ValueError(f"expected at most {width} bytes, got {len(values)}")
    packed = 0
    for idx, value in enumerate(values):
        packed |= (int(value) & 0xFF) << (8 * idx)
    return packed


def load_interpreter(model_path: Path) -> tf.lite.Interpreter:
    interpreter = tf.lite.Interpreter(
        model_path=str(model_path),
        experimental_preserve_all_tensors=True,
    )
    interpreter.allocate_tensors()
    return interpreter


def load_quantized_input(image_path: Path) -> np.ndarray:
    image = Image.open(image_path).convert("RGB").resize((96, 96))
    array = np.asarray(image, dtype=np.int16)
    return (array - 128).astype(np.int8)


def build_fragment_payload(
    interpreter: tf.lite.Interpreter,
    layer_name: str,
    image_q: np.ndarray,
    output_channel: int,
    output_row: int,
    start_col: int,
) -> dict:
    binding = LAYER_BINDINGS[layer_name]
    input_detail = interpreter.get_input_details()[0]
    interpreter.set_tensor(input_detail["index"], image_q[None, ...])
    interpreter.invoke()

    activation = interpreter.get_tensor(binding.input_index)[0]
    weights = interpreter.get_tensor(binding.weight_index)
    bias = interpreter.get_tensor(binding.bias_index)
    output = interpreter.get_tensor(binding.output_index)[0]
    activation_detail = interpreter.get_tensor_details()[binding.input_index]
    activation_zero_point = int(activation_detail["quantization"][1])

    out_h, out_w, out_c = output.shape
    if not (0 <= output_channel < out_c):
        raise ValueError(f"output_channel {output_channel} out of range 0..{out_c - 1}")
    if not (0 <= output_row < out_h):
        raise ValueError(f"output_row {output_row} out of range 0..{out_h - 1}")
    if start_col < 0 or start_col + 2 >= out_w:
        raise ValueError(f"start_col {start_col} must satisfy 0 <= start_col <= {out_w - 3}")

    padded = np.pad(
        activation.astype(np.int32),
        ((1, 1), (1, 1), (0, 0)),
        constant_values=activation_zero_point,
    )
    local = padded[output_row : output_row + 3, start_col : start_col + 5, :]

    cases: list[dict] = []
    sw_partials: list[list[int]] = []
    for input_channel in range(activation.shape[2]):
        patch5 = local[:, :, input_channel].astype(np.int32)
        kernel = weights[output_channel, :, :, input_channel].astype(np.int32)
        partials = []
        for dx in range(3):
            patch3 = patch5[:, dx : dx + 3]
            partials.append(int(np.sum(patch3 * kernel)))

        sw_partials.append(partials)
        cases.append(
            {
                "ic": input_channel,
                "row0_lo": pack_i8_bytes(patch5[0, 0:4].tolist(), 4),
                "row0_hi": pack_i8_bytes([int(patch5[0, 4])], 1),
                "row1_lo": pack_i8_bytes(patch5[1, 0:4].tolist(), 4),
                "row1_hi": pack_i8_bytes([int(patch5[1, 4])], 1),
                "row2_lo": pack_i8_bytes(patch5[2, 0:4].tolist(), 4),
                "row2_hi": pack_i8_bytes([int(patch5[2, 4])], 1),
                "wgt0": pack_i8_bytes(kernel.reshape(-1)[0:4].tolist(), 4),
                "wgt1": pack_i8_bytes(kernel.reshape(-1)[4:8].tolist(), 4),
                "wgt2": pack_i8_bytes([int(kernel.reshape(-1)[8])], 1),
            }
        )

    sw_partials_arr = np.asarray(sw_partials, dtype=np.int64)
    partial_sum = sw_partials_arr.sum(axis=0)
    weight_sum = int(weights[output_channel].astype(np.int32).sum())
    adjusted_bias = int(bias[output_channel]) - activation_zero_point * weight_sum
    final_totals = partial_sum + adjusted_bias

    return {
        "layer_name": layer_name,
        "input_shape": tuple(int(x) for x in activation.shape),
        "output_shape": tuple(int(x) for x in output.shape),
        "activation_zero_point": activation_zero_point,
        "output_channel": output_channel,
        "output_row": output_row,
        "start_col": start_col,
        "raw_bias": int(bias[output_channel]),
        "weight_sum": weight_sum,
        "adjusted_bias": adjusted_bias,
        "sw_partials": sw_partials_arr,
        "sw_partial_sum": partial_sum,
        "final_totals": final_totals,
        "tflite_output_chunk": output[output_row, start_col : start_col + 3, output_channel].astype(int).tolist(),
        "cases": cases,
    }


def write_tcl_script(cases: list[dict], delay_ms: int, path: Path) -> None:
    lines = [
        "set base_addr 0x43C00000",
        f"source {to_windows_unc(COMMON_XSDB_TCL)}",
        "cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file",
    ]
    for case in cases:
        lines += [
            "cfg9_apu_write32 [expr {$base_addr + 0x180}] 0x00000002",
            "after 5",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x110}}] 0x{case['wgt0']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x114}}] 0x{case['wgt1']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x118}}] 0x{case['wgt2']:08X}",
            "cfg9_apu_write32 [expr {$base_addr + 0x11C}] 0x00000000",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x184}}] 0x{case['row0_lo']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x188}}] 0x{case['row0_hi']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x18C}}] 0x{case['row1_lo']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x190}}] 0x{case['row1_hi']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x194}}] 0x{case['row2_lo']:08X}",
            f"cfg9_apu_write32 [expr {{$base_addr + 0x198}}] 0x{case['row2_hi']:08X}",
            "cfg9_apu_write32 [expr {$base_addr + 0x180}] 0x00000001",
            f"after {delay_ms}",
            "set result0 [cfg9_apu_read32_int [expr {$base_addr + 0x1A0}]]",
            "set result1 [cfg9_apu_read32_int [expr {$base_addr + 0x1A4}]]",
            "set result2 [cfg9_apu_read32_int [expr {$base_addr + 0x1A8}]]",
            (
                "puts [format \"WIN3_PARTIAL ic=%d result0=0x%08X result1=0x%08X result2=0x%08X\" "
                f"{case['ic']} $result0 $result1 $result2]"
            ),
        ]
    lines += [
        "puts \"WIN3_REAL_LAYER_FRAGMENT_DONE\"",
        "exit",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_xsdb_script(tcl_path: Path) -> str:
    cmd = (
        'cd /d E:\\coralnpu_vivado\\zynqmini_7z010 && '
        'call E:\\Xilinx\\Vivado\\2023.2\\bin\\xsdb.bat '
        f'{to_windows_unc(tcl_path)}'
    )
    result = subprocess.run(
        ["cmd.exe", "/c", cmd],
        check=True,
        capture_output=True,
    )
    stdout = result.stdout
    if isinstance(stdout, bytes):
        try:
            return stdout.decode("utf-8")
        except UnicodeDecodeError:
            return stdout.decode("gbk", errors="ignore")
    return stdout


def parse_board_partials(stdout: str, expected_cases: int) -> np.ndarray:
    board_rows: list[list[int]] = []
    for line in stdout.splitlines():
        match = PARTIAL_RE.search(line)
        if not match:
            continue
        board_rows.append(
            [
                sign32(int(match.group("r0"), 16)),
                sign32(int(match.group("r1"), 16)),
                sign32(int(match.group("r2"), 16)),
            ]
        )
    if len(board_rows) != expected_cases:
        raise RuntimeError(
            f"Expected {expected_cases} board partial rows, got {len(board_rows)}.\nFull XSDB output:\n{stdout}"
        )
    return np.asarray(board_rows, dtype=np.int64)


def main() -> None:
    args = parse_args()
    interpreter = load_interpreter(args.model)
    image_q = load_quantized_input(args.image)
    payload = build_fragment_payload(
        interpreter=interpreter,
        layer_name=args.layer,
        image_q=image_q,
        output_channel=args.output_channel,
        output_row=args.output_row,
        start_col=args.start_col,
    )

    with tempfile.TemporaryDirectory(prefix="win3_real_layer_") as tmp_dir:
        tcl_path = Path(tmp_dir) / "run_fragment.tcl"
        write_tcl_script(payload["cases"], args.delay_ms, tcl_path)
        stdout = run_xsdb_script(tcl_path)

    board_partials = parse_board_partials(stdout, expected_cases=len(payload["cases"]))
    if not np.array_equal(board_partials, payload["sw_partials"]):
        raise SystemExit(
            "Board partial sums mismatch software partials.\n"
            f"software={payload['sw_partials'].tolist()}\n"
            f"board={board_partials.tolist()}\n"
        )

    board_partial_sum = board_partials.sum(axis=0)
    board_final = board_partial_sum + payload["adjusted_bias"]
    if not np.array_equal(board_final, payload["final_totals"]):
        raise SystemExit(
            "Board accumulated totals mismatch software golden.\n"
            f"software={payload['final_totals'].tolist()}\n"
            f"board={board_final.tolist()}\n"
        )

    relu_pack = [relu8_sat(int(v)) for v in board_final.tolist()]

    print(f"LAYER {payload['layer_name']}")
    print(f"IMAGE {args.image}")
    print(
        "FRAGMENT oc={oc} row={row} cols={c0}-{c2}".format(
            oc=payload["output_channel"],
            row=payload["output_row"],
            c0=payload["start_col"],
            c2=payload["start_col"] + 2,
        )
    )
    print(f"INPUT_SHAPE {payload['input_shape']}")
    print(f"OUTPUT_SHAPE {payload['output_shape']}")
    print(f"ACTIVATION_ZERO_POINT {payload['activation_zero_point']}")
    print(f"RAW_BIAS {payload['raw_bias']}")
    print(f"WEIGHT_SUM {payload['weight_sum']}")
    print(f"ADJUSTED_BIAS {payload['adjusted_bias']}")
    print(f"SOFTWARE_PARTIAL_SUM {payload['sw_partial_sum'].tolist()}")
    print(f"BOARD_PARTIAL_SUM {board_partial_sum.tolist()}")
    print(f"FINAL_INT32_GOLDEN {payload['final_totals'].tolist()}")
    print(f"BOARD_FINAL_INT32 {board_final.tolist()}")
    print(f"FINAL_RELU8_SAT {relu_pack}")
    print(f"TFLITE_OUTPUT_Q {payload['tflite_output_chunk']}")
    print("WIN3_REAL_LAYER_FRAGMENT_PASS")


if __name__ == "__main__":
    main()
