#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Apply the rootfs config, then run the full PetaLinux build.
# Long-running: expect tens of minutes to a couple of hours.
#
# Log goes to a LOCAL ext4 path (never /mnt/*) -- reading/writing the Windows
# drives from WSL is roughly an order of magnitude slower and this build does
# a lot of small file I/O.

set -uo pipefail
export PATH=/usr/bin:/bin

PLNX_DIR="$HOME/petalinux/2023.2"
PROJ="$HOME/gf_linux_ws/gf_linux"
LOG="$HOME/gf_linux_ws/build.log"

# Hard requirement, not cosmetic: PetaLinux hard-codes LC_ALL="en_US.UTF-8" in
# tools/xsct/bin/rdiArgs.sh.  Without that locale the XSCT C++ tools abort with
#     locale::facet::_S_create_c_locale name not valid
# and BitBake mis-parses the gcc version out of a setlocale warning.
# See 00_host_setup.sh for the full explanation.
if ! locale -a 2>/dev/null | grep -qx 'en_US.utf8'; then
  echo "ERROR: en_US.UTF-8 locale is missing." >&2
  echo "  Run this once (needs root), then retry:" >&2
  echo "    sudo bash $(dirname "$0")/00_host_setup.sh" >&2
  exit 2
fi

source "$PLNX_DIR/settings.sh"

cd "$PROJ" || exit 2

echo "==== apply rootfs config ====" | tee "$LOG"
petalinux-config -c rootfs --silentconfig >> "$LOG" 2>&1
echo "rootfs_silentconfig_rc=$?" | tee -a "$LOG"

echo "==== petalinux-build ====" | tee -a "$LOG"
date | tee -a "$LOG"
petalinux-build >> "$LOG" 2>&1
rc=$?
date | tee -a "$LOG"
echo "BUILD_RC=$rc" | tee -a "$LOG"

echo "==== images ====" | tee -a "$LOG"
ls -la "$PROJ/images/linux/" 2>&1 | tee -a "$LOG"
