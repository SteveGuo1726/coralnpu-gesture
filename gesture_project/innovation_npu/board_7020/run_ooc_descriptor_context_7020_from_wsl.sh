#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Run only the OOC resource/timing gate. The Tcl is copied before execution so
# Vivado never receives a WSL UNC path.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1
mkdir -p "$dst/gestureflow_src" "$dst/project_local_gestureflow"
cp -f "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_output_bank_relay_loader,gestureflow_output_bank_pool_relay_loader,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_loader,gestureflow_hp0_tensor_loader_banked,gestureflow_hp0_weight_dma_loader,gestureflow_hp0_gap_fc,gestureflow_hp0_tensor_writer,gestureflow_layer_chain_hp0_axil}.sv "$dst/gestureflow_src/"
cp -f "$root/board_7020/ooc_descriptor_context_7020.tcl" "$dst/project_local_gestureflow/"
cmd.exe /d /s /c "pushd E:\coralnpu_vivado\projects\gestureflow_layer_chain_descriptor_hp0_7020_v1\project_local_gestureflow && call E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source ooc_descriptor_context_7020.tcl"
