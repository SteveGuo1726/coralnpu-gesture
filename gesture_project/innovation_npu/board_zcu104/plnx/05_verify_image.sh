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


REPO="${REPO:-$HOME/coralnpu-gesture}"
PLNX="${PLNX:-$HOME/gf_linux_ws/gf_linux}"
LF_SRC="$REPO/gesture_project/innovation_npu/board_zcu104/linux"
IMG="$PLNX/images/linux/rootfs.ext4"
MANIFEST="$PLNX/images/linux/rootfs.manifest"
# 临时目录放在 /tmp 并在退出时清理。
# **不要**放在 $HOME 下：04_make_sd.sh 的 GATE 0 会以 root 调用本脚本，root 会在
# 用户家目录里留下 root 属主的文件，之后非 sudo 运行就写不进去，从而误报 FAIL。
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gf_imgverify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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

# ------------------------------------- 2b. 运行手册里的命令是否真的存在
# 上板操作卡会让用户跑下面这几条。若其中某个在 rootfs 里不存在，
# 应该在写卡**之前**就知道，而不是在串口前才发现。
# 用 debugfs 查 inode：它对符号链接同样有效，而宿主机上的 [ -e ] 不行
# （绝对符号链接会按宿主机的 / 去解析，必然判成不存在）。
echo
echo "--- [2b] 上板操作卡会用到的命令 ---"
for p in /usr/bin/gf_npu_probe /usr/bin/gf_camera /usr/bin/v4l2-ctl \
         /usr/bin/lsusb /usr/bin/usb-devices; do
    if debugfs -R "stat $p" "$IMG" 2>/dev/null | grep -q '^Inode:'; then
        ok "$p"
    else
        bad "$p 在 rootfs 里不存在"
    fi
done
if debugfs -R "stat /lib/modules" "$IMG" 2>/dev/null | grep -q '^Inode:'; then
    ok "/lib/modules 存在（摄像头/UVC 模块要用）"
else
    bad "/lib/modules 不存在"
fi
# --view 用的网页。它不在二进制里，所以单独查一次；少了只会让页面变成
# 占位页（gf_camera 仍然正常跑），但那种降级在伸手够不到的板子上很难看出来。
if debugfs -R "stat /usr/share/gf/view.html" "$IMG" 2>/dev/null | grep -q '^Inode:'; then
    ok "/usr/share/gf/view.html 存在（--view 的页面）"
    # 内容也要对。曾经的真实故障是：二进制是新的、页面是旧的（页面走的是另一条
    # 投放路径），于是页面上少了新加的字段而板子上看不出来。用"必须有"和
    # "必须没有"两组 D3 探针卡住它。
    PAGE_TMP="$TMP/view.html"
    debugfs -R "dump /usr/share/gf/view.html $PAGE_TMP" "$IMG" >/dev/null 2>&1
    if [ -s "$PAGE_TMP" ]; then
        for needle in '当前结果' '逐帧准确率' '模型看到的范围' 'id="cls"'; do
            grep -qF "$needle" "$PAGE_TMP" \
                && ok "view.html 含 '$needle'" \
                || bad "view.html 缺 '$needle' -> 页面是旧的（bash 10_push_app.sh page）"
        done
        # 反向：被删掉的表决口径不许复活
        for banned in 'hist_smooth' 'votefill' '稳定帧准确率'; do
            grep -qF "$banned" "$PAGE_TMP" \
                && bad "view.html 仍含已删除的 '$banned' -> 页面是旧版" \
                || ok "view.html 不含已删除的 '$banned'"
        done
        # 页面上报的 /stats 字段与二进制必须对得上。注意这里先把 strings 落到
        # 文件再 grep：`strings | grep -q` 里 grep 命中即退出，写端吃 SIGPIPE，
        # 配上 pipefail 会让**成功**被判成失败（PITFALLS #21）。
        strs="$(strings -a "$TMP/gf_camera")"
        case "$strs" in
            *'"cls":%d'*) ok "gf_camera 的 /stats 用新字段 cls" ;;
            *)            bad "gf_camera 的 /stats 还是旧的 raw/smooth 字段" ;;
        esac
        case "$strs" in
            *votes*) bad "gf_camera 仍在 /stats 里输出 votes -> 表决代码没删干净" ;;
            *)       ok "gf_camera 的 /stats 里没有 votes" ;;
        esac
    else
        warn "无法从镜像里 dump view.html，跳过内容检查"
    fi
else
    warn "/usr/share/gf/view.html 不在镜像里 —— --view 会退回内置占位页"
fi

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
gf_camera|save the resized 96x96 RGB|gf_camera.c
gf_camera|gf_camera: using %s %dx%d|gf_camera.c
gf_camera|JPEG decode failed, skipping frame|gf_camera.c
gf_camera|rotating the NPU input %d degrees clockwise|gf_camera.c
gf_camera|camera digital zoom, %d..%d|gf_camera.c
gf_camera|continuing without the requested zoom|gf_camera.c
gf_camera|centred crop of %dx%d|gf_camera.c
gf_camera|gf_camera: viewer ready -- open this in the laptop browser:|gf_view.c
gf_camera|no frame yet|gf_view.c
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
for pair in "gf_npu_probe:gf_npu.c" "gf_camera:gf_camera.c" "gf_camera:gf_view.c"; do
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

