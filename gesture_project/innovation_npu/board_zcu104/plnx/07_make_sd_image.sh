#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# 07_make_sd_image.sh -- 把 PetaLinux 产物打成一个**可烧录的整盘镜像**。
#
# 什么时候用它（备选方案 B）：当 `wsl --mount \\.\PHYSICALDRIVE<N> --bare` 因为
# 读卡器 / 设备被占用 / 权限等原因挂不上时，不去跟 Windows 较劲 ——
# 在 WSL 里造一个 .img，再用 Windows 上的 Rufus / balenaEtcher 写进 SD 卡。
#
#   usage:  sudo 07_make_sd_image.sh [输出镜像] [大小MiB]
#   e.g.    sudo 07_make_sd_image.sh ~/gf_zcu104_sd.img 2048
#
# ---------------------------------------------------------------------------
# 设计要点：**不重新实现分区/写盘逻辑**，而是造一个等价的 loop 设备，
# 然后直接调用已经验证过的 04_make_sd.sh。
# 这样"写卡"和"造镜像"两条路走的是**同一段代码**，不会出现
# "镜像这条路谁也没测过"的问题。分区表布局也因此天然一致。
#
# 需要 root：losetup / parted / mkfs / mount。
# ---------------------------------------------------------------------------

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
IMG_DIR="$PROJ/images/linux"
OUT="${1:-$HOME/gf_zcu104_sd.img}"
SIZE_MIB="${2:-2048}"

HERE="$(cd "$(dirname "$0")" && pwd)"

die()  { echo "ERROR: $*" >&2; exit 2; }
info() { echo "--- $*"; }

[ "$(id -u)" = "0" ] || die "必须用 root 跑：  sudo bash $0 ${OUT} ${SIZE_MIB}"

# ------------------------------------------------------------ 输入检查
for f in BOOT.BIN image.ub rootfs.ext4; do
    [ -f "$IMG_DIR/$f" ] || die "缺少 $IMG_DIR/$f
  若路径不对（例如 sudo 把 \$HOME 变成了 /root），显式指定：
      sudo GF_HOME=/home/<you> bash $0 $OUT $SIZE_MIB"
done
[ -f "$HERE/04_make_sd.sh" ]      || die "找不到 $HERE/04_make_sd.sh"
[ -f "$HERE/05_verify_image.sh" ] || die "找不到 $HERE/05_verify_image.sh（04 的 GATE 0 需要它）"

[ -e "$OUT" ] && die "$OUT 已存在。先删掉或换个名字（故意不覆盖，避免误伤已有镜像）。"

# 04 把 p1 固定切成 1028 MiB；p2 至少要比 rootfs 大，否则装不下
ROOTFS_MB=$(( ( $(stat -c%s "$IMG_DIR/rootfs.ext4") + 1024*1024 - 1 ) / 1024 / 1024 ))
MIN_MIB=$(( 1028 + ROOTFS_MB + 64 ))
if [ "$SIZE_MIB" -lt "$MIN_MIB" ]; then
    die "镜像太小：要求 ${SIZE_MIB} MiB，但至少需要 ${MIN_MIB} MiB
 （p1 固定 1028 MiB + rootfs ${ROOTFS_MB} MiB + 64 MiB 余量）"
fi

echo "=============================================================="
echo " 07_make_sd_image.sh -- 生成可烧录整盘镜像"
echo "=============================================================="
echo "  输出 : $OUT"
echo "  大小 : ${SIZE_MIB} MiB"
echo "  来源 : $IMG_DIR"
echo "  布局 : p1 FAT32 1028 MiB / p2 ext4 其余  （与 04_make_sd.sh 完全一致）"
echo

# ------------------------------------------------------------ 1. 稀疏镜像文件
info "1/4 创建稀疏镜像文件"
truncate -s "${SIZE_MIB}M" "$OUT"
ls -lh "$OUT"

# ------------------------------------------------------------ 2. loop 设备
info "2/4 接成 loop 设备（-P 让分区节点自动出现）"
LOOPDEV="$(losetup -Pf --show "$OUT")"
echo "  loop = $LOOPDEV"

cleanup() {
    set +e
    umount "${LOOPDEV}p1" 2>/dev/null
    umount "${LOOPDEV}p2" 2>/dev/null
    losetup -d "$LOOPDEV" 2>/dev/null
}
detached=0
trap 'if [ "$detached" = 0 ]; then cleanup; fi' EXIT

sleep 1
ls -l "${LOOPDEV}"* 2>/dev/null || die "分区节点没出现；试着 re-plug 或换内核"

# ------------------------------------------------------------ 3. 复用 04
info "3/4 调用 04_make_sd.sh（同一段分区 / 写盘 / 校验逻辑）"
# 04 会：先跑 05_verify_image.sh（GATE 0，不 PASS 拒绝继续）
#       → 校验 manifest 含 gf-npu
#       → 要求"把设备名再手打一遍确认"
#       → 分区 → 写 rootfs → resize2fs 撑满 → 只读挂载复核 + 打印 md5
# 这里用管道把设备名喂进去作为确认 —— loop 设备是我们刚造的，不可能认错，
# 而 05 的校验和写后 md5 复核一步都没省。
printf '%s\n' "$LOOPDEV" | bash "$HERE/04_make_sd.sh" "$LOOPDEV"

# ------------------------------------------------------------ 4. 卸载 + 指纹
info "4/4 卸载 loop 并算指纹"
umount "${LOOPDEV}p1" 2>/dev/null || true
umount "${LOOPDEV}p2" 2>/dev/null || true
losetup -d "$LOOPDEV"
detached=1

echo
echo "==================== DONE ===================="
ls -lh "$OUT"
echo
echo "  镜像 SHA256（记下来；写卡后可据此确认你写的确实是这个文件）："
sha256sum "$OUT" | sed 's/^/    /'
echo
echo "  p1/p2 布局（用 fdisk 复核，不用挂载）："
fdisk -l "$OUT" 2>/dev/null | sed 's/^/    /' | head -12
echo
echo "下一步（Windows 侧）："
echo "  1. 用 **Rufus** 或 **balenaEtcher**，把下面的文件写到那张 32 GB 卡："
echo "       \\\\wsl.localhost\\Ubuntu-22.04$(echo "$OUT" | sed 's|^/home/|/home/|')"
echo "     （或先 cp 到 /mnt/c/ 再写，避免 WSL 共享路径的兼容问题）"
echo "  2. 写完：SW6[4:1] = OFF,OFF,OFF,ON，插 J100，上电"
echo
echo "  注意：镜像只有 ${SIZE_MIB} MiB，所以卡上会剩一段未分区空间，**不影响使用**。"
echo "        若要把根分区撑满整卡，在板上执行一次："
echo "          sudo growpart /dev/mmcblk0 2 && sudo resize2fs /dev/mmcblk0p2"
