#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Build the ZCU104 SD boot card from the PetaLinux images.
#
#   usage:  04_make_sd.sh <block-device>      e.g.  /dev/sdX
#
#   ############################################################
#   #  THIS ERASES THE ENTIRE TARGET DEVICE.  IT IS NOT UNDOABLE.
#   #  Double-check the device name with `lsblk` FIRST.
#   ############################################################
#
# ZCU104 SD boot layout (UG1267 / PetaLinux SD-boot convention):
#   p1  FAT32  ~1 GB : BOOT.BIN, image.ub, boot.scr, system.dtb
#   p2  ext4  rest   : rootfs.ext4 written raw
#
# Boot mode: SW6 [4:1] = OFF, OFF, OFF, ON   (SD1).  UG1267 note: ON = 0, OFF = 1.
#
# This script ONLY touches the device you name.  It never guesses one.

set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROJ="${PROJ:-$HOME/gf_linux_ws/gf_linux}"
IMG="$PROJ/images/linux"
DEV="${1:-}"

die() { echo "ERROR: $*" >&2; exit 2; }

[ -n "$DEV" ] || die "give the target block device, e.g. $0 /dev/sdX
  list candidates with:  lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT,MODEL"
[ -b "$DEV" ] || die "$DEV is not a block device"

echo "################################################################"
echo "#  ABOUT TO ERASE  $DEV"
echo "#"
lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT,MODEL "$DEV" || true
echo "#"
echo "#  Everything above will be DESTROYED."
echo "################################################################"
echo
echo "Type the device path again to confirm (or Ctrl-C to abort):"
read -r CONFIRM
[ "$CONFIRM" = "$DEV" ] || die "confirmation did not match - aborted, nothing was written"

for f in BOOT.BIN image.ub; do
  [ -f "$IMG/$f" ] || die "missing $IMG/$f  (run plnx_driver.sh package first)"
done

# make sure nothing on the device is mounted
while read -r mp; do
  [ -n "$mp" ] && { umount "$mp" 2>/dev/null || die "cannot unmount $mp"; }
done < <(lsblk -no MOUNTPOINT "$DEV")

echo "--- partitioning $DEV: p1 FAT32 1GiB, p2 ext4 = rest ---"
wipefs -a "$DEV" >/dev/null 2>&1 || true
parted -s "$DEV" mklabel msdos
parted -s -a optimal "$DEV" mkpart primary fat32 4MiB 1028MiB
parted -s -a optimal "$DEV" mkpart primary ext4  1028MiB 100%
partprobe "$DEV" 2>/dev/null || true
sleep 2

# partition naming: /dev/sdX1 vs /dev/mmcblk0p1 vs /dev/nvme0n1p1
if [[ "$DEV" =~ [0-9]$ ]]; then P1="${DEV}p1"; P2="${DEV}p2"; else P1="${DEV}1"; P2="${DEV}2"; fi

echo "--- p1 = $P1 (FAT32) ---"
mkfs.vfat -F 32 -n BOOT "$P1"
mkdir -p /mnt/gf_boot
mount "$P1" /mnt/gf_boot
cp -f "$IMG/BOOT.BIN" "$IMG/image.ub" /mnt/gf_boot/
for extra in boot.scr system.dtb system.bit; do
  [ -f "$IMG/$extra" ] && cp -f "$IMG/$extra" /mnt/gf_boot/
done
sync
umount /mnt/gf_boot

echo "--- p2 = $P2 (ext4) ---"
if [ -f "$IMG/rootfs.ext4" ]; then
  mkfs.ext4 -q -F -L rootfs "$P2"
  dd if="$IMG/rootfs.ext4" of="$P2" bs=4M conv=fsync status=progress
elif [ -f "$IMG/rootfs.ext4.gz" ]; then
  mkfs.ext4 -q -F -L rootfs "$P2"
  zcat "$IMG/rootfs.ext4.gz" | dd of="$P2" bs=4M conv=fsync status=progress
else
  # initramfs-in-image.ub layout: a single ext4 partition is still needed for
  # persistence, but it starts empty.
  mkfs.ext4 -q -F -L rootfs "$P2"
  echo "NOTE: no rootfs.ext4 found - p2 formatted empty."
  echo "      If you selected EXT4 rootfs in petalinux-config this file must exist."
fi
sync

echo
echo "==================== DONE ===================="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEV"
echo
echo "Insert into J100, set SW6 [4:1] = OFF, OFF, OFF, ON (SD1), then power-cycle."
echo "Serial: FT4232H channel 0, 115200 8N1."
