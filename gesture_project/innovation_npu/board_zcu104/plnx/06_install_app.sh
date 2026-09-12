#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# 06_install_app.sh -- 把仓库里的 Linux 侧源码"投放"进 PetaLinux 工程，并强制重编
#
# ============================================================================
# 这个脚本解决什么
# ============================================================================
#
# 两件事，都很实在：
#
# (1) **投放**：把 board_zcu104/linux/*.{c,h} 和 board_7020/software 里的权重头
#     逐个 cmp 后同步进 recipe 的 files/ 目录。因为 SRC_URI 是 file://，
#     漏拷一个文件就会编不过或者编出旧东西，用 cmp 保证不漏。
#
# (2) **强制重编**：做一个干净的、可复现的重编，而不是"赌 sstate 会失效"。
#         petalinux-build -c gf-npu -x do_cleanall   # 清 sstate + work
#         petalinux-build                            # 全量重编 + 重打包
#
#     关于"为什么不等 sstate 自己判断"：
#     `file://` 类型的源码确实**不贡献内容哈希**给 Yocto 的 sstate 签名（Yocto
#     把本地文件的内容变化交给开发者自行声明）。但**实测**在本工程上，正常
#     `petalinux-build` 会把改动编进去 —— 曾经"镜像里是旧代码"的结论是**误判**，
#     真正原因是编译期常量导致的死代码删除（见 PITFALLS.md #8）。
#
#     不过 cleanall 依然值得保留：它是"无论签名逻辑怎么变都不会错"的那条路，
#     而且能保证旧的 WORKDIR 残留不会蒙混过关。代价只有几分钟。
#     `-x do_compile` 单独跑没有意义（不做投放、不动签名）。
#
# 做完立刻调 05_verify_image.sh 校验，不通过就退出非零 ——
# 绝不允许"以为改好了"的镜像被写进 SD 卡。
#
# ----------------------------------------------------------------------------
# 两点容易误判、但**不是**故障的现象（详见 PITFALLS.md #8）：
#
#   * log.do_compile 恒为 ~85 字节是**正常**的：recipe 的 do_compile 只有两条
#     gcc，而 gcc 成功时不输出任何东西。**不要**用"日志大小没变"推断任务被短路。
#
#   * 构建收尾后 WORKDIR 里只剩 temp/ 也是**正常**的：do_rm_work 会清掉源码和
#     recipe-sysroot。想查源码，先单独跑 `-x do_unpack`。
#
#   还有一个纯编译期现象：源码里某些诊断文案位于**编译期恒假**的分支，会被
#   GCC 连同字符串一起删除，在二进制里搜不到 —— 这不代表代码是旧的。
#   挑探针字符串时，条件必须依赖运行时数据。05_verify_image.sh 已按此原则选词。
# ============================================================================
#
# usage:
#   bash 06_install_app.sh            # 投放源码 + cleanall + 全量重编 + 校验
#   bash 06_install_app.sh --sync     # 只投放源码，不编译
#   bash 06_install_app.sh --check    # 只投放 + 校验（不编译，用来看当前镜像）
#
set -uo pipefail

REPO="${REPO:-$HOME/coralnpu-gesture}"
PLNX="${PLNX:-$HOME/gf_linux_ws/gf_linux}"
SRC="$REPO/gesture_project/innovation_npu/board_zcu104/linux"
APP="$PLNX/project-spec/meta-user/recipes-apps/gf-npu"
LOG="$HOME/gf_linux_ws/app_build.log"
PLNX_DIR="$HOME/petalinux/2023.2"

MODE="${1:-}"

step() { echo; echo "==================== $* ===================="; }
die()  { echo "ERROR: $*" >&2; exit 2; }

[ -d "$SRC" ]  || die "找不到源码目录: $SRC"
[ -d "$APP" ]  || die "找不到 recipe 目录: $APP（PetaLinux 工程还没建？）"

# ----------------------------------------------------------------- 1. 投放源码
step "1/4 投放源码: $SRC  ->  $APP/files/"

