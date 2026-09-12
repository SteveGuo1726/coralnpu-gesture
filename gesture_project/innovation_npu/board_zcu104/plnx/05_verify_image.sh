#!/usr/bin/env bash
#
# 05_verify_image.sh -- 在 WSL 里证明"镜像里的二进制 = 仓库里的源码"
#
# 动机：
#   "构建成功" 和 "改动真的进了镜像" 是两件事。petalinux-build 只保证
#   tmp/work/ 里那份源码编过了，不保证进 rootfs.ext4 的就是这份。
#   （注意：file:// 的 SRC_URI 确实不带内容哈希，但它**不是**本次问题的原因——
#   曾经的误判记录见 PITFALLS.md #8。）
#
#   另一个真实陷阱：源码里被**编译期常量**条件包住的诊断字符串会被 GCC 连分支
#   带字符串一起删掉，因此在二进制里找不到它 *不代表* 二进制是旧的。
#   所以本脚本的探针只选**运行期条件**保护的字符串。
#
# 本脚本用最简单也最硬的办法：把 rootfs.ext4 里的二进制 dump 出来，
# 再用它自己内嵌的字符串（错误信息、类名、函数名）与 repo 源码交叉比对。
#
# 用法（WSL 内，无需 sudo）:
#   bash 05_verify_image.sh
#
#
set -u

REPO="${REPO:-$HOME/coralnpu-gesture}"
PLNX="${PLNX:-$HOME/gf_linux_ws/gf_linux}"
LF_SRC="$REPO/gesture_project/innovation_npu/board_zcu104/linux"
IMG="$PLNX/images/linux/rootfs.ext4"
MANIFEST="$PLNX/images/linux/rootfs.manifest"
TMP="$HOME/gf_linux_ws/_imgverify"

fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '  [WARN] %s\n' "$*"; }

echo "=============================================================="
echo " 05_verify_image.sh  -- 镜像内容 vs 仓库源码"
echo "=============================================================="
echo "REPO    = $REPO"
echo "PLNX    = $PLNX"
echo "IMAGE   = $IMG"

[ -f "$IMG" ] || { echo "!!!! rootfs.ext4 不存在，先跑 petalinux-build !!!!"; exit 1; }

# ---------------------------------------------------------------- 0. 时效性
echo
echo "--- [0] 时效性：镜像文件 vs 仓库源码 ---"
newest_src=$(find "$LF_SRC" -type f \( -name '*.c' -o -name '*.h' \) -printf '%T@ %p\n' \
             | sort -rn | head -1)
src_t=${newest_src%% *}; src_f=${newest_src#* }
img_t=$(stat -c '%Y' "$IMG")
note "最新源码: $(date -d "@$src_t" '+%m-%d %H:%M')  ${src_f#$REPO/}"
note "rootfs  : $(date -d "@$img_t" '+%m-%d %H:%M')  $(stat -c '%s' "$IMG") bytes"
if [ "${src_t%.*}" -gt "$img_t" ]; then
    bad "镜像比最新源码旧 —— 改动没进镜像，必须重编"
else
    ok "镜像不比源码旧"
fi

# ------------------------------------------------- 1. manifest 里的包与工具
echo
echo "--- [1] rootfs.manifest ---"
[ -f "$MANIFEST" ] || { bad "找不到 rootfs.manifest"; MANIFEST=/dev/null; }
for p in gf-npu libjpeg62 libv4l v4l-utils usbutils; do
    if grep -qE "^$p " "$MANIFEST" 2>/dev/null; then
        ok "$p   $(grep -E "^$p " "$MANIFEST" | head -1 | awk '{print $2, $3}')"
    else
        bad "$p 不在 manifest 里"
    fi
done

# ------------------------------------------------------- 2. dump 出二进制
echo
echo "--- [2] 从 rootfs.ext4 导出二进制（debugfs，无需 sudo）---"
mkdir -p "$TMP"; rm -f "$TMP"/gf_npu_probe "$TMP"/gf_camera
for f in gf_npu_probe gf_camera; do
    if debugfs -R "dump /usr/bin/$f $TMP/$f" "$IMG" >/dev/null 2>&1 && [ -s "$TMP/$f" ]; then
        ok "$f  $(stat -c '%s' "$TMP/$f") bytes"
    else
        bad "$f 导出失败 / 不在 /usr/bin"
    fi
done

# ------------------------------------------- 3. 架构 + 依赖（是不是我们的编译）
echo
echo "--- [3] 二进制属性 ---"
for f in gf_npu_probe gf_camera; do
    [ -s "$TMP/$f" ] || continue
    arch=$(file -b "$TMP/$f")
    note "$f: $arch"
    case "$arch" in
        *aarch64*|*ARM\ aarch64*) ok "$f 是 aarch64" ;;
        *) bad "$f 不是 aarch64" ;;
    esac
    # 摄像头要 MJPEG 就必须链到 libjpeg
    if [ "$f" = gf_camera ]; then
        if readelf -d "$TMP/$f" 2>/dev/null | grep -qi libjpeg; then
            ok "gf_camera 链到 libjpeg（-DGF_HAVE_JPEG 生效）"
        else
            warn "gf_camera 没链 libjpeg —— MJPEG 路径未启用，只剩 YUYV"
        fi
    fi
