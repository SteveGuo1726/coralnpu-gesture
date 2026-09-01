#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/board_7020/software/gestureflow_body2_dmp_main.c"
real_header="$root/board_7020/software/gestureflow_chain_body_data.h"
dmp_header="$root/board_7020/software/gestureflow_dmp_body2_layer.h"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_body2_dmp_7020_v1
app="$dst/vitis/axi_gpio"
include_win='E:\coralnpu_vivado\projects\gestureflow_body2_dmp_7020_v1\vitis\system_wrapper\export\system_wrapper\sw\system_wrapper\standalone_ps7_cortexa9_0\bspinclude\include'
lib_win='E:\coralnpu_vivado\projects\gestureflow_body2_dmp_7020_v1\vitis\system_wrapper\export\system_wrapper\sw\system_wrapper\standalone_ps7_cortexa9_0\bsplib\lib'
mkdir -p "$app/src" "$app/Debug"
cp -f "$src" "$app/src/gestureflow_body2_dmp_main.c"
cp -f "$real_header" "$app/src/gestureflow_chain_body_data.h"
cp -f "$dmp_header" "$app/src/gestureflow_dmp_body2_layer.h"
cp -f "$app/src/lscript.ld" "$app/src/gestureflow_body2_dmp.ld"
cmd.exe /d /s /c "set PATH=E:\Xilinx\Vitis\2023.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin;E:\Xilinx\Vitis\2023.2\gnuwin\bin;%PATH% && pushd E:\coralnpu_vivado\projects\gestureflow_body2_dmp_7020_v1\vitis\axi_gpio\Debug && arm-none-eabi-gcc -Wall -O2 -g3 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -I${include_win} -o gestureflow_body2_dmp.o ..\src\gestureflow_body2_dmp_main.c && arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,..\src\gestureflow_body2_dmp.ld -L${lib_win} -o gestureflow_body2_dmp.elf gestureflow_body2_dmp.o -Wl,--start-group -lxil -lgcc -lc -Wl,--end-group && arm-none-eabi-size gestureflow_body2_dmp.elf"
