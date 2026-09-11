#!/usr/bin/env bash
set -uo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# ZCU104 GestureFlow full-network build driver (WSL -> Windows Vivado 2023.2).
#
# ---------------------------------------------------------------------------
# CRITICAL -- DO NOT PIPE VIVADO'S STDOUT THROUGH WSL.
# ---------------------------------------------------------------------------
# Earlier revisions of this driver finished with
#     ... vivado.bat ... 2>&1 | tee /tmp/gf_zcu104_build.log
# and every large synthesis then died at the very end with
#     error deleting ".../.Xil/Vivado-<pid>-<host>/realtime/tmp":
#     no such file or directory
#     -> [Common 17-69] Command failed: Vivado Synthesis failed
# while small designs (the LED bring-up, single leaf modules) passed, and the
# same RTL passed when the output went straight to a Windows file.
#
# Root cause of that failure family: Vivado's design runs are launched through
# `ISEWrap.sh`, i.e. a *shell* wrapper, and Vivado's own scratch cleanup races
# with the output channel.  When stdout is a WSL pipe the cleanup at the end of
# `synth_design` can lose the race and is reported as a hard error
# (`1 Errors encountered` -> `synth_design failed`, no .dcp written).
#
# The fix, and the reason this driver redirects into a WINDOWS-side log file
# instead of `tee`-ing into /tmp, is therefore:
#   * Vivado's stdout must go to a plain Windows file -- never through a WSL
#     pipe, and never through `tee`.
#   * The launcher itself must `cd /mnt/e` and use
#     `cmd.exe /d /s /c "pushd <win dir> && call vivado.bat ..."`.
# Both were verified on 2026-09-11: the identical 21-file minimal repro FAILED
# through `tee /tmp/...` and PASSED (produced  gf_ooc.dcp, 6.8 MB) when the log
# was redirected to a Windows path.
#
# usage:
#   run_build_gestureflow_hagrid18_dmp_zcu104_from_wsl.sh [bd_only|full] [fresh]

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/zcu104_vivado/gftmpl
mode="${1:-full}"

if [[ "${2:-}" == "fresh" ]]; then
  echo "FRESH: removing $dst"
  rm -rf "$dst"
fi

mkdir -p "$dst/gestureflow_src" "$dst/project_local_gestureflow"

# GestureFlow RTL -> Windows side (same 21-file list as the verified 7020 build).
cp -f "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile_dmp,gestureflow_conv4x4_cin_same_stream_dmp,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_output_bank_relay_loader,gestureflow_output_bank_pool_relay_loader,gestureflow_hp0_rgb_loader,gestureflow_hp0_tensor_loader,gestureflow_hp0_tensor_loader_banked,gestureflow_hp0_weight_dma_loader_dmp,gestureflow_hp0_gap_fc,gestureflow_hp0_tensor_writer,gestureflow_hp0_stream_writer,gestureflow_stream_pool2x2,gestureflow_layer_chain_dmp_hp0_axil}.sv "$dst/gestureflow_src/"

cp -f "$root/board_zcu104/build_gestureflow_hagrid18_dmp_zcu104.tcl" "$dst/project_local_gestureflow/"
cp -f "$root/board_zcu104/gestureflow_hagrid18_dmp_zcu104_timing.xdc" "$dst/project_local_gestureflow/"

# Windows-side log: NEVER tee into /tmp (see the header note).
winlog='E:\zcu104_vivado\gf_zcu104_build.out.log'

cd /mnt/e
timeout 10800s cmd.exe /d /s /c "pushd E:\\zcu104_vivado\\gftmpl\\project_local_gestureflow && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source build_gestureflow_hagrid18_dmp_zcu104.tcl -tclargs $mode >> $winlog 2>&1"
rc=$?
echo "=== VIVADO_RC=$rc ===" >> /mnt/e/zcu104_vivado/gf_zcu104_build.rc
exit $rc