# ---------------------------------------------------------------------------
# 7. 设备树 <-> 驱动常量一致性
#
# rootfs 校验通过只说明"二进制是这份源码"。它完全不能说明"这份二进制和板上那份
# 设备树说的是同一件事"。两者不一致时构建、写卡、启动全都正常，只在用户态第一次
# 访问那段内存时崩 —— 而且是没有内核日志的 SIGBUS，极难定位。
#
# 这里把 /dev/mem 会不会给出可用的映射，按内核源码的判定链完整推一遍：
#
#   arch/arm64/mm/mmu.c::phys_mem_access_prot()
#       !pfn_is_map_memory(pfn)          -> pgprot_noncached()      MT_DEVICE_nGnRnE
#       O_SYNC && pfn_is_map_memory(pfn) -> pgprot_writecombine()   MT_NORMAL_NC
#
#   pfn_is_map_memory() == memblock_is_map_memory()：范围必须在 memory 节点里，
#   且不带 MEMBLOCK_NOMAP。
#
# 所以下面四条缺一不可：
#   (a) 有一段 memory 覆盖 0x70000000..0x70FFFFFF  (=> pfn_is_map_memory 为真)
#   (b) reserved-memory 节点存在且没有 no-map        (=> 不会被打上 MEMBLOCK_NOMAP)
#   (c) 节点的地址/长度 == gf_npu.h 的 GF_BUF_*      (=> 软件和 DT 说同一件事)
#   (d) gf_npu.c 用 O_SYNC 打开 /dev/mem            (=> 拿到 Normal-NC 而不是 Cached)
#
# (a)(b) 任一条不成立，映射会退化成 Device-nGnRnE：`devmem` 那种单字访问看着没事，
# 但驱动的 memset/memcpy 一上去就 fault（Device 内存只保证 <=64bit 访问）。
# (d) 不成立则会拿到 Normal **Cached**，对非相干的 HP0 是错的。
# ---------------------------------------------------------------------------
echo
echo "--- [7] 设备树 <-> 驱动常量一致性 ---"
DTB="$PLNX/images/linux/system.dtb"
UB="$PLNX/images/linux/image.ub"
if [ ! -f "$DTB" ]; then
    bad "找不到 $DTB"
elif ! command -v dtc >/dev/null 2>&1; then
    warn "没有 dtc，跳过 [7]"
else
    while IFS= read -r _l; do
        case "$_l" in
            OK\ *)   ok   "${_l#OK }" ;;
            FAIL\ *) bad  "${_l#FAIL }" ;;
            NOTE\ *) note "${_l#NOTE }" ;;
        esac
    done < <(python3 - "$DTB" "$UB" "$LF_SRC/gf_npu.h" "$LF_SRC/gf_npu.c" <<'PY'
import re, os, subprocess, sys

dtb, ub, hdr, src = sys.argv[1:5]
def emit(tag, msg): print(f"{tag} {msg}")

def macro(path, name):
    try:
        t = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return None
    m = re.search(r'#define\s+%s\s+(0[xX][0-9a-fA-F]+|\d+)' % name, t)
    return int(m.group(1), 0) if m else None

base = macro(hdr, 'GF_BUF_PHYS_BASE')
size = macro(hdr, 'GF_BUF_SIZE')
if base is None or size is None:
    emit("FAIL", "gf_npu.h 里找不到 GF_BUF_PHYS_BASE / GF_BUF_SIZE")
    sys.exit(0)
emit("NOTE", "驱动常量: GF_BUF_PHYS_BASE=0x%08X  GF_BUF_SIZE=0x%X (%d MiB)"
     % (base, size, size >> 20))

def undtc(path):
    r = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', path],
                       capture_output=True, text=True)
    return r.stdout

dts = undtc(dtb)
if not dts.strip():
    emit("FAIL", "dtc 无法解析 %s" % dtb)
    sys.exit(0)
lines = dts.splitlines()

def block_of(name):
    """Return the text of the /<name> { ... } node, by brace matching."""
    for i, l in enumerate(lines):
        if re.match(r'\s*%s\s*\{' % re.escape(name), l):
            depth, out = 0, []
            for j in range(i, len(lines)):
                depth += lines[j].count('{') - lines[j].count('}')
                out.append(lines[j])
                if depth <= 0:
                    break
            return '\n'.join(out)
    return None

def nums(s):
    return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', s)]

# ---- memory 节点：所有范围 -------------------------------------------
mem = block_of('memory@0') or ''
ranges = []
for m in re.finditer(r'reg\s*=\s*<([^>]*)>', mem):
    v = nums(m.group(1))
    for k in range(0, len(v) - 3, 4):
        addr = (v[k] << 32) | v[k + 1]
        ln = (v[k + 2] << 32) | v[k + 3]
        ranges.append((addr, ln))
