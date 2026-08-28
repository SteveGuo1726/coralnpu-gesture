#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Compile the HaGRID-18 full-network driver against the 48-cin postprocess XSA.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_hagrid18_7020_v1
src="$root/board_7020/software/gestureflow_hagrid18_main.c"
app="$project/vitis/axi_gpio_hagrid18"
platform_bsp="$project/vitis/gestureflow_hagrid18_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/ps7_cortexa9_0"
include_win='E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\vitis\gestureflow_hagrid18_platform\ps7_cortexa9_0\standalone_ps7_cortexa9_0\bsp\ps7_cortexa9_0\include'
lib_win='E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\vitis\gestureflow_hagrid18_platform\ps7_cortexa9_0\standalone_ps7_cortexa9_0\bsp\ps7_cortexa9_0\lib'
headers=(
  gestureflow_real_conv4x4_full_layer.h gestureflow_chain_body_data.h
  gestureflow_real_maxpool2d.h gestureflow_real_maxpool2d_pool2.h
  gestureflow_real_conv4x4_conv2a_layer.h gestureflow_real_conv4x4_conv2b_layer.h
  gestureflow_real_conv4x4_conv3a_layer.h gestureflow_real_conv4x4_conv3b_layer.h
  gestureflow_real_maxpool2d_pool3.h gestureflow_real_conv4x4_head1x1_layer.h
  gestureflow_real_gap_fc.h
)
for required in \
  "$project/logs/gestureflow_hagrid18_7020.xsa" \
  "$platform_bsp/include/xparameters.h" "$platform_bsp/lib/libxil.a"; do
  [[ -f "$required" ]] || { echo "missing hagrid18 build input: $required" >&2; exit 2; }
done
mkdir -p "$app/src" "$app/Debug"
cp -f "$src" "$app/src/gestureflow_hagrid18_main.c"
for header in "${headers[@]}"; do cp -f "$root/board_7020/software/$header" "$app/src/$header"; done
cp -f "$project/vitis/axi_gpio/src/lscript.ld" "$app/src/gestureflow_hagrid18.ld" 2>/dev/null || \
  cp -f "$project/vitis/axi_gpio/src/lscript.ld" "$app/src/lscript.ld"
cp -f "$project/vitis/axi_gpio/Debug/Xilinx.spec" "$app/Debug/Xilinx.spec"
cmd.exe /d /s /c "set PATH=E:\Xilinx\Vitis\2023.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin;E:\Xilinx\Vitis\2023.2\gnuwin\bin;%PATH% && pushd E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\vitis\axi_gpio_hagrid18\Debug && arm-none-eabi-gcc -Wall -O2 -g3 -DGF_FAST_RELEASE=1 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -I${include_win} -o gestureflow_hagrid18_main.o ..\src\gestureflow_hagrid18_main.c && arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none -specs=Xilinx.spec -Wl,-T -Wl,..\src\gestureflow_hagrid18.ld -L${lib_win} -o gestureflow_hagrid18.elf gestureflow_hagrid18_main.o -Wl,--start-group -lxil -lgcc -lc -Wl,--end-group && arm-none-eabi-size gestureflow_hagrid18.elf"
