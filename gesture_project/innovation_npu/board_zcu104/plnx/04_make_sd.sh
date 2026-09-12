#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Build the ZCU104 SD boot card from the PetaLinux images.
#
#   usage:  sudo 04_make_sd.sh <block-device>      e.g.  /dev/sdX
#
#   ############################################################
#   #  THIS ERASES THE ENTIRE TARGET DEVICE.  IT IS NOT UNDOABLE.
#   #  Double-check the device name with `lsblk` FIRST.
#   ############################################################
#
# Needs root (parted / mkfs / dd / mount), so run it with sudo:
#     lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT,MODEL     # find the card
#     sudo bash 04_make_sd.sh /dev/sdX
#
# Layout (UG1267 / PetaLinux SD-boot convention):
#   p1  FAT32  ~1 GiB : BOOT.BIN, image.ub, boot.scr, system.dtb
#   p2  ext4   rest   : rootfs.ext4 written raw, then resized to fill p2
#
# Boot mode: SW6 [4:1] = OFF, OFF, OFF, ON  (SD1).  UG1267 note: ON = 0, OFF = 1.
#
# This script only touches the device you name; it never guesses one, and it
# requires you to retype the path before writing anything.

set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# ---------------------------------------------------------------------------
# 解析"调用者"的家目录（改动前先读完这段）。
#
# 这些脚本需要 root（parted / mkfs / dd / mount），但 PetaLinux 工程树和 git 仓库
# 在**调用者**的家目录下。sudo 会把 $HOME 重置为 /root，于是裸用 $HOME 会静默指向
# 错误的树 —— 症状是镜像明明在，脚本却报 missing /root/gf_linux_ws/... 。
#
# 解析顺序：$GF_HOME（显式覆盖） -> 调用 sudo 的那个用户的家目录 -> $HOME。
# ---------------------------------------------------------------------------
if [ -z "${GF_HOME:-}" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    GF_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
fi
if [ -n "${GF_HOME:-}" ] && [ -d "$GF_HOME" ]; then
    HOME="$GF_HOME"; export HOME
fi


PROJ="${PROJ:-$HOME/gf_linux_ws/gf_linux}"
IMG="$PROJ/images/linux"
DEV="${1:-}"

die()  { echo "ERROR: $*" >&2; exit 2; }
info() { echo "--- $*"; }

# ---------------------------------------------------------------- pre-checks --
[ "$(id -u)" = "0" ] || die "must run as root:  sudo bash $0 ${DEV:-<device>}"
[ -n "$DEV" ] || die "give the target block device, e.g. $0 /dev/sdX
  list candidates with:  lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT,MODEL"
[ -b "$DEV" ] || die "$DEV is not a block device"

for f in BOOT.BIN image.ub; do
  [ -f "$IMG/$f" ] || die "missing $IMG/$f
  resolved image dir: $IMG
  If that path is wrong, point the script at the right tree explicitly:
      sudo GF_HOME=/home/<you> bash $0 ${DEV}
      sudo PROJ=/home/<you>/gf_linux_ws/gf_linux bash $0 ${DEV}"
done
[ -f "$IMG/rootfs.ext4" ] || die "missing $IMG/rootfs.ext4 (rootfs type must be ext4)"

# ---------------------------------------------------------------------------
# GATE 0: prove the image is not stale.
#
# "The build succeeded" and "the change actually reached the image" are two
# different claims.  This runs the verifier and refuses to write if it fails --
# better to fail here than to debug a phantom on hardware.
#
# （历史注记：曾把这里的问题误判成 "file:// 的 SRC_URI 让 sstate 短路了 do_compile"。
#   实际原因是编译期常量导致 GCC 删掉了那条诊断字符串。详见 PITFALLS.md #8。）
# ---------------------------------------------------------------------------
# 用绝对路径定位同目录的姊妹脚本：dirname "$0" 在 $0 没有目录成分时只是 "."，
# 一旦脚本被从别处按路径调用就会失效（曾因此出现 "找不到 05" 的假故障）。
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$HERE/05_verify_image.sh"
if [ -x "$VERIFY" ]; then
  echo "=== pre-flight: verifying rootfs content against the repo sources ==="
  # 05_verify_image.sh uses debugfs and needs no root, but it is happy either way.
  if bash "$VERIFY"; then
    echo "=== pre-flight OK: the image matches the current sources ==="
  else
    die "pre-flight verification FAILED - this image does NOT contain the current
  sources, so the board would run stale binaries.
  Rebuild with:  bash $HERE/06_install_app.sh
  (then run this script again)"
  fi
else
  echo "WARNING: $VERIFY not found - skipping the staleness gate."
  echo "         Strongly recommended: run it manually before flashing."
  read -r -p "         Continue anyway? [y/N] " _cont
  [ "$_cont" = "y" ] || die "aborted (no gate, no write)"
fi

# The whole point of this card is to run the NPU pipeline; fail early if the
# binaries are not actually in the rootfs, rather than after flashing.
if [ -f "$IMG/rootfs.manifest" ]; then
  if grep -q '^gf-npu ' "$IMG/rootfs.manifest"; then
    echo "rootfs contains gf-npu:"
    grep -E '^gf-npu |^v4l-utils |^usbutils |^libjpeg' "$IMG/rootfs.manifest" || true
  else
    die "gf-npu is NOT in rootfs.manifest - the image would boot without the NPU tools.
  Check that CONFIG_gf-npu=y is set and the build succeeded."
  fi
fi

echo "################################################################"
echo "#  ABOUT TO ERASE  $DEV"
echo "#"
lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT,MODEL "$DEV" || true
echo "#"
echo "#  Everything above will be DESTROYED."
echo "################################################################"
echo
read -r -p "Type the device path again to confirm (or Ctrl-C to abort): " CONFIRM
[ "$CONFIRM" = "$DEV" ] || die "confirmation did not match - aborted, nothing was written"

# unmount anything currently on the device
while read -r mp; do
  [ -n "$mp" ] && { umount "$mp" 2>/dev/null || die "cannot unmount $mp"; }
done < <(lsblk -no MOUNTPOINT "$DEV")

# ---------------------------------------------------------------- partitioning --
info "partitioning $DEV: p1 FAT32 1 GiB, p2 ext4 = rest"
wipefs -a "$DEV" >/dev/null 2>&1 || true
parted -s "$DEV" mklabel msdos
parted -s -a optimal "$DEV" mkpart primary fat32 4MiB 1028MiB
parted -s -a optimal "$DEV" mkpart primary ext4  1028MiB 100%
partprobe "$DEV" 2>/dev/null || true
sleep 2

# /dev/sdX1 vs /dev/mmcblk0p1 vs /dev/nvme0n1p1
if [[ "$DEV" =~ [0-9]$ ]]; then P1="${DEV}p1"; P2="${DEV}p2"; else P1="${DEV}1"; P2="${DEV}2"; fi
[ -b "$P1" ] || die "$P1 did not appear; re-plug the card and check dmesg"
[ -b "$P2" ] || die "$P2 did not appear; re-plug the card and check dmesg"

# ------------------------------------------------------------------ boot (p1) --
info "p1 = $P1 (FAT32)"
mkfs.vfat -F 32 -n BOOT "$P1"
BOOTMNT="$(mktemp -d)"
mount "$P1" "$BOOTMNT"
cp -f "$IMG/BOOT.BIN" "$IMG/image.ub" "$BOOTMNT/"
for extra in boot.scr system.dtb system.bit; do
  [ -f "$IMG/$extra" ] && cp -f "$IMG/$extra" "$BOOTMNT/"
done
sync
echo "p1 contents:"
ls -la "$BOOTMNT"
umount "$BOOTMNT"
rmdir "$BOOTMNT"

# ------------------------------------------------------------------ root (p2) --
info "p2 = $P2 (ext4, raw rootfs.ext4 + resize to fill)"
mkfs.ext4 -q -F -L rootfs "$P2"
dd if="$IMG/rootfs.ext4" of="$P2" bs=4M conv=fsync status=progress

# The ext4 image is smaller than the partition; grow it, otherwise everything
# past the image size is unusable.  e2fsck first because resize2fs wants a
# clean filesystem.
info "growing the filesystem to fill $P2"
e2fsck -f -y "$P2" >/dev/null 2>&1 || true
resize2fs "$P2" 2>&1 | tail -3
sync

# ------------------------------------------------------------- verification --
info "verifying what was written"
ROOTMNT="$(mktemp -d)"
if mount -o ro "$P2" "$ROOTMNT"; then
  ok=1
  for p in usr/bin/gf_npu_probe usr/bin/gf_camera usr/bin/v4l2-ctl usr/bin/lsusb; do
    # 必须同时接受普通文件和符号链接，而且要在**挂载树内部**解析链接目标。
    #
    # 原因：Yocto 的 update-alternatives 把 /usr/bin/lsusb 做成**绝对**符号链接
    #（-> /usr/bin/lsusb.usbutils）。`[ -e ]` 会跟随它、并按**宿主机**的 / 去解析
    # 目标，于是永远判成不存在 —— 纯粹误报（曾据此在写卡后报 "MISS /usr/bin/lsusb"）。
    # 但裸用 `[ -L ]` 又会把悬空链接也当成 OK。所以这里自己解析：
    #   绝对链接  -> 拼到 $ROOTMNT 前
    #   相对链接  -> 相对其所在目录
    ent="$ROOTMNT/$p"
    shown="$p"
    if [ -L "$ent" ]; then
      tgt="$(readlink "$ent")"
      shown="$p  -> $tgt"
      case "$tgt" in
        /*) target="$ROOTMNT$tgt" ;;
        *)  target="$(dirname "$ent")/$tgt" ;;
      esac
    else
      target="$ent"
    fi
    if [ -e "$target" ]; then
      echo "  OK   /$shown"
    else
      echo "  MISS /$shown"; ok=0
    fi
  done
  if [ -d "$ROOTMNT/lib/modules" ]; then
    echo "  OK   /lib/modules ($(ls -1 "$ROOTMNT/lib/modules" | tr '\n' ' '))"
  else
    echo "  MISS /lib/modules"
  fi
  echo "  file(1) on gf_camera:"
  file "$ROOTMNT/usr/bin/gf_camera" 2>/dev/null | sed 's/^/    /'
  # 指纹：记下这几个值，与 05_verify_image.sh 的输出对照，
  # 就能确认卡上跑的确实是刚校验过的那两个二进制。
  echo "  md5 (应该与 05_verify_image.sh 的 [6] 段一致):"
  md5sum "$ROOTMNT/usr/bin/gf_npu_probe" "$ROOTMNT/usr/bin/gf_camera" 2>/dev/null | sed 's/^/    /'
  umount "$ROOTMNT"
  [ "$ok" = "1" ] || echo "WARNING: some expected files are missing - check the build"
else
  echo "  could not re-mount read-only for verification"
fi
rmdir "$ROOTMNT"

echo
echo "==================== DONE ===================="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEV"
echo
echo "Next:"
echo "  1. insert the card into J100"
echo "  2. set SW6 [4:1] = OFF, OFF, OFF, ON   (SD1; ON=0, OFF=1)"
echo "  3. serial console: FT4232H channel 0, 115200 8N1"
echo "  4. power-cycle"
echo
echo "First commands on the board:"
echo "  lsusb                       # is the camera enumerated?"
echo "  v4l2-ctl --list-devices"
echo "  gf_npu_probe                # MUST print RESULT: PASS before trusting the camera"
echo "  gf_camera -s 640x480"
