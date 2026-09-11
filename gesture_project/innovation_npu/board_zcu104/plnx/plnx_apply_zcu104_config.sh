#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Apply the ZCU104-specific PetaLinux project settings to
# project-spec/configs/config, then `petalinux-config --silentconfig` re-applies
# them.  This replaces the interactive menuconfig, which cannot be scripted.
#
# Every value here is grounded in an official source:
#
#   CONFIG_SUBSYSTEM_MACHINE_NAME = "zcu104-revc"
#       AMD Vitis-Tutorials, Vitis_Platform_Creation/Getting_Started/
#       02-Edge-AI-ZCU104/step2.md -> "DTG Settings->MACHINE_NAME, modify it to
#       zcu104-revc.  If you are using a Xilinx development board it is
#       recommended to modify the machine name so that the board configurations
#       would be involved in the DTS auto-generation."
#       Effect for us: pulls in zynqmp-zcu104-revC.dts, which already contains
#           &dwc3_0 { dr_mode = "host"; maximum-speed = "super-speed"; };
#           &usb0  { phys = <&psgtr 2 PHY_TYPE_USB3 0 2>; };
#       i.e. USB3 host for the camera, with no hand-written DT patch.
#
#   CONFIG_SUBSYSTEM_ROOTFS_EXT4 = y   (and INITRD off)
#       Same tutorial: initramfs cannot retain runtime changes; we need to be
#       able to install things on the board.
#
#   CONFIG_SUBSYSTEM_RFS_FORMATS  += ext4.gz
#       Same tutorial: "append `ext4 ext4.gz` to Root File System Formats".
#
#   CONFIG_YOCTO_BB_NUMBER_THREADS / PARALLEL_MAKE
#       BitBake parallel build.  `petalinux-build` itself has no -j option
#       (checked: its --help lists none), so parallelism is a Yocto setting.
#       This box has 32 cores but WSL is capped at ~11 GB RAM, and a kernel
#       build wants roughly 1-2 GB per parallel task, so 8 is the safe knee.
#       Raise it if the build is memory-comfortable.
#
#       *** CONFIG_YOCTO_PARALLEL_MAKE IS A BARE NUMBER, NOT "-jN" ***
#       PetaLinux's gen_plnx_machine.py (line ~323) does
#           override_string += 'PARALLEL_MAKE = "-j %s"\n' % parallel_make
#       i.e. it prepends "-j " itself.  Writing "-j8" therefore produces
#           PARALLEL_MAKE = "-j -j8"
#       and Poky's oe.utils.parallel_make() then does int("-j8") and dies with
#           ExpansionError ... ValueError: invalid literal for int() with
#           base 10: '-j8'
#       The Kconfig prompt showing "[-j8]" is unrelated to the required format.
#
#   CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT = n
#       We boot from SD; copying images to /tftpboot is pointless and the
#       directory needs root.

set -uo pipefail

PROJ="${PROJ:-$HOME/gf_linux_ws/gf_linux}"
CFG="$PROJ/project-spec/configs/config"

[ -f "$CFG" ] || { echo "no config file: $CFG" >&2; exit 2; }

set_kv() {
  local k="$1" v="$2"
  if   grep -qE "^${k}="            "$CFG"; then sed -i -E "s|^${k}=.*|${k}=${v}|"    "$CFG"
  elif grep -qE "^# ${k} is not set" "$CFG"; then sed -i -E "s|^# ${k} is not set|${k}=${v}|" "$CFG"
  else printf '%s=%s\n' "$k" "$v" >> "$CFG"
  fi
  echo "  set    ${k}=${v}"
}
unset_kv() {
  local k="$1"
  if grep -qE "^${k}=" "$CFG"; then
    sed -i -E "s|^${k}=.*|# ${k} is not set|" "$CFG"
  fi
  echo "  unset  ${k}"
}

echo "=== ZCU104 project settings -> $CFG ==="

echo "[DTG] machine name (this is the ZCU104-native key)"
set_kv CONFIG_SUBSYSTEM_MACHINE_NAME '"zcu104-revc"'

echo "[rootfs] EXT4 instead of initrd"
unset_kv CONFIG_SUBSYSTEM_ROOTFS_INITRD
set_kv   CONFIG_SUBSYSTEM_ROOTFS_EXT4 y
set_kv   CONFIG_SUBSYSTEM_RFS_FORMATS '"cpio cpio.gz cpio.gz.u-boot ext4 ext4.gz tar.gz jffs2"'

echo "[boot] SD1 as primary (already default, pinned for clarity)"
set_kv CONFIG_SUBSYSTEM_PRIMARY_SD_PSU_SD_1_SELECT y

echo "[build] parallel bitbake  (PARALLEL_MAKE is a bare number - see header)"
set_kv CONFIG_YOCTO_BB_NUMBER_THREADS '"8"'
set_kv CONFIG_YOCTO_BB_NUMBER_PARSE_THREADS '"8"'
set_kv CONFIG_YOCTO_PARALLEL_MAKE '"8"'

echo "[misc] no tftp copy (SD boot)"
unset_kv CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT

echo
echo "=== 结果核对 ==="
grep -nE 'SUBSYSTEM_MACHINE_NAME|SUBSYSTEM_ROOTFS_(EXT4|INITRD)|SUBSYSTEM_RFS_FORMATS|PRIMARY_SD_PSU_SD_1_SELECT|YOCTO_BB_NUMBER_THREADS|YOCTO_PARALLEL_MAKE|COPY_TO_TFTPBOOT' "$CFG"
