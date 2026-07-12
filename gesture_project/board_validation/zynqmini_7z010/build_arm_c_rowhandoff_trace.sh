#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

clang_bin="${CLANG:-clang}"
ld_lld="${LD_LLD:-$repo_root/local_env/toolchains/lld-14/usr/bin/ld.lld-14}"

src="$script_dir/arm_host_inject_rowhandoff_trace.c"
obj="$script_dir/arm_host_inject_rowhandoff_trace_c.o"
elf="$script_dir/arm_host_inject_rowhandoff_trace.elf"
lds="$script_dir/arm_host_inject_rowhandoff_trace.ld"

if [[ ! -x "$ld_lld" ]]; then
  cat >&2 <<EOF
Missing ld.lld for ARM baremetal linking:
  $ld_lld

One user-local setup path is:
  cd /tmp
  apt-get download lld-14
  mkdir -p "$repo_root/local_env/toolchains/lld-14"
  dpkg-deb -x /tmp/lld-14_*.deb "$repo_root/local_env/toolchains/lld-14"
EOF
  exit 1
fi

"$clang_bin" \
  -target armv7-none-eabi \
  -mcpu=cortex-a9 \
  -marm \
  -O2 \
  -ffreestanding \
  -fno-builtin \
  -nostdlib \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fno-asynchronous-unwind-tables \
  -c "$src" \
  -o "$obj"

"$ld_lld" \
  -T "$lds" \
  -o "$elf" \
  "$obj"

llvm-readelf-14 -h "$elf" | rg 'Entry point address|Machine'
llvm-objdump-14 -d "$elf" | sed -n '1,40p'