if not ranges:
    ranges = [(0, 0x80000000)]   # 没有 memory 节点时的内核默认
for a, l in ranges:
    emit("NOTE", "memory 范围: 0x%08X .. 0x%08X" % (a, a + l - 1))

covered = any(a <= base and base + size <= a + l for a, l in ranges)
if covered:
    emit("OK", "0x%08X..0x%08X 落在 memory 里 => pfn_is_map_memory() 为真" % (base, base + size - 1))
else:
    emit("FAIL", "0x%08X..0x%08X 不在任何 memory 范围里（被挖洞/挪出 RAM）"
         " => /dev/mem 会给出 Device-nGnRnE，驱动的 memset/memcpy 必崩" % (base, base + size - 1))

# ---- reserved-memory 节点 --------------------------------------------
rm = None
for i, l in enumerate(lines):
    if re.match(r'\s*reserved-memory\s*\{', l):
        depth, out = 0, []
        for j in range(i, len(lines)):
            depth += lines[j].count('{') - lines[j].count('}')
            out.append(lines[j])
            if depth <= 0:
                break
        rm = '\n'.join(out)
        break

if rm is None:
    emit("FAIL", "设备树里没有 reserved-memory 节点")
else:
    if re.search(r'\bno-map\b', rm):
        emit("FAIL", "reserved-memory 里出现了 no-map "
             "=> MEMBLOCK_NOMAP => Device-nGnRnE，必须去掉")
    else:
        emit("OK", "reserved-memory 无 no-map => 仍然算 RAM，不会被摘出线性映射")

    # 找目标地址对应的子节点
    want = '@%x' % base
    hit = None
    for i, l in enumerate(lines):
        if want in l and '{' in l:
            depth, out = 0, []
            for j in range(i, len(lines)):
                depth += lines[j].count('{') - lines[j].count('}')
                out.append(lines[j])
                if depth <= 0:
                    break
            hit = '\n'.join(out)
            break
    if hit is None:
        emit("FAIL", "reserved-memory 里没有 %s 的节点" % want)
    else:
        v = nums(re.search(r'reg\s*=\s*<([^>]*)>', hit).group(1))
        n_addr = (v[0] << 32) | v[1]
        n_len = (v[2] << 32) | v[3]
        if n_addr == base and n_len == size:
            emit("OK", "reserved-memory 节点 = 0x%08X + 0x%X，与 gf_npu.h 一致" % (n_addr, n_len))
        else:
            emit("FAIL", "DT 节点是 0x%08X + 0x%X，但 gf_npu.h 说的是 0x%08X + 0x%X"
                 % (n_addr, n_len, base, size))

# ---- 驱动是否用 O_SYNC -----------------------------------------------
try:
    s = open(src, encoding='utf-8', errors='replace').read()
except OSError:
    s = ''
m = re.search(r'open\(\s*"/dev/mem"\s*,([^)]*)\)', s)
if not m:
    emit("FAIL", "gf_npu.c 里找不到 open(\"/dev/mem\", ...)")
elif 'O_SYNC' in m.group(1):
    emit("OK", "gf_npu.c 以 O_SYNC 打开 /dev/mem => pgprot_writecombine (MT_NORMAL_NC)")
else:
    emit("FAIL", "gf_npu.c 打开 /dev/mem 没带 O_SYNC（%s）=> 会拿到 Normal Cached，对非相干 HP0 是错的"
         % m.group(1).strip())

# ---- image.ub 内嵌的那份 DTB 必须和 system.dtb 一致 -------------------
# 内核实际用的是 image.ub(FIT) 里内嵌的 DTB，不是 BOOT.BIN 里的 system.dtb。
# 两者不一致时板子会带着一份没人检查过的 DTB 启动。
if os.path.exists(ub) and subprocess.run(['sh','-c','command -v dumpimage'],
                                         capture_output=True).returncode == 0:
    import tempfile, hashlib
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'ub.dtb')
        subprocess.run(['dumpimage', '-T', 'flat_dt', '-p', '1', '-o', out, ub],
                       capture_output=True)
        if not os.path.exists(out):
            emit("FAIL", "无法从 image.ub 提取内嵌 DTB")
        else:
            h = lambda p: hashlib.md5(open(p, 'rb').read()).hexdigest()
            if h(out) == h(dtb):
                emit("OK", "image.ub 内嵌 DTB == system.dtb (%s)" % h(dtb)[:16])
            else:
                emit("FAIL", "image.ub 内嵌 DTB != system.dtb（%s vs %s）—— 内核用的是前者"
                     % (h(out)[:16], h(dtb)[:16]))
else:
    emit("NOTE", "跳过 image.ub 内嵌 DTB 比对（缺 image.ub 或 dumpimage）")
PY
    )
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
