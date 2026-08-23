#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/board_7020/software/gestureflow_descriptor_replay_main.c"
full_header="$root/board_7020/software/gestureflow_real_conv4x4_full_layer.h"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1
app="$dst/vitis/axi_gpio"
include_win='E:\coralnpu_vivado\projects\gestureflow_layer_chain_descriptor_hp0_7020_v1\vitis\gestureflow_descriptor_platform\ps7_cortexa9_0\standalone_ps7_cortexa9_0\bsp\ps7_cortexa9_0\include'
# Vitis 2023.2's local BSP make crashes while building libxil on this host.
# The descriptor has no custom software driver, so use the existing generic
# Zynq standalone archive with the new XSA-generated headers above.
lib_win='E:\coralnpu_vivado\projects\gestureflow_layer_chain_descriptor_hp0_7020_v1\vitis\system_wrapper\export\system_wrapper\sw\system_wrapper\standalone_ps7_cortexa9_0\bsplib\lib'
mkdir -p "$app/src" "$app/Debug"
cp -f "$src" "$app/src/gestureflow_descriptor_replay_main.c"
cp -f "$full_header" "$app/src/gestureflow_real_conv4x4_full_layer.h"
cp -f "$app/src/lscript.ld" "$app/src/gestureflow_descriptor_replay.ld"
cmd.exe /d /s /c "set PATH=E:\Xilinx\Vitis\2023.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin;E:\Xilinx\Vitis\2023.2\gnuwin\bin;%PATH% && cd /d E:\coralnpu_vivado\projects\gestureflow_layer_chain_descriptor_hp0_7020_v1\vitis\axi_gpio\Debug && arm-none-eabi-gcc -Wall -O2 -g3 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -I${include_win} -o gestureflow_descriptor_replay_main.o ..\src\gestureflow_descriptor_replay_main.c && arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,..\src\gestureflow_descriptor_replay.ld -L${lib_win} -o gestureflow_descriptor_replay.elf gestureflow_descriptor_replay_main.o -Wl,--start-group -lxil -lgcc -lc -Wl,--end-group && arm-none-eabi-size gestureflow_descriptor_replay.elf"
