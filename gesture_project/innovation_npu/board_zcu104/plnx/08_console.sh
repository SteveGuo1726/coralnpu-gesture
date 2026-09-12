#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# 08_console.sh -- ZCU104 串口控制台助手（FT4232H channel 0 = MPSoC UART0, 115200 8N1）
#
# 为什么需要它：ZCU104 的 USB-UART 是 FT4232H（JTAG + 3 UART 复合设备）。
# WSL2 看不到 USB，所以必须先用 usbipd 把它透传进来；透传后是 /dev/ttyUSB0..3，
# 其中控制台实测是 **/dev/ttyUSB1**（不是 ttyUSB0！2026-09-12 实板确认：
# ttyUSB1 上有 `gflinux login:` 提示符）。不要凭"channel A = ttyUSB0"猜，
# 用 `probe` 子命令实测哪个口吐登录提示符。
#
#   usage:
#     bash 08_console.sh list              # 列出串口设备 + 权限
#     bash 08_console.sh probe             # 逐个试点，找出哪个是控制台
#     bash 08_console.sh log [秒] [文件]    # 抓 N 秒输出（默认 30s -> console_YYYYmmdd_HHMMSS.log）
#     bash 08_console.sh send "<命令>" [秒] # 发一条命令并抓响应（默认 8s）
#     bash 08_console.sh shell             # 打开交互式会话（screen；Ctrl-A 然后 k 退出）
#
# 需要 root（/dev/ttyUSB* 默认 root:dialout，普通用户不在 dialout 组）。
#   要么用 sudo 跑本脚本，要么先：  sudo chmod 666 /dev/ttyUSB*
#
# 透传步骤（Windows 管理员 PowerShell，一次性）：
#   usbipd list                          # 找 0403:6011 / "USB Serial Converter A"
#   usbipd bind   --busid <BUSID>
#   usbipd attach --wsl --busid <BUSID>
#   用完：usbipd detach --busid <BUSID>
#
# 注意：attach 会把整个 FT4232H（含 JTAG 通道）交给 WSL。要用 Vivado 走 JTAG 前先 detach。

set -u

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# --- 解析调用者的家目录（见 PITFALLS.md #11）---
if [ -z "${GF_HOME:-}" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    GF_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
fi
if [ -n "${GF_HOME:-}" ] && [ -d "$GF_HOME" ]; then
    HOME="$GF_HOME"; export HOME
fi

BAUD="${BAUD:-115200}"
MOD="${1:-}"

die()  { echo "ERROR: $*" >&2; exit 2; }
info() { echo "--- $*"; }

# 默认设备：优先 ttyUSB0（= channel A = UART0 = 控制台）
DEV="${TTY:-}"
if [ -z "$DEV" ]; then
    if [ -e /dev/ttyUSB0 ]; then DEV=/dev/ttyUSB0
    else
        DEV="$(ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1)"
    fi
fi

need_dev() {
    [ -n "$DEV" ] || die "找不到任何串口设备。
  → 板载 FT4232H 还没有透传进 WSL。在 **管理员 PowerShell** 里：
      usbipd list                          # 找 0403:6011 「USB Serial Converter A」
      usbipd bind   --busid <BUSID>
      usbipd attach --wsl --busid <BUSID>
    然后在 WSL 里：
      sudo modprobe ftdi_sio usbserial && ls -l /dev/ttyUSB*"
    [ -e "$DEV" ] || die "$DEV 不存在"
}

# 配好 8N1 原始模式。
#
# 每个参数都是必要的，不是抄来的：
#   -echo         否则你发给板子的字符会被**本机**回显，看起来像板子在回话
#   raw          关掉本地行规程（我们只要透传字节）
#   -hupcl        ★ 关闭 fd 时**不要拉低 DTR**。log/send 每次都要开关串口，
#                  若开着 hupcl，DTR 抖动有可能复位板子或丢掉那段输出。
#   clocal        忽略调制解调器控制线（USB 串口没有真的 DCD/DSR）
#   -crtscts     不开硬件流控（板子那边也没开）
#   -ixon -ixoff 不开软件流控（否则 XON/XOFF 字节会被吃掉）
#   min 1 time 0  ★ 阻塞式读：至少等到 1 个字节。**绝不能用 min 0**——
#                   min 0 时无数据 read() 立即返回 0 字节，而 cat 把 0 字节当 EOF
#                   直接退出，于是 log/send 永远抓到 0 字节并误报"板子没回应"。
#                   （这个坑会把人骗去查电源和 SW6，实测踩过。）
setup_tty() {
    stty -F "$DEV" "$BAUD" cs8 -cstopb -parenb \
         -crtscts -ixon -ixoff -hupcl clocal \
         -icanon -echo -echoe -echok -echoctl -echoke \
         raw min 1 time 0 2>/dev/null || die "stty 配置 $DEV 失败（权限？不在 dialout 组？）"
}

# 候选设备列表：显式 $TTY 优先，否则扫常见节点。
candidates() {
    if [ -n "${TTY:-}" ]; then
        printf '%s\n' "$TTY"
        return
    fi
    ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
}

case "$MOD" in

# ------------------------------------------------------------------ list
list|"")
    info "串口设备"
    ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  (无)"
    info "当前用户 / 是否有 root"
    echo "  user=$(id -un)  uid=$(id -u)"
    id -nG | tr ' ' '\n' | grep -qx dialout && echo "  在 dialout 组 ✅" || echo "  不在 dialout 组（需要 sudo 或 chmod 666）"
    info "WSL 里的 FTDI 驱动"
    lsmod | grep -E 'ftdi_sio|usbserial' | sed 's/^/  /' || echo "  未加载 ftdi_sio/usbserial"
    ;;

