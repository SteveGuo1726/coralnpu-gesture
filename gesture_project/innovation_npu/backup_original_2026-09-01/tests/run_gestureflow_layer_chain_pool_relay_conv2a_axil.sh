#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Pool-relay regression for body -> pool -> conv2a tile0. During conv2a input
# replay the HP0 read channel must stay silent, proving the pooled relay path
# feeds the next layer directly from the local output bank.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_layer_chain_pool_relay_conv2a_axil_verilator"
rm -rf "$build"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_layer_chain_pool_relay_conv2a_axil --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_output_bank_relay_loader,gestureflow_output_bank_pool_relay_loader,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_loader,gestureflow_hp0_tensor_loader_banked,gestureflow_hp0_weight_dma_loader,gestureflow_hp0_gap_fc,gestureflow_hp0_tensor_writer,gestureflow_layer_chain_hp0_axil}.sv \
  "$root/tests/tb_gestureflow_layer_chain_pool_relay_conv2a_axil.sv"
timeout 180s "$build/Vtb_gestureflow_layer_chain_pool_relay_conv2a_axil"
