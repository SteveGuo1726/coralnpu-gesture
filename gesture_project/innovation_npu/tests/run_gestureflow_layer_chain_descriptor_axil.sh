#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Short descriptor-to-existing-backend regression. It is bounded and does not
# run the full real-model layer-chain simulation.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_layer_chain_descriptor_axil_verilator"
rm -rf "$build"
export VERILATOR_ROOT=/home/steveguo/verilator
# IMAGE_WIDTH/OUTPUT_ADDR_W are intentionally reduced only for this control
# regression; the inherited 14-bit internal bank wires then truncate at the
# small test instance boundary. Production 96x96 lint runs without suppressions.
/home/steveguo/verilator/bin/verilator_bin --binary --timing --sv -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --top-module tb_gestureflow_layer_chain_descriptor_axil --Mdir "$build" \
  "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_output_bank_relay_loader,gestureflow_output_bank_pool_relay_loader,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_loader,gestureflow_hp0_tensor_loader_banked,gestureflow_hp0_weight_dma_loader,gestureflow_hp0_gap_fc,gestureflow_hp0_tensor_writer,gestureflow_layer_chain_hp0_axil}.sv \
  "$root"/rtl/gestureflow_hp0_stream_writer.sv \
  "$root/tests/tb_gestureflow_layer_chain_descriptor_axil.sv"
timeout 30s "$build/Vtb_gestureflow_layer_chain_descriptor_axil"
