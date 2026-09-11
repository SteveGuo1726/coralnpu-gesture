#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# ZCU104 / PetaLinux 2023.2 build-host preparation (Ubuntu 22.04 on WSL2).
#
# Run ONCE as root:
#     sudo bash /mnt/e/zcu104_vivado/plnx/00_host_setup.sh
#
# Does three things UG1144 requires, in the order that actually works on 22.04:
#   1. /bin/sh -> bash            (PetaLinux refuses to run with dash)
#   2. enable the i386 architecture  (needed for zlib1g:i386)
#   3. install the build-host package list
#
# Notes on the 22.04 package list -- these differ from older guides:
#   * `pylint3`   -> in 22.04 the package is `pylint`
#   * `tftpd`     -> provided by `tftpd-hpa` on 22.04
#   * `libegl1-mesa` -> kept, it is still installable as a transitional package
#   * `bc`        added (needed by some kernel build steps)
# Install is best-effort per package so that one unavailable name cannot abort
# the whole run; the missing ones are re-checked at the end.

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

echo "=== 1. /bin/sh -> bash ==="
echo "dash dash/sh boolean false" | debconf-set-selections
dpkg-reconfigure -f noninteractive dash
echo "now: /bin/sh -> $(readlink -f /bin/sh)"

echo
echo "=== 2. enable i386 architecture ==="
if dpkg --print-foreign-architectures | grep -q i386; then
  echo "already enabled"
else
  dpkg --add-architecture i386
  echo "added"
fi

echo
echo "=== 3. apt-get update ==="
apt-get update -qq

echo
echo "=== 4. install build-host packages ==="
PKGS="
iproute2 gawk python3 python3-pip build-essential gcc git make
net-tools libncurses5-dev tftpd-hpa zlib1g-dev libssl-dev flex bison
libselinux1 gnupg wget diffstat chrpath socat xterm autoconf libtool
tar unzip texinfo gcc-multilib automake screen pax gzip cpio
python3-pexpect xz-utils debianutils iputils-ping python3-git python3-jinja2
libegl1-mesa libsdl1.2-dev pylint bc libtinfo5 subversion u-boot-tools
zlib1g:i386
"
failed=""
for p in $PKGS; do
  if ! apt-get install -y -qq "$p" >/dev/null 2>&1; then
    failed="$failed $p"
  fi
done

echo
if [ -n "$failed" ]; then
  echo "!!! these could not be installed:$failed"
  echo "    retry individually to see why, e.g.:  apt-get install -y <name>"
else
  echo "OK: every package installed"
fi

echo
echo "=== 5. verify ==="
echo "/bin/sh       : $(readlink -f /bin/sh)   (must be /bin/bash)"
echo "foreign arch  : $(dpkg --print-foreign-architectures | tr '\n' ' ')"
df -h "$HOME" | tail -1
free -g | sed -n '2p'

cat <<'EOT'

--------------------------------------------------------------------
NEXT: download the installer (AMD account required) and run
      PetaLinux 2023.2 Installer (RUN, 3.01 GB)
        https://amd.com/zh-cn/support/downloads/adaptive-socs-and-fpgas/embedded-software.html
      put it in ~/Downloads/ then:
        bash board_zcu104/plnx/plnx_driver.sh install
--------------------------------------------------------------------
EOT
