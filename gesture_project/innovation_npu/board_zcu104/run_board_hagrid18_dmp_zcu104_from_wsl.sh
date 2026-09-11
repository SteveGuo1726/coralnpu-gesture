#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Program the ZCU104 with the GestureFlow HaGRID-18 DMP bitstream + ELF and read
# the PROBE array back over JTAG.
#
# Prerequisites:
#   * ZCU104 connected over USB-JTAG (FT4232H, VID_0403&PID_6011);
#   * a Windows hw_server listening, by default on tcp:127.0.0.1:3121:
#         bash /mnt/e/zcu104_vivado/run_hw_server.sh
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/c/vivado_zcu104/gfz
win_project='C:\vivado_zcu104\gfz'
cp -f "$root/board_zcu104/scripts/run_gestureflow_hagrid18_dmp_zcu104_xsct.tcl" \
  "$project/project_local_gestureflow/run_gestureflow_hagrid18_dmp_zcu104_xsct.tcl"
cd /mnt/c
cmd.exe /d /s /c "set GESTUREFLOW_PROJECT_ROOT=$win_project&& set GESTUREFLOW_BIT_PATH=$win_project\\logs\\gestureflow_hagrid18_dmp_zcu104.bit&& set GESTUREFLOW_XSA_PATH=$win_project\\logs\\gestureflow_hagrid18_dmp_zcu104.xsa&& set GESTUREFLOW_ELF_PATH=$win_project\\vitis\\ws\\gf_dmp\\Debug\\gf_dmp.elf&& set GESTUREFLOW_HW_SERVER_URL=tcp:127.0.0.1:3121&& cd /d $win_project\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat run_gestureflow_hagrid18_dmp_zcu104_xsct.tcl"
