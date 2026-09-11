#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# ZCU104 PetaLinux 2023.2 driver  --  ZCU104-native flow, NOT a 7020 port.
#
# Grounded in the official AMD ZCU104 flow:
#   Xilinx/Vitis-Tutorials -> Vitis_Platform_Creation/Getting_Started/
#                             02-Edge-AI-ZCU104/step2.md
#   UG1267 (ZCU104 board UG, SW6 table 2-4)
#   UG1144 (PetaLinux Tools Reference Guide 2023.2)
#
# The single most important ZCU104-specific step is setting the device-tree
# generator MACHINE_NAME to `zcu104-revc`.  That pulls in the official board DTS
# (arch/arm64/boot/dts/xilinx/zynqmp-zcu104-revC.dts), which ALREADY contains
#     &dwc3_0 { dr_mode = "host"; maximum-speed = "super-speed"; };
#     &usb0  { phys = <&psgtr 2 PHY_TYPE_USB3 0 2>; };
# i.e. USB3 host mode for the camera comes for free.  Without it you would have
# to hand-write the PHY/dr_mode nodes -- which is what the previous 7020-derived
# plan wrongly did.
#
# usage:  plnx_driver.sh <stage>
#   env      check build-host requirements (run first, safe to repeat)
#   install  install PetaLinux from the .run into ~/petalinux/2023.2
#   project  create the project + import our XSA + seed configs
#   config   re-apply project-spec/configs/config (after editing it)
#   build    petalinux-build
#   package  petalinux-package --boot  -> BOOT.BIN
#   all      env, install, project, build, package

set -uo pipefail

PLNX_VER=2023.2
PLNX_DIR="$HOME/petalinux/$PLNX_VER"
INSTALLER="$HOME/Downloads/petalinux-v${PLNX_VER}-10121855-installer.run"

WS="$HOME/gf_linux_ws"
PROJ="$WS/gf_linux"

# artefacts from the Vivado side (see run_build_gestureflow_..._from_wsl.sh)
XSA_SRC=/mnt/e/zcu104_vivado/gftmpl/logs/zcu104_gf.xsa
PLNX_ASSETS=/mnt/e/zcu104_vivado/plnx

die() { echo "ERROR: $*" >&2; exit 2; }
step() { echo; echo "==================== $* ===================="; }

# --------------------------------------------------------------------- env ---
stage_env() {
  step "env: build-host requirements (UG1144)"
  echo "--- /bin/sh must be bash, not dash ---"
  if [ "$(readlink -f /bin/sh)" = "/bin/bash" ]; then
    echo "OK: /bin/sh -> bash"
  else
    echo "NEEDS FIX: /bin/sh -> $(readlink -f /bin/sh)"
    echo "  run:  sudo dpkg-reconfigure dash     (answer: No)"
  fi

  echo "--- free space on \$HOME (need >= 80 GB for petalinux-build) ---"
  df -h "$HOME" | tail -1

  echo "--- RAM ---"
  free -h | sed -n '1,2p'

  echo "--- i386 architecture (needed for zlib1g:i386) ---"
  if dpkg --print-foreign-architectures | grep -q i386; then
    echo "OK: i386 enabled"
  else
    echo "NEEDS FIX: i386 not enabled"
  fi

  echo "--- required packages (UG1144 list) ---"
  local pkgs="iproute2 gawk python3 build-essential gcc git make net-tools \
libncurses5-dev tftpd zlib1g-dev libssl-dev flex bison libselinux1 gnupg wget \
diffstat chrpath socat xterm autoconf libtool tar unzip texinfo gcc-multilib \
automake screen pax gzip cpio python3-pip python3-pexpect xz-utils \
debianutils iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev \
pylint bc libtinfo5 subversion u-boot-tools"
  local missing=""
  for p in $pkgs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  dpkg -s zlib1g:i386 >/dev/null 2>&1 || missing="$missing zlib1g:i386"
  if [ -n "$missing" ]; then
    echo "MISSING:$missing"
    echo
    echo "  Fix everything at once (needs root):"
    echo "    sudo bash $(dirname "$0")/00_host_setup.sh"
  else
    echo "OK: all listed packages present"
  fi
}

