#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_hagrid18_ooc_7020
period_ns="${GESTUREFLOW_HAGRID18_OOC_PERIOD_NS:-12.500}"
out_lanes="${GESTUREFLOW_HAGRID18_OOC_OUT_LANES:-32}"
mkdir -p "$dst/hagrid18_src" "$dst/logs"
cp -f "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_output_bank_relay_loader,gestureflow_output_bank_pool_relay_loader,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_loader,gestureflow_hp0_tensor_loader_banked,gestureflow_hp0_weight_dma_loader,gestureflow_hp0_gap_fc,gestureflow_hp0_tensor_writer,gestureflow_hp0_stream_writer,gestureflow_layer_chain_hp0_axil}.sv "$dst/hagrid18_src/"
cp -f "$root/board_7020/ooc_gestureflow_hagrid18_synth_7020.tcl" "$dst/"
# CMD.EXE inherits the WSL UNC working directory unless we move to the
# mounted Windows volume first. Vivado itself must be launched from E: so the
# batch Tcl path is resolved as a native Windows path, not \\wsl.localhost.
cd /mnt/e
timeout 360s cmd.exe /d /s /c "pushd E:\\coralnpu_vivado\\projects\\gestureflow_hagrid18_ooc_7020 && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source ooc_gestureflow_hagrid18_synth_7020.tcl -tclargs ${period_ns} ${out_lanes}" 2>&1 | tee /tmp/gestureflow_hagrid18_ooc_synth.log
