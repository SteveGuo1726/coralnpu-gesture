#!/usr/bin/env bash
#
# 09_board_put.sh -- 只走串口，把一个文件送进板上（不拔 SD 卡、不用读卡器）
#
# 为什么需要它
# ------------
# 每次改一行驱动代码就要拔卡、插读卡器、重写 431 MB 的 rootfs —— 这在迭代期是
# 纯粹的浪费。板子本身在跑 Linux、有 root shell、有 python3，而且启动分区
# (/dev/mmcblk0p1) 是 rw 挂载的。所以正确的迭代通道是：
#
#     串口 → base64 → 板上解码 → 直接覆盖 /usr/bin 里的那一个二进制 → 重跑
#
# 一个 526 KB 的可执行文件大约一分钟，改完立刻能验。SD 卡只在"最终固化一版
# 完整镜像"时才需要动。
#
# 为什么是 base64 + 持久 fd
# -------------------------
# 直接把二进制往控制台灌会被 tty 的行规程改字节（\r、\n、0x03、0x11、0x13 都
# 有特殊含义），所以先 base64 成可打印 ASCII。发送端用一个持久 fd 并设成 raw，
# 这样写出去的字节原样上行；tty 的发送缓冲在满时会阻塞，于是**天然按 115200
# 的线速做流控**，不需要自己 sleep 调速率。接收端先 `stty -echo`，否则板子会把
# 每个字节都回显回来，既慢又可能把两侧缓冲堵死。
#
# 传输完一定要校验：板上解码后打印 md5，与本地比。不一致就整段重来（最多 3 次）。
# 没有校验的串口传输就是在赌，而赌输的代价是一个"看起来能跑但结果随机错"的板子。
#
# usage:
#   bash 09_board_put.sh <local-file> <remote-path> [tty]
#
#   TTY=/dev/ttyUSB1 bash 09_board_put.sh gf_npu_probe /usr/bin/gf_npu_probe
#   BAUD=115200 bash 09_board_put.sh ../../images/linux/system.dtb /tmp/system.dtb
#
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE="$(cd "$(dirname "$0")" && pwd)"
CONSOLE="$HERE/08_console.sh"

LOCAL="${1:-}"
REMOTE="${2:-}"
DEV="${3:-${TTY:-}}"
BAUD="${BAUD:-115200}"
CHUNK="${CHUNK:-250}"      # base64 每行长度；远低于 tty 的 4096 行长限制
ATTEMPTS="${ATTEMPTS:-3}"

die() { echo "09_board_put: $*" >&2; exit 2; }

if [ -z "$LOCAL" ] || [ -z "$REMOTE" ]; then
    sed -n '2,40p' "$0"
    exit 2
fi
[ -f "$LOCAL" ]  || die "本地文件不存在: $LOCAL"
[ -x "$CONSOLE" ] || die "找不到 $CONSOLE"
command -v base64 >/dev/null || die "本机没有 base64"

# ------------------------------------------------------------------ 找控制台
if [ -z "$DEV" ]; then
    for d in /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$d" ] || continue
        # 只当 tty 存在还不够：要确认真的是有 shell 的那个口。
        # 同样不用 `| grep -q`（pipefail + SIGPIPE 会把成功判成失败）。
        _ping="$(TTY="$d" bash "$CONSOLE" send "echo GF_PING_$$" 3 2>/dev/null)"
        case "$_ping" in
            *GF_PING_$$*) DEV="$d"; break ;;
        esac
    done
fi
[ -n "$DEV" ] || die "没找到能响应命令的控制台串口；用 TTY=/dev/ttyUSBx 指定"

LOCAL_ABS="$(cd "$(dirname "$LOCAL")" && pwd)/$(basename "$LOCAL")"
SIZE=$(stat -c '%s' "$LOCAL_ABS")
LSUM=$(md5sum "$LOCAL_ABS" | cut -d' ' -f1)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gfput.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
B64="$TMP/payload.b64"
base64 -w "$CHUNK" "$LOCAL_ABS" > "$B64"
NLINES=$(wc -l < "$B64")
B64SUM=$(md5sum "$B64" | cut -d' ' -f1)
B64SIZE=$(stat -c '%s' "$B64")

echo "=============================================================="
echo " 09_board_put.sh  -- 串口投放"
echo "=============================================================="
echo "  本地   : $LOCAL_ABS  ($SIZE bytes, md5 ${LSUM:0:16})"
echo "  板上   : $REMOTE"
echo "  控制台 : $DEV @ $BAUD"
echo "  载荷   : base64 $B64SIZE bytes / $NLINES 行（每行 $CHUNK）"
echo "  预计   : 约 $(( (B64SIZE + 11519) / 11520 )) 秒纯线时 + 开销"

send() { TTY="$DEV" bash "$CONSOLE" send "$1" "${2:-4}" 2>&1; }