# ----------------------------------------------------------------- install ---
stage_install() {
  step "install: PetaLinux $PLNX_VER"
  [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER
  Download 'PetaLinux $PLNX_VER Installer' (RUN, 3.01 GB, md5 c401b28a41669ace1...) from
  https://amd.com/zh-cn/support/downloads/adaptive-socs-and-fpgas/embedded-software.html
  (PetaLinux tab, needs an AMD account) and put it in ~/Downloads/."

  if [ -f "$PLNX_DIR/settings.sh" ]; then
    echo "already installed at $PLNX_DIR"
  else
    mkdir -p "$PLNX_DIR"
    chmod u+x "$INSTALLER"
    "$INSTALLER" --dir "$PLNX_DIR" || die "installer failed"
  fi
  # shellcheck disable=SC1091
  source "$PLNX_DIR/settings.sh"
  petalinux-util --webtalk off >/dev/null 2>&1 || true
  echo "petalinux-create: $(command -v petalinux-create)"
}

# ----------------------------------------------------------------- project ---
stage_project() {
  step "project: create $PROJ and import our XSA"
  [ -f "$PLNX_DIR/settings.sh" ] || die "PetaLinux not installed - run stage 'install'"
  # shellcheck disable=SC1091
  source "$PLNX_DIR/settings.sh"

  [ -f "$XSA_SRC" ] || die "XSA not found: $XSA_SRC"
  mkdir -p "$WS"
  cp -f "$XSA_SRC" "$WS/" || die "copy XSA failed"

  if [ -d "$PROJ" ]; then
    echo "project already exists: $PROJ"
  else
    cd "$WS" || die "cd $WS"
    petalinux-create --type project --template zynqMP --name gf_linux || die "petalinux-create failed"
  fi

  cd "$PROJ" || die "cd $PROJ"

  # --silentconfig keeps this non-interactive.  On a brand-new project it
  # generates the default config from the XSA first.
  echo "--- petalinux-config --get-hw-description=$WS --silentconfig ---"
  petalinux-config --get-hw-description="$WS" --silentconfig 2>&1 | tail -30

  if [ -f project-spec/configs/config ]; then
    echo
    echo "GENERATED project-spec/configs/config -- MACHINE_NAME and rootfs keys:"
    grep -nE 'MACHINE_NAME|ROOTFS|RFS_FORMATS|BOOT_DEVICE|PRIMARY_SD' \
      project-spec/configs/config || echo "  (no matching symbols found - inspect the file)"
  else
    echo "NOTE: project-spec/configs/config was not generated."
    echo "      Run this once by hand, save+exit, then re-run this stage:"
    echo "        cd $PROJ && petalinux-config --get-hw-description=$WS"
  fi

  # seed the rootfs package list so they are easy to pick in menuconfig
  local urc=project-spec/meta-user/conf/user-rootfsconfig
  mkdir -p "$(dirname "$urc")"
  if ! grep -q packagegroup-petalinux-v4lutils "$urc" 2>/dev/null; then
    cat >> "$urc" <<'EOF'
CONFIG_packagegroup-petalinux-v4lutils
CONFIG_package-management
CONFIG_dnf
CONFIG_e2fsprogs-resize2fs
CONFIG_parted
CONFIG_usbutils
EOF
    echo "seeded $urc"
  fi

  # kernel fragment for USB3 host + UVC
  local kd=project-spec/meta-user/recipes-kernel/linux/linux-xlnx
  mkdir -p "$kd"
  cp -f "$PLNX_ASSETS/kernel_uvc.cfg"     "$kd/"        && echo "installed kernel_uvc.cfg"
  cp -f "$PLNX_ASSETS/linux-xlnx_%.bbappend" \
        project-spec/meta-user/recipes-kernel/linux/ && echo "installed linux-xlnx bbappend"

  echo
  echo "--------------------------------------------------------------------"
  echo "NEXT (one-off menu step, ~2 min):"
  echo "  cd $PROJ && petalinux-config"
  echo "    DTG Settings -> MACHINE_NAME                = zcu104-revc"
  echo "    Image Packaging Configuration ->"
  echo "        Root File System Type                   = EXT4"
  echo "        Root File System Formats                = ext4 ext4.gz"
  echo "    Subsystem AUTO Hardware Settings -> Advanced bootable images"
  echo "        storage -> Image storage media          = primary sd"
  echo "  save + exit, then re-run:  $0 config"
  echo "--------------------------------------------------------------------"
}

# ------------------------------------------------------------------ config ---
stage_config() {
  step "config: re-apply project-spec/configs/config"
  [ -d "$PROJ" ] || die "project missing - run stage 'project'"
  # shellcheck disable=SC1091
  source "$PLNX_DIR/settings.sh"
  cd "$PROJ" || die "cd $PROJ"
  petalinux-config --silentconfig 2>&1 | tail -20
  grep -nE 'MACHINE_NAME|ROOTFS|RFS_FORMATS|BOOT_DEVICE' project-spec/configs/config || true
}

# ------------------------------------------------------------------- build ---
stage_build() {
  step "build: petalinux-build (this takes a while)"
  [ -d "$PROJ" ] || die "project missing"
  # shellcheck disable=SC1091
  source "$PLNX_DIR/settings.sh"
  cd "$PROJ" || die "cd $PROJ"
  petalinux-build 2>&1 | tail -40
  ls -la images/linux/ 2>/dev/null | tail -20
}

# ----------------------------------------------------------------- package ---
stage_package() {
  step "package: BOOT.BIN"
  [ -d "$PROJ" ] || die "project missing"
  # shellcheck disable=SC1091
  source "$PLNX_DIR/settings.sh"
  cd "$PROJ" || die "cd $PROJ"
  for f in images/linux/zynqmp_fsbl.elf images/linux/pmufw.elf \
           images/linux/bl31.elf images/linux/u-boot.elf images/linux/system.bit; do
    [ -f "$f" ] || die "missing boot component: $f"
  done
  petalinux-package --boot --fsbl images/linux/zynqmp_fsbl.elf \
    --pmufw images/linux/pmufw.elf \
    --fpga  images/linux/system.bit \
    --u-boot images/linux/u-boot.elf --force 2>&1 | tail -20
  ls -la images/linux/BOOT.BIN images/linux/image.ub images/linux/rootfs.ext4 2>&1
}

case "${1:-}" in
  env)     stage_env ;;
  install) stage_install ;;
  project) stage_project ;;
  config)  stage_config ;;
  build)   stage_build ;;
  package) stage_package ;;
  all)     stage_env; stage_install; stage_project; stage_build; stage_package ;;
  *) sed -n '20,32p' "$0"; exit 1 ;;
esac
