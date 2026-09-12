#!/usr/bin/env bash
#
# 10_push_app.sh -- 把刚编好的程序/页面直接送进**正在运行**的板子，不碰 SD 卡
#
# 场景
# ----
# 改完驱动想立刻在板上验一版。正规做法是重写 431 MB 的 rootfs 再重插卡，一轮
# 十几分钟。但板子已经在跑 Linux、有 root shell、根文件系统是可写的 ext4，所以
# 只要把那**一个**文件送过去覆盖即可：
#
#     从 rootfs.ext4 里 debugfs 取出文件（无需 sudo）
#        -> 09_board_put.sh 走串口送进板子的 /tmp
#        -> 板上 install 到目标路径
#        -> 双向核对 md5
#
# 526 KB 的二进制 ≈ 1 分钟；14 KB 的网页 ≈ 2 秒 —— 所以改 view.html 几乎不要钱。
#
# 什么情况下**必须**回到写卡：改动落在 rootfs 之外的东西上 —— 设备树、内核、
# boot.scr、U-Boot。那些在启动分区/BOOT.BIN 里，串口覆盖不了（见 07 与文档）。
#
# usage:
#   bash 10_push_app.sh                # 二进制 + 查看器页面
#   bash 10_push_app.sh probe          # 只推 gf_npu_probe
#   bash 10_push_app.sh camera         # 只推 gf_camera
#   bash 10_push_app.sh page           # 只推 view.html（秒级）
#   DRY=1 bash 10_push_app.sh          # 只取出并核对，不发送
#
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# 解析"调用者"的家目录：本脚本本身不需要 root，但它会被夹在需要 root 的流程里，
# 而且从这里调出去的 05 会以调用者的身份跑。规则与 04/05/06 一致。
# ---------------------------------------------------------------------------
if [ -z "${GF_HOME:-}" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    GF_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
fi
if [ -n "${GF_HOME:-}" ] && [ -d "$GF_HOME" ]; then HOME="$GF_HOME"; export HOME; fi

REPO="${REPO:-$HOME/coralnpu-gesture}"
PLNX="${PLNX:-$HOME/gf_linux_ws/gf_linux}"
IMG="$PLNX/images/linux/rootfs.ext4"
LF_SRC="$REPO/gesture_project/innovation_npu/board_zcu104/linux"

WHAT="${1:-all}"
DEV="${TTY:-}"
BAUD="${BAUD:-115200}"

die() { echo "10_push_app: $*" >&2; exit 2; }
[ -f "$IMG" ] || die "找不到 $IMG —— 先跑 06_install_app.sh 编一版"

# 每个条目:  名称 : 镜像里的路径 : 板上目标路径 : 权限
# 顺序有意义：二进制先、页面后（页面小，失败也无所谓）。
ALL_ITEMS=(
    "gf_npu_probe:/usr/bin/gf_npu_probe:/usr/bin/gf_npu_probe:755"
    "gf_camera:/usr/bin/gf_camera:/usr/bin/gf_camera:755"
    "view.html:/usr/share/gf/view.html:/usr/share/gf/view.html:644"
)

ITEMS=()
case "$WHAT" in
    all)    ITEMS=("${ALL_ITEMS[@]}") ;;
    probe)  ITEMS=("${ALL_ITEMS[0]}") ;;
    camera) ITEMS=("${ALL_ITEMS[1]}") ;;
    page)   ITEMS=("${ALL_ITEMS[2]}") ;;
    *)      die "参数只能是 all|probe|camera|page（给的是 '$WHAT'）" ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gfpush.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

NAMES=""
for it in "${ITEMS[@]}"; do NAMES="$NAMES ${it%%:*}"; done

echo "=============================================================="
echo " 10_push_app.sh  -- 免拔卡部署（串口）"
echo "=============================================================="
echo "  rootfs: $IMG"
echo "  改动于: $(stat -c '%y' "$LF_SRC/gf_npu.c" | cut -d. -f1)  (gf_npu.c)"
echo "  推哪些:$NAMES"