# ------------------------------------------------------------------ probe
# 逐个串口发一个回车，看谁有回应。控制台在 U-Boot/内核/登录状态下都会吐东西。
probe)
    mapfile -t CANDS < <(candidates)
    if [ "${#CANDS[@]}" -eq 0 ]; then
        need_dev      # 复用那句可操作的报错并退出
    fi
    info "试点各串口（每个约 2 秒，发一个 \\r）"
    for d in "${CANDS[@]}"; do
        if ! stty -F "$d" "$BAUD" cs8 -cstopb -parenb -crtscts -ixon -ixoff \
                 -hupcl clocal raw -echo min 1 time 0 2>/dev/null; then
            echo "  $d : 配置失败（权限？）"
            continue
        fi
        T="$(mktemp)"
        # 先开读，再写，避免错过响应
        timeout 3 cat "$d" > "$T" 2>/dev/null &
        rd=$!
        sleep 0.4
        printf '\r' > "$d" 2>/dev/null
        sleep 1.2
        printf '\r' > "$d" 2>/dev/null
        wait $rd 2>/dev/null
        n=$(wc -c < "$T")
        echo "  $d : 收到 $n 字节"
        if [ "$n" -gt 0 ]; then
            sed 's/^/        | /' "$T" | head -12
        fi
        rm -f "$T"
    done
    echo
    echo "  提示：有输出且出现登录提示符的那个就是控制台。"
    echo "        实板实测是 /dev/ttyUSB1（不是 ttyUSB0），但请以 probe 结果为准。"
    echo "  用 TTY=/dev/ttyUSB1 bash $0 log 10  可以只盯某一个。"
    ;;

# ------------------------------------------------------------------ log
log)
    need_dev
    SECS="${2:-30}"
    OUT="${3:-$PWD/console_$(date +%Y%m%d_%H%M%S).log}"
    setup_tty
    info "抓取 $SECS 秒 -> $OUT"
    echo "  （期间请给板子上电 / 复位；Ctrl-C 可提前结束）"
    timeout "$SECS" cat "$DEV" | tee "$OUT" | sed 's/^/  | /'
    echo
    echo "  已保存：$OUT  ($(wc -l < "$OUT") 行, $(wc -c < "$OUT") 字节)"
    ;;

# ------------------------------------------------------------------ send
send)
    need_dev
    CMD="${2:-}"
    [ -n "$CMD" ] || die "用法: bash $0 send \"<命令>\" [等待秒数]"
    WAIT="${3:-8}"
    setup_tty
    T="$(mktemp)"
    info "发送: $CMD   （等 $WAIT 秒）"
    timeout "$WAIT" cat "$DEV" > "$T" 2>/dev/null &
    rd=$!
    sleep 0.3
    # 收尾用 \r：Linux 串口控制台的 tty 行规程默认有 ICRNL，CR 会被当回车。
    # （本机侧是 raw，所以发出去的字节原样不变。）
    printf '%s\r' "$CMD" > "$DEV"
    wait $rd 2>/dev/null
    if [ -s "$T" ]; then
        sed 's/^/  | /' "$T"
        echo "  （$(wc -c < "$T") 字节）"
    else
        echo "  （0 字节 —— 板子没有任何回应）"
        echo "  依次排查："
        echo "    ① 板子没上电 / 还在启动中"
        echo "    ② SW6 [4:1] 不是 OFF,OFF,OFF,ON（SD1 启动；ON=0）"
        echo "    ③ 这个串口不是控制台 —— 先跑  bash $0 probe"
        echo "    ④ 板子停在登录提示符，需要先输入用户名（PetaLinux 默认 root）"
    fi
    rm -f "$T"
    ;;

# ------------------------------------------------------------------ shell
shell)
    need_dev
    setup_tty
    if command -v screen >/dev/null 2>&1; then
        info "打开 screen $DEV $BAUD —— 退出：Ctrl-A 然后按 k（或 Ctrl-A \\）"
        exec screen "$DEV" "$BAUD"
    elif command -v socat >/dev/null 2>&1; then
        info "打开 socat $DEV —— 退出：Ctrl-C"
        exec socat -,raw,echo=0 "$DEV",raw,echo=0,b"$BAUD"
    else
        die "既没有 screen 也没有 socat"
    fi
    ;;

*)
    die "未知子命令: $MOD
  可用: list | probe | log [秒] [文件] | send \"<命令>\" [秒] | shell"
    ;;
esac