# 把解码器装到板上。用 heredoc 逐行发，避免任何嵌套引号：
# 板上的 shell 在执行 cat > file <<'EOF'，后续行就都进 heredoc。
#
# 这里刻意**不**用 `send ... | grep -q`：脚本开了 pipefail，而 grep -q 找到匹配
# 就立刻退出、可能让写管道的一端拿到 SIGPIPE，于是管道整体返回非零 —— 明明成功
# 也判成失败。而且失败时回显被 /dev/null 吃掉，完全没法排查。
install_decoder() {
    local out
    send "cat > /tmp/gfdec.py <<'PYPUT'" 2 >/dev/null
    send "import base64,hashlib,sys" 2 >/dev/null
    send "d=base64.b64decode(open(sys.argv[1],'rb').read())" 2 >/dev/null
    send "open(sys.argv[2],'wb').write(d)" 2 >/dev/null
    send "print('GF_DEC',hashlib.md5(d).hexdigest(),len(d))" 2 >/dev/null
    send "PYPUT" 2 >/dev/null
    out="$(send "python3 -c \"print('GF_DECODER_OK')\"" 3)"
    case "$out" in
        *GF_DECODER_OK*) return 0 ;;
    esac
    echo "  解码器安装失败，板上回显：" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
}

echo
if ! install_decoder; then
    die "板上 python3 不可用，或 heredoc 安装失败 —— 先手动确认：python3 -c 'print(1)'"
fi
echo "  解码器 /tmp/gfdec.py 已就位"

attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    echo
    echo "--- 传输尝试 $attempt/$ATTEMPTS ---"

    send "stty -echo 2>/dev/null; rm -f $REMOTE.b64 $REMOTE.tmp; cat > $REMOTE.b64" 2 >/dev/null

    exec 3<>"$DEV" || die "打不开 $DEV"
    stty -F "$DEV" "$BAUD" cs8 -cstopb -parenb -crtscts -ixon -ixoff \
         -hupcl clocal raw 2>/dev/null
    t0=$(date +%s.%N)
    while IFS= read -r _l; do printf '%s\n' "$_l" >&3; done < "$B64"
    printf '\004' >&3          # ^D = 行首 EOF，结束板上的 cat
    exec 3>&- 3<&-
    t1=$(date +%s.%N)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    rate=$(awk -v s="$B64SIZE" -v t="$t1" -v u="$t0" 'BEGIN{d=t-u; if(d<=0)d=0.001; printf "%.1f", s/d/1024}')

    sync_out=$(send "sync; md5sum $REMOTE.b64 2>/dev/null | cut -d' ' -f1; wc -c < $REMOTE.b64" 6)
    got_b64=$(printf '%s' "$sync_out" | grep -oE '[0-9a-f]{32}' | head -1)
    got_bytes=$(printf '%s' "$sync_out" | grep -oE '^[[:space:]]*[0-9]+' | tr -d ' ' | head -1)

    echo "  传输用时 ${secs}s  (${rate} KiB/s 上行)"
    echo "  板上 .b64: md5=${got_b64:-?}  bytes=${got_bytes:-?}"

    if [ "$got_b64" != "$B64SUM" ]; then
        echo "  ✗ base64 内容不一致（期望 $B64SUM）—— 重来"
        continue
    fi
    echo "  ✓ base64 逐字节一致"

    dec_out=$(send "python3 /tmp/gfdec.py $REMOTE.b64 $REMOTE; rm -f $REMOTE.b64" 8)
    dec_md5=$(printf '%s' "$dec_out" | grep -oE 'GF_DEC [0-9a-f]{32}' | awk '{print $2}')
    dec_len=$(printf '%s' "$dec_out" | grep -oE 'GF_DEC [0-9a-f]{32} [0-9]+' | awk '{print $3}')

    echo "  板上解码后: md5=${dec_md5:-?}  bytes=${dec_len:-?}"
    if [ "$dec_md5" = "$LSUM" ] && [ "$dec_len" = "$SIZE" ]; then
        send "stty echo 2>/dev/null" 3 >/dev/null
        echo
        echo "=============================================================="
        echo " OK  $REMOTE  ==  $LOCAL_ABS  ($SIZE bytes, md5 ${LSUM:0:16})"
        echo "=============================================================="
        exit 0
    fi
    echo "  ✗ 解码结果与本地不一致 —— 重来"
done

send "stty echo 2>/dev/null" 3 >/dev/null
echo
echo "=============================================================="
echo " FAIL  $ATTEMPTS 次都没能完整送达。别继续用它。"
echo " 排查：换更短的 CHUNK（CHUNK=120）、把线速降到 BAUD=57600、"
echo "       或插一根网线走 eth0（板上有 nc/wget/tftp，那样是秒级）。"
echo "=============================================================="
exit 1
