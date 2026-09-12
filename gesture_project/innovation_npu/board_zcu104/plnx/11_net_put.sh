#!/usr/bin/env bash
#
# 11_net_put.sh -- 走以太网把一个文件送进板上（比串口快两个数量级）
#
# 前提
# ----
# 板子在同一链路上可达。ZCU104 与 PC 的 USB 网卡直连时 Windows 会自动拿到
# 169.254.0.0/16 的 APIPA 地址，所以**把板子也配进 169.254/16 就不需要改任何
# Windows 设置**：
#
#     ip link set eth0 up
#     ip addr replace 169.254.10.20/16 dev eth0
#
# 为什么不用 nc
# ------------
# 板上的 busybox nc 是精简版（`Usage: nc [IPADDR PORT]`），**没有 -l**，所以板子
# 不能当 nc 的服务端。改用板上的 python3 起一个一次性 TCP 接收器（本机固件有
# socket/base64/hashlib）。
#
# 串口只在"装接收器 + 启监听"这两步用一下（约 2 秒），文件本体走 TCP。
#
# usage:
#   PUSH_HOST=169.254.10.20 bash 11_net_put.sh <local-file> <remote-path> [mode]
#   PUSH_PORT=9999 ...        # 后改端口
#
# mode 默认 755（这是给二进制用的）；网页之类的数据文件要显式给 644。
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE="$(cd "$(dirname "$0")" && pwd)"
CONSOLE="$HERE/08_console.sh"

LOCAL="${1:-}"
REMOTE="${2:-}"
MODE="${3:-755}"
HOST="${PUSH_HOST:-169.254.10.20}"
PORT="${PUSH_PORT:-9999}"
DEV="${TTY:-/dev/ttyUSB1}"

die() { echo "11_net_put: $*" >&2; exit 2; }

if [ -z "$LOCAL" ] || [ -z "$REMOTE" ]; then
    sed -n '2,30p' "$0"
    exit 2
fi
[ -f "$LOCAL" ] || die "本地文件不存在: $LOCAL"
LOCAL_ABS="$(cd "$(dirname "$LOCAL")" && pwd)/$(basename "$LOCAL")"
SIZE=$(stat -c '%s' "$LOCAL_ABS")
LSUM=$(md5sum "$LOCAL_ABS" | cut -d' ' -f1)

command -v ping >/dev/null || die "本机没有 ping"
if ! ping -c 1 -W 1 "$HOST" >/dev/null 2>&1; then
    die "ping 不通 $HOST —— 先在板上跑：
      ip link set eth0 up
      ip addr replace 169.254.10.20/16 dev eth0
  并确认 PC 上那块 USB 网卡是连接状态（Windows 无人应答 DHCP 时会自己用 169.254/16）。"
fi

# 串口只能有一个写入者（同 09_board_put.sh 的理由）
if command -v flock >/dev/null 2>&1; then
    exec 9>"${TMPDIR:-/tmp}/gf-console-$(basename "$DEV").lock"
    flock -w 900 9 || die "拿不到 $DEV 的使用权"
fi

send() { TTY="$DEV" bash "$CONSOLE" send "$1" "${2:-4}" 2>&1; }

# 板上的一次性接收器。用 base64 从**单行**命令落地（理由同 09：多行 heredoc 会被
# 第二个写入者撕开，而且症状离原因很远）。只含单引号，便于嵌进双引号里。
_recv_b64() {
    printf '%s\n' \
        "import socket,hashlib,sys" \
        "port=int(sys.argv[1]); out=sys.argv[2]" \
        "s=socket.socket()" \
        "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)" \
        "s.bind(('0.0.0.0',port))" \
        "s.listen(1)" \
        "c,_=s.accept()" \
        "f=open(out,'wb'); h=hashlib.md5(); n=0" \
        "while True:" \
        "    d=c.recv(262144)" \
        "    if not d: break" \
        "    f.write(d); h.update(d); n+=len(d)" \
        "f.close(); c.close(); s.close()" \
        "print('NET_RECV',h.hexdigest(),n)" \
    | base64 -w0
}

echo "=============================================================="
echo " 11_net_put.sh  -- 以太网投放"
echo "=============================================================="
echo "  本地 : $LOCAL_ABS  ($SIZE bytes, md5 ${LSUM:0:16})"
echo "  板上 : $REMOTE  (mode $MODE)"
echo "  通道 : $HOST:$PORT  (串口 $DEV 只用于启停接收器)"

