#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Build and program the minimal ZCU104 LED bring-up design from WSL.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/zcu104_vivado
mkdir -p "$dst"
cp -f "$root/board_zcu104/led_blink_top.sv" "$dst/"
cp -f "$root/board_zcu104/led_blink.xdc" "$dst/"
cp -f "$root/board_zcu104/build_zcu104_led_blink.tcl" "$dst/"
cp -f "$root/board_zcu104/program_zcu104_led_blink.tcl" "$dst/"

cd /mnt/e
cmd.exe /d /s /c "cd /d E:\ && E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source E:\zcu104_vivado\build_zcu104_led_blink.tcl"
cmd.exe /d /s /c "cd /d E:\ && E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source E:\zcu104_vivado\program_zcu104_led_blink.tcl"