done

# ------------------------------------- 4. 内容比对：字符串必须来自当前源码
echo
echo "--- [4] 内容比对：二进制内嵌字符串 <-> 源码 ---"
#
# 判据是双向的：
#   (a) 二进制里有这个字符串   (b) 源码里也有这个字符串
# 两边都真，才能说"镜像里的二进制来自这份源码"。
#
# ⚠️ 选探针的铁律（踩过坑，见文件末尾"为什么不能随便挑字符串"）：
#   必须选**编译器无法静态证明其不可达**的字符串。
#   如果条件是编译期常量比较（例如 `bytes_needed > GF_BUF_SIZE`），
#   编译器会把不成立的分支连同 printf 一起删掉 —— 字符串不在二进制里，
#   不代表代码是旧的。本脚本因此只用下面这些"运行时才可能触发"的诊断文案。
#
# 词条格式：<二进制> <字符串> <源文件名>
CHECKS="
gf_npu_probe|gf_npu: staged weights + activations|gf_npu.c
gf_npu_probe|PL id ok (MAGIC|gf_npu.c
gf_npu_probe|SELFTEST PASS  class=|gf_npu.c
gf_npu_probe|scratch region too small for weight image|gf_npu.c
gf_npu_probe|scratch region too small for the activation pool|gf_npu.c
gf_npu_probe|golden content checks (bit-exact memcmp)|gf_npu_probe.c
gf_npu_probe|RESULT: PASS|gf_npu_probe.c
gf_npu_probe|CONTENT MISMATCH|gf_npu.c
gf_npu_probe|first difference at byte|gf_npu.c
gf_npu_probe|hardware FNV registers|gf_npu_probe.c
gf_npu_probe|software FNV1A of what the PL wrote|gf_npu_probe.c
gf_npu_probe|per-tile PL cycles:|gf_npu_probe.c
gf_camera|VIDIOC_DQBUF|gf_camera.c
gf_camera|majority-vote smoothing window|gf_camera.c
gf_camera|save the resized 96x96 RGB|gf_camera.c
gf_camera|gf_camera: using %s %dx%d|gf_camera.c
gf_camera|JPEG decode failed, skipping frame|gf_camera.c
"
while IFS='|' read -r bin needle srcfile; do
    [ -n "${bin:-}" ] || continue
    [ -s "$TMP/$bin" ] || continue
    hit_bin=0; hit_src=0
    strings -a "$TMP/$bin" | grep -qF "$needle" && hit_bin=1
    [ -f "$LF_SRC/$srcfile" ] && grep -qF "$needle" "$LF_SRC/$srcfile" && hit_src=1

    if [ "$hit_bin" = 1 ] && [ "$hit_src" = 1 ]; then
        ok "$bin <- '$needle'  ($srcfile)"
    elif [ "$hit_src" = 0 ]; then
        bad "探针写错了：'$needle' 不在 $srcfile 里（改脚本，别改镜像）"
    else
        bad "$bin 缺 '$needle'  ->  $srcfile 的改动没进镜像"
    fi
done <<< "$CHECKS"

# --------------- 5. 源码级一致性：抽源码里的诊断串，看命中率
echo
echo "--- [5] 反向一致性：源码里的诊断串有多少进了镜像 ---"
#
# 做法：从源文件里抽出**单行完整**的字符串字面量（长度 >= 18，含非字母的
# 诊断特征，如 ':' / ' ' / '%'），逐个在二进制里找。
#
# 为什么不要求 100%：一部分文案位于编译期恒假的死分支（见 [4] 的说明），
# 还有一部分是 printf 的分段拼接（跨行），抽取时按段算。因此这里看的是
# **命中率**，只要过半就说明这份源码确实被编了进去。
for pair in "gf_npu_probe:gf_npu.c" "gf_camera:gf_camera.c"; do
    bin=${pair%%:*}; srcfile=${pair##*:}
    [ -s "$TMP/$bin" ] || continue
    [ -f "$LF_SRC/$srcfile" ] || continue

    # 抽长度 >= 18 的字符串字面量。
    # 过滤掉三类噪声，它们**本来就不会**出现在二进制里：
    #   - #include 的头文件名（以 .h 结尾）
    #   - 纯标识符（没有空格/冒号/百分号）
    #   - 无小写字母的（宏名之类）
    mapfile -t lits < <(
        grep -oE '"[^"\\]{18,70}"' "$LF_SRC/$srcfile" \
        | sed 's/^"//; s/"$//' \
        | grep -vE '\.h$' \
        | grep -E '[a-z]{3,}' \
        | grep -E '[ :%]' \
        | sort -u
    )
    total=${#lits[@]}
    [ "$total" -gt 0 ] || { warn "$srcfile 里没抽到可用文案"; continue; }

    # 一次性 dump 二进制字符串，避免 shell 里重复调用
    strings -a "$TMP/$bin" > "$TMP/.strs.$bin"
    hit=0
    for l in "${lits[@]}"; do
        grep -qF -- "$l" "$TMP/.strs.$bin" && hit=$((hit+1))
    done
    pct=$(( hit * 100 / total ))
    note "$bin: 源码 $total 条候选文案，镜像命中 $hit 条 (${pct}%)"
    if [ "$pct" -ge 50 ]; then
        ok "$bin 命中率 ${pct}% => 二进制与这份源码一致"
    else
        bad "$bin 命中率仅 ${pct}% => 二进制可能不是这份源码编的"
        echo "        下一步：bash $(dirname "$0")/06_install_app.sh"
    fi
done

# ----- 5b. 构建日志指纹（供人工核对，不作为失败判据）
echo
echo "--- [5b] 构建任务日志指纹（仅供参考）---"
#
# ⚠️ 修正过的认识（2026-09-12）：
#   `do_compile` 的日志**恒定为一个很小的字节数**是**正常**的 ——
#   因为 do_compile 的函数体只有两条 gcc 命令，而 gcc 成功时**不输出任何东西**。
#   所以"三次日志大小相同"**不能**证明 sstate 短路；它只说明没有告警。
#   本段因此只打印信息，不做判定。
#   真正能证明"改动进了镜像"的，是上面 [4]/[5] 对**二进制内容**的检查。
WT=$(find "$PLNX/build/tmp/work" -maxdepth 5 -type d -name "1.0-r0" -path "*gf-npu*" 2>/dev/null | head -1)
if [ -n "$WT" ] && [ -d "$WT/temp" ]; then
    for t in do_unpack do_compile do_install do_package; do
        n=$(ls "$WT/temp/" 2>/dev/null | grep -c "^log\.$t\.[0-9]")
        [ "$n" -eq 0 ] && { note "$t: 无日志"; continue; }
        sizes=$(for x in "$WT/temp/"log.$t.[0-9]*; do stat -c '%s' "$x" 2>/dev/null; done \
                | sort -u | tr '\n' ' ')
        note "$t: $n 次, 不同字节数 = ${sizes:-(none)}"
    done
    note "（do_compile 恒为 ~85 B 属正常：gcc 成功时无输出）"
    if [ -f "$WT/temp/log.do_cleanall.2500" ]; then
        note "最近做过 do_cleanall（清过 sstate）"
    fi
else
    warn "找不到 gf-npu 的 work 目录（可能被 do_rm_work 清理了，正常）"
fi

# ------------------------------------------------------------- 版本指纹
echo
echo "--- [6] 指纹（贴给我，用来确认我们说的是同一份）---"
for f in gf_npu_probe gf_camera; do
    [ -s "$TMP/$f" ] || continue
    printf '  %-14s md5=%s\n' "$f" "$(md5sum "$TMP/$f" | cut -c1-16)"
done
printf '  %-14s md5=%s\n' "gf_npu.c" "$(md5sum "$LF_SRC/gf_npu.c" | cut -c1-16)"

echo
echo "=============================================================="
if [ "$fail" -eq 0 ]; then
    echo " RESULT: PASS  -- 镜像里的二进制确实来自仓库源码，可以写卡上板"
else
    echo " RESULT: FAIL  -- $fail 项不通过，别烧卡"
    echo
    echo " 若是 [4]/[5] 报'改动没进镜像'："
    echo "   bash $(dirname "$0")/06_install_app.sh"
    echo "   （投放源码 -> do_cleanall 清 sstate -> 全量重编 -> 自动再校验）"
    echo
    echo " 若是 [3] 报架构/依赖不对：检查 recipe 的交叉编译设置"
fi
echo "=============================================================="
echo
cat <<'NOTE'
--------------------------------------------------------------------
为什么不能随便挑一个字符串当"新代码标志"

本次踩到的坑：曾用 `Widen the reserved-memory node` 当回归探针，
它在源码里存在、编译也成功，但**永远搜不到** —— 于是误判成
"改动没进镜像"，并据此错误地怀疑了 Yocto 的 sstate 缓存。

真正原因：那句 printf 所在的条件是

    if (bytes_needed > (size_t)GF_BUF_SIZE)   // 578 KB > 16 MiB

两边都是**编译期常量**，条件恒假，于是 GCC 做了死代码消除，
把整个分支连同那条字符串一起删掉了。这是**正确且期望的**优化。

结论：挑探针字符串时，条件必须是**运行时**才能确定的
（例如依赖读到的寄存器、memcmp 的结果、V4L2 的返回值）。
本脚本上面用的探针都满足这一点。

补充：do_compile 的日志恒为 ~85 字节也是正常的 —— gcc 成功时无输出。
不能用"日志大小一样"推断 sstate 短路。
--------------------------------------------------------------------
NOTE
exit "$fail"
