#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Bounded real-model HP0 regression. The timeout is intentionally below 3 min.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_full_layer_hp0_axil_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_full_layer_hp0_axil --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_same4x4_rgb_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_rgb_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_conv4x4_rgb_same_layer,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_writer,gestureflow_full_layer_hp0_axil}.sv \
  "$root/tests/tb_gestureflow_full_layer_hp0_axil.sv"
timeout 180s "$build/Vtb_gestureflow_full_layer_hp0_axil"
timeout 180s "$build/Vtb_gestureflow_full_layer_hp0_axil" +store