# ------------------------------------------------- 1. 从镜像里取出文件
# 用 debugfs 直接读 ext4，不需要 mount、不需要 root。
echo
echo "--- 1/4 从 rootfs.ext4 取出文件（debugfs，无需 sudo）---"
for it in "${ITEMS[@]}"; do
    IFS=: read -r name srcimg dest mode <<<"$it"
    rm -f "$WORK/$name"
    if debugfs -R "dump $srcimg $WORK/$name" "$IMG" >/dev/null 2>&1 && [ -s "$WORK/$name" ]; then
        printf '  %-14s %8s bytes  md5=%s\n' "$name" "$(stat -c '%s' "$WORK/$name")" "$(md5sum "$WORK/$name" | cut -c1-16)"
    else
        die "从镜像里取不出 $srcimg（debugfs 失败）"
    fi
done

# 顺带证明"取出来的就是这份源码编的"，避免把上一次的产物推上去
VMARK="$WORK/.verify"
if bash "$HERE/05_verify_image.sh" > "$VMARK" 2>&1; then
    echo "  [ OK ] 05_verify_image.sh: RESULT: PASS（镜像 == 仓库源码）"
else
    echo "  [WARN] 05_verify_image.sh 没通过，摘要："
    grep -E '^\s+\[FAIL\]|RESULT:' "$VMARK" | sed 's/^/         /'
    echo "         先跑 06_install_app.sh 把源码编进镜像，再来推。"
    die "镜像与源码不一致，拒绝推送"
fi

if [ "${DRY:-0}" = "1" ]; then
    echo
    echo "DRY=1：已取出并核对，未发送。文件在 $WORK（脚本退出即删）。"
    ls -l "$WORK" | sed 's/^/  /'
    exit 0
fi

# ----------------------------------------------------------- 2. 送进板子
echo
echo "--- 2/4 串口送进板子的 /tmp ---"
for it in "${ITEMS[@]}"; do
    IFS=: read -r name srcimg dest mode <<<"$it"
    echo
    echo ">>> $name  ->  $dest"
    if ! TTY="$DEV" BAUD="$BAUD" bash "$HERE/09_board_put.sh" "$WORK/$name" "/tmp/$name.new"; then
        die "投放 $name 失败（三次都没校验通过）—— 没有继续覆盖目标文件"
    fi
done

# --------------------------------------------------- 3/4 落位并双向核对
echo
echo "--- 3/4 落位并核对 ---"
CMDS="mkdir -p /usr/share/gf;"
for it in "${ITEMS[@]}"; do
    IFS=: read -r name srcimg dest mode <<<"$it"
    want="$(md5sum "$WORK/$name" | cut -c1-32)"
    CMDS="$CMDS cp /tmp/$name.new $dest && chmod $mode $dest && rm -f /tmp/$name.new;"
    CMDS="$CMDS printf 'GF_INSTALLED %-14s ' $name; md5sum $dest | cut -d' ' -f1;"
    CMDS="$CMDS printf 'GF_WANT      %-14s %s\\n' $name $want;"
done
CMDS="$CMDS sync;"

TTY="$DEV" bash "$HERE/08_console.sh" send "$CMDS" 8 2>&1 | sed 's/^/  /'

# ------------------------------------------------------------- 4. 结论
echo
echo "--- 4/4 结论 ---"
echo "  板上自报的 GF_INSTALLED 与 GF_WANT 必须逐字节相同；不同就说明落位没成功。"
cat <<'NOTE'

  下一步（板上，root）：
      # 先让网口起来（板子 GbE 接路由器/交换机，与笔记本同一网段）
      ip link set eth0 up
      udhcpc -i eth0                      # 有 DHCP 就会打印租到的 IP

      # --view 起网页。相机当前是**正装**的，所以不要加 --rotate；
      # 若画面方向不对，再按当前安装角度补 --rotate 0|90|180|270（运行期参数）。
      gf_camera -s 640x480 --view 8080

      然后在笔记本浏览器打开板子启动时打印的 http://<板子IP>:8080/

  关于 --view 的开销：没人看的时候它不做任何拷贝，所以基准测试请用不带
  --view 的命令行（或者量完再翻页）。细节见 gf_view.h 的注释。

  注意：这一版只存在于板上的 rootfs 里。要让**镜像**也带上它，
  仍然要跑 06_install_app.sh 并用 04_make_sd.sh 写卡 —— 别把"板上跑通了"
  和"镜像里有这一版"当成同一件事。
NOTE
