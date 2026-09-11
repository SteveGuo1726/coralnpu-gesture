#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Enable the rootfs packages + image features we need on the ZCU104.
#
# ---------------------------------------------------------------------------
# CORRECTION (learned the hard way):
# `package-management` is an IMAGE FEATURE, not a recipe.  The AMD Vitis
# tutorial lists it alongside real packages, and seeding it into
# project-spec/meta-user/conf/user-rootfsconfig makes PetaLinux treat it as a
# package and add it to IMAGE_INSTALL.  The build then dies with
#     ERROR: Nothing RPROVIDES 'package-management' (but
#            .../petalinux-image-minimal.bb RDEPENDS on or otherwise requires it)
#     ERROR: Required build target 'petalinux-image-minimal' has no buildable
#            providers.
# In rootfs_config the two live in different sections:
#     CONFIG_imagefeature-package-management   <- the IMAGE feature (correct)
#     CONFIG_package-management                <- under "user packages", only
#                                                 because we seeded it
# So: never put image features into user-rootfsconfig.
# ---------------------------------------------------------------------------
#
#   packagegroup-petalinux-v4lutils  -> v4l2-ctl etc. (to poke the UVC camera)
#   usbutils                         -> lsusb
#   dnf, e2fsprogs-resize2fs, parted -> manage the rootfs on target and grow the
#                                       ext4 partition to fill the SD card
#   imagefeature-package-management  -> the actual package-management feature
#   imagefeature-empty-root-password -> development convenience; without it the
#                                       serial console may not let you log in

set -uo pipefail
export PATH=/usr/bin:/bin

P="${PROJ:-$HOME/gf_linux_ws/gf_linux}"
RC="$P/project-spec/configs/rootfs_config"
URC="$P/project-spec/meta-user/conf/user-rootfsconfig"

[ -f "$RC" ] || { echo "no rootfs_config: $RC" >&2; exit 2; }

set_kv() {
  local k="$1" v="$2"
  if   grep -qE "^${k}="             "$RC"; then sed -i -E "s|^${k}=.*|${k}=${v}|"        "$RC"; echo "  set     $k=$v"
  elif grep -qE "^# ${k} is not set" "$RC"; then sed -i -E "s|^# ${k} is not set|${k}=${v}|" "$RC"; echo "  enable  $k=$v"
  else printf '%s=%s\n' "$k" "$v" >> "$RC"; echo "  append  $k=$v"
  fi
}
unset_kv() {
  local k="$1"
  if grep -qE "^${k}=" "$RC"; then
    sed -i -E "s|^${k}=.*|# ${k} is not set|" "$RC"; echo "  disable $k"
  else
    echo "  already off  $k"
  fi
}

echo "=== 1) 从 user-rootfsconfig 删掉不是 recipe 的条目 ==="
if [ -f "$URC" ]; then
  cp -f "$URC" "$URC.bak"
  sed -i '/^CONFIG_package-management$/d' "$URC"
  echo "  removed CONFIG_package-management  (backup: $URC.bak)"
  echo "  remaining entries: $(grep -c '^CONFIG_' "$URC")"
fi

echo
echo "=== 2) 关掉被误当成包的 package-management ==="
unset_kv CONFIG_package-management

echo
echo "=== 3) 打开真正需要的 image features ==="
set_kv CONFIG_imagefeature-package-management y
set_kv CONFIG_imagefeature-empty-root-password y

echo
echo "=== 4) 确认真正的 recipe 包仍然是开的 ==="
for k in CONFIG_dnf CONFIG_e2fsprogs-resize2fs CONFIG_parted CONFIG_usbutils \
         CONFIG_packagegroup-petalinux-v4lutils; do
  printf '  %-45s : ' "$k"
  if grep -qE "^${k}=y$" "$RC"; then echo "y"; else echo "!! NOT SET"; fi
done

echo
echo "=== 5) imagefeature 段最终状态 ==="
grep -nE 'CONFIG_imagefeature-' "$RC"

echo
echo "=== 6) 确认 package-management 已不在 user packages 段 ==="
if grep -qE '^CONFIG_package-management=' "$RC"; then echo "  !! 仍然存在"; else echo "  OK: 已移除"; fi
