#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; build="${TMPDIR:-/tmp}/gestureflow_same_layer_verilator"; rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"; VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv --top-module tb_gestureflow_conv4x4_rgb_same_layer --Mdir "$build" "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_same4x4_rgb_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_rgb_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_conv4x4_rgb_same_layer}.sv "$root/tests/tb_gestureflow_conv4x4_rgb_same_layer.sv"
"$build/Vtb_gestureflow_conv4x4_rgb_same_layer"