# --- 投放前的换行自检 --------------------------------------------------------
# 仓库里所有 shell/C 源都必须是 LF。Windows 侧编辑会写入 CR，而症状是
# bash 报"未找到命令"，离原因很远（历史上为此浪费过时间）。
# 这里选择**拦截**而不是事后自愈：自愈会把问题掩盖掉，而且自愈代码本身
# 也需要被验证 —— 上一版的自愈守卫就是个反例（见 PITFALLS.md #8 附注）。
cr_bad=0
for f in "$SRC"/*.c "$SRC"/*.h \
         "$REPO/gesture_project/innovation_npu/board_zcu104/yocto/gf-npu/gf-npu_1.0.bb"; do
    [ -f "$f" ] || continue
    n=$(LC_ALL=C tr -dc '\r' < "$f" | wc -c)
    [ "$n" -eq 0 ] || { echo "  [FAIL] 含 $n 个 CR 字节: $f"; cr_bad=$((cr_bad+1)); }
done
[ "$cr_bad" -eq 0 ] || die "$cr_bad 个待投放文件含 CR 字节；先统一成 LF（见仓库根 .gitattributes）再投放"
echo "  换行自检: 待投放文件均无 CR"

changed=0
for f in "$SRC"/*.c "$SRC"/*.h; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if [ -f "$APP/files/$b" ] && cmp -s "$f" "$APP/files/$b"; then
        printf '  same   %s\n' "$b"
    else
        cp -f "$f" "$APP/files/$b"
        printf '  UPDATED %s\n' "$b"
        changed=$((changed+1))
    fi
done

# 权重头文件（模型单一真源在 board_7020/software）
W="$REPO/gesture_project/innovation_npu/board_7020/software"
if [ -d "$W" ]; then
    for h in gestureflow_real_conv4x4_full_layer.h gestureflow_dmp_full_layer.h \
             gestureflow_chain_body_data.h gestureflow_dmp_body2_layer.h \
             gestureflow_real_maxpool2d.h \
             gestureflow_real_conv4x4_conv2a_layer.h gestureflow_dmp_conv2a_layer.h \
             gestureflow_real_conv4x4_conv2b_layer.h gestureflow_dmp_conv2b_layer.h \
             gestureflow_real_maxpool2d_pool2.h \
             gestureflow_real_conv4x4_conv3a_layer.h gestureflow_dmp_conv3a_layer.h \
             gestureflow_real_conv4x4_conv3b_layer.h gestureflow_dmp_conv3b_layer.h \
             gestureflow_real_maxpool2d_pool3.h \
             gestureflow_real_conv4x4_head1x1_layer.h gestureflow_dmp_head1x1_layer.h \
             gestureflow_real_gap_fc.h; do
        [ -f "$W/$h" ] || continue
        if [ -f "$APP/files/$h" ] && cmp -s "$W/$h" "$APP/files/$h"; then :; else
            cp -f "$W/$h" "$APP/files/$h"; printf '  UPDATED %s (weights)\n' "$h"
            changed=$((changed+1))
        fi
    done
fi

# 顺带把 recipe 本体也刷新一遍（它同样可能被改过）
cp -f "$REPO/gesture_project/innovation_npu/board_zcu104/yocto/gf-npu/gf-npu_1.0.bb" \
      "$APP/gf-npu_1.0.bb" 2>/dev/null && echo "  refreshed gf-npu_1.0.bb"

echo
echo "  本次更新 $changed 个文件"
echo "  --- 投放后 files/ 与仓库源码的 md5 对照（必须一致）---"
for b in gf_npu.c gf_npu.h gf_npu_probe.c gf_camera.c; do
    a=$(md5sum "$SRC/$b" 2>/dev/null | cut -c1-16)
    c=$(md5sum "$APP/files/$b" 2>/dev/null | cut -c1-16)
    if [ "$a" = "$c" ]; then printf '  [ OK ] %-16s %s\n' "$b" "$a"
    else                        printf '  [FAIL] %-16s repo=%s  files=%s\n' "$b" "$a" "$c"; fi
done

if [ "$MODE" = "--sync" ]; then
    echo; echo "--sync: 只投放，不编译。"; exit 0
fi

if [ "$MODE" = "--check" ]; then
    step "只校验当前镜像"
    bash "$(dirname "$0")/05_verify_image.sh"
    exit $?
fi

# ------------------------------------------------------------- 2. 清 sstate
step "2/4 清掉 gf-npu 的 sstate + work（关键：让 do_compile 的签名失效）"
# shellcheck disable=SC1091
source "$PLNX_DIR/settings.sh" 2>/dev/null || die "找不到 $PLNX_DIR/settings.sh"
cd "$PLNX" || die "cd $PLNX"
petalinux-build -c gf-npu -x do_cleanall 2>&1 | tail -15
echo "cleanall_rc=${PIPESTATUS[0]}"

# --------------------------------------------------------------- 3. 全量重编
step "3/4 全量 petalinux-build（重编 + 重打包 rootfs/image.ub，耗时较长）"
echo "日志: $LOG"
echo "开始: $(date '+%H:%M:%S')"
{ echo "==== 06_install_app.sh $(date) ===="
  date
  petalinux-build
  rc=$?
  date
  echo "BUILD_RC=$rc"
  ls -la "$PLNX/images/linux/" 2>&1
} > "$LOG" 2>&1

build_rc=$(sed -n 's/^BUILD_RC=\([0-9]*\)$/\1/p' "$LOG" | tail -1)
build_rc="${build_rc:-99}"
echo "  petalinux-build 返回码: $build_rc"
tail -12 "$LOG"
echo "  完整日志: $LOG"

if [ "$build_rc" != "0" ]; then
    echo
    echo "=============================================================="
    echo " 构建失败（BUILD_RC=$build_rc）—— 不继续校验。"
    echo " 先看日志尾部，再针对性处理：$LOG"
    echo "=============================================================="
    exit 2
fi

# ------------------------------------------------------------------ 4. 校验
step "4/4 校验镜像里的二进制 == 仓库源码"
bash "$(dirname "$0")/05_verify_image.sh"
v=$?

echo
if [ "$v" -eq 0 ]; then
    echo "=============================================================="
    echo " 全部通过：源码已进镜像，可以写 SD 卡上板。"
    echo "=============================================================="
else
    echo "=============================================================="
    echo " 校验未通过（exit $v）—— 先别烧卡，看上面的 [FAIL] 行。"
    echo "=============================================================="
fi
exit "$v"
