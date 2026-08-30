#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Build only against the routed Wide80 XSA's generated BSP. Do not reuse the
# signed 40-Cin ELF or silently fall back to the old descriptor platform.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_wide80_7020_v1
src="$root/board_7020/software/gestureflow_layer_chain_hp0_main.c"
body_src="$root/board_7020/software/gestureflow_chain_body_data.c"
app="$project/vitis/axi_gpio_80cin"
platform_bsp="$project/vitis/gestureflow_wide80_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/ps7_cortexa9_0"
include_win='E:\coralnpu_vivado\projects\gestureflow_wide80_7020_v1\vitis\gestureflow_wide80_platform\ps7_cortexa9_0\standalone_ps7_cortexa9_0\bsp\ps7_cortexa9_0\include'
lib_win='E:\coralnpu_vivado\projects\gestureflow_wide80_7020_v1\vitis\gestureflow_wide80_platform\ps7_cortexa9_0\standalone_ps7_cortexa9_0\bsp\ps7_cortexa9_0\lib'
headers=(
  gestureflow_real_conv4x4_full_layer.h
  gestureflow_real_conv4x4_body2_layer.h
  gestureflow_chain_body_data.h
  gestureflow_real_maxpool2d.h
  gestureflow_real_maxpool2d_pool2.h
  gestureflow_real_conv4x4_conv2a_layer.h
  gestureflow_real_conv4x4_conv2b_layer.h
  gestureflow_real_maxpool2d_pool2.h
  gestureflow_real_conv4x4_conv3a_layer.h
  gestureflow_real_conv4x4_conv3b_layer.h
  gestureflow_real_maxpool2d_pool3.h
  gestureflow_real_conv4x4_head1x1_layer.h
  gestureflow_real_gap_fc.h
)
for required in \
  "$project/logs/gestureflow_wide80_7020.xsa" \
  "$project/logs/gestureflow_wide80_7020.bit" \
  "$platform_bsp/include/xparameters.h" \
  "$platform_bsp/lib/libxil.a"; do
  [[ -f "$required" ]] || { echo "missing Wide80 build input: $required" >&2; exit 2; }
done
mkdir -p "$app/src" "$app/Debug"
cp -f "$src" "$app/src/gestureflow_layer_chain_hp0_main.c"
cp -f "$body_src" "$app/src/gestureflow_chain_body_data.c"
for header in "${headers[@]}"; do
  cp -f "$root/board_7020/software/$header" "$app/src/$header"
done
cp -f "$project/vitis/axi_gpio/src/lscript.ld" "$app/src/gestureflow_layer_chain_hp0_80cin.ld"
cp -f "$project/vitis/axi_gpio/Debug/Xilinx.spec" "$app/Debug/Xilinx.spec"
cmd.exe /d /s /c "set PATH=E:\Xilinx\Vitis\2023.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin;E:\Xilinx\Vitis\2023.2\gnuwin\bin;%PATH% && pushd E:\coralnpu_vivado\projects\gestureflow_wide80_7020_v1\vitis\axi_gpio_80cin\Debug && arm-none-eabi-gcc -Wall -O2 -g3 -DGF_FAST_RELEASE=0 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -I${include_win} -o gestureflow_layer_chain_hp0_main.o ..\src\gestureflow_layer_chain_hp0_main.c && arm-none-eabi-gcc -Wall -O2 -g3 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -I${include_win} -o gestureflow_chain_body_data.o ..\src\gestureflow_chain_body_data.c && arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,..\src\gestureflow_layer_chain_hp0_80cin.ld -L${lib_win} -o gestureflow_layer_chain_hp0_80cin.elf gestureflow_layer_chain_hp0_main.o gestureflow_chain_body_data.o -Wl,--start-group -lxil -lgcc -lc -Wl,--end-group && arm-none-eabi-size gestureflow_layer_chain_hp0_80cin.elf"