echo
echo "--- 1/4 装接收器（单行落地 + 编译自检）---"
blob="$(_recv_b64)"
send "python3 -c \"import base64;open('/tmp/gfrecv.py','wb').write(base64.b64decode('$blob'))\"" 4 >/dev/null
# 用内建 compile() 而不是 py_compile —— 板上的 python3 是精简版，没有 py_compile。
# 这一步是为了抓住"落地时被写坏"（语法错误），否则要等到传输完才发现，
# 而那时的症状会像"网络丢包"。
chk="$(send "python3 -c \"compile(open('/tmp/gfrecv.py').read(),'gfrecv','exec');print('RECV''_OK')\"" 5)"
case "$chk" in
    *RECV_OK*) echo "  ✓ /tmp/gfrecv.py 语法正确" ;;
    *) echo "$chk" | sed 's/^/    /'; die "接收器落地失败（见上面的板上回显）" ;;
esac

echo
echo "--- 2/4 板上起监听 ---"
# 上一次异常退出可能留下一个还在监听的接收器，那会让新的 bind 失败。
# 板上没有别的 python3 使用者，直接清掉是安全的。
send "killall python3 2>/dev/null; rm -f $REMOTE.part /tmp/gfrecv.log" 3 >/dev/null
# 目标目录必须先存在。接收器 open() 失败时进程会直接死掉，而那时 TCP 早已
# accept 过 —— 客户端可能已经把数据写进内核缓冲并"成功"返回，症状看起来像
# 网络问题。目标目录不在旧镜像里时（例如新增的 /usr/share/gf）就会撞上。
send "mkdir -p $(dirname "$REMOTE")" 3 >/dev/null
send "nohup python3 /tmp/gfrecv.py $PORT $REMOTE.part > /tmp/gfrecv.log 2>&1 &" 3 >/dev/null
# 给解释器和 bind 一点时间；下面 TCP 连不上就会报错，不会静默失败
sleep 1

echo
echo "--- 3/4 TCP 传输 ---"
t0=$(date +%s.%N)
if ! python3 - "$HOST" "$PORT" "$LOCAL_ABS" <<'PY'
import socket, sys
host, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), 5)   # 连不上会抛异常 -> 退出码非 0
s.settimeout(15)
with open(path, 'rb') as f:
    while True:
        d = f.read(262144)
        if not d:
            break
        s.sendall(d)
s.shutdown(socket.SHUT_WR)
s.close()
PY
then
    die "TCP 发送失败 —— 板上的监听没起来？（nc 不能当服务端，接收器是 python3，确认端口 $PORT 没被占）"
fi
t1=$(date +%s.%N)
secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
rate=$(awk -v s="$SIZE" -v t="$t1" -v u="$t0" 'BEGIN{d=t-u; if(d<=0)d=0.001; printf "%.0f", s/d/1024}')

echo
echo "--- 4/4 板上核对 ---"
res="$(send "sleep 1; cat /tmp/gfrecv.log; mv $REMOTE.part $REMOTE && chmod $MODE $REMOTE; md5sum $REMOTE | cut -d' ' -f1; wc -c < $REMOTE; ls -l $REMOTE" 8)"
got=$(printf '%s' "$res" | grep -oE 'NET_RECV [0-9a-f]{32} [0-9]+' | head -1)
gmd5=$(printf '%s' "$got" | awk '{print $2}')
glen=$(printf '%s' "$got" | awk '{print $3}')

echo "  用时 ${secs}s  (${rate} KiB/s)"
echo "  板上: md5=${gmd5:-?}  bytes=${glen:-?}"

if [ "$gmd5" = "$LSUM" ] && [ "$glen" = "$SIZE" ]; then
    echo
    echo "=============================================================="
    echo " OK  $REMOTE  ==  $LOCAL_ABS  ($SIZE bytes, md5 ${LSUM:0:16})"
    echo "=============================================================="
    exit 0
fi

echo
echo "  板上没报出 NET_RECV。完整回显："
printf '%s\n' "$res" | sed 's/^/    /'
die "板上的 md5/长度与本地不一致 —— 常见原因：目标目录不存在（接收器 open() 失败，
     进程立刻退出而 TCP 已 accept，看起来像网络问题）、端口被占、或 /tmp 写满。"
