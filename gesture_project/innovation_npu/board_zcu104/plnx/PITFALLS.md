# PetaLinux 2023.2 on the ZCU104 — pitfalls actually hit

Everything below was hit while bringing up this project (2026-09-11 → 12). Each
entry records the exact symptom, the real cause, and the fix, so it does not
have to be rediscovered.

Ordering matters: several of these cost a full 20–40 minute build cycle each.

---

## 1. `en_US.UTF-8` locale must exist system-wide  (environment, blocks everything)

**Symptom A** — `petalinux-create` / `gen-machineconf` dies mid-way:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  locale::facet::_S_create_c_locale name not valid
Aborted (core dumped)
ERROR: Failed to run gen-machineconf
```

**Symptom B** — `petalinux-build` exits after ~0.5 s:

```
ERROR: Can't get compiler version from gcc --version output
```

**Cause** — `tools/xsct/bin/rdiArgs.sh:37` **hard-codes** `export LC_ALL="en_US.UTF-8"`.
The WSL image only had `C.UTF-8`. Two different failure modes follow:

- C++ tools `abort()` because `std::locale("en_US.UTF-8")` cannot resolve.
- BitBake's `get_host_compiler_version()` (`poky/meta/lib/oe/utils.py`) runs
  `gcc --version` with `stderr=STDOUT` and then regexes **only the first line**
  for a version number. A missing locale makes `/bin/sh` print
  `warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)` to stderr
  first, so the regex matches the warning instead of the version → `bb.fatal`.

**Verified reproduction** — `/bin/sh -c 'gcc  --version' 2>&1 | head -1`:

| environment | first line | result |
|---|---|---|
| no locale vars | `gcc (Ubuntu 11.4.0…)` | OK |
| `LOCPATH` only | `gcc (Ubuntu 11.4.0…)` | OK |
| `LC_ALL=en_US.UTF-8` + `LOCPATH` | `gcc (Ubuntu 11.4.0…)` | OK |
| **`LC_ALL=en_US.UTF-8`, no LOCPATH** | **`/bin/sh: warning: setlocale: …`** | **FAIL** |
| `LC_ALL=C.UTF-8` | `gcc (Ubuntu 11.4.0…)` | OK |

**Fix** — generate the locale system-wide (needs root; a `localedef` + `LOCPATH`
workaround is not enough because parts of the build chain do not inherit it):

```bash
sudo locale-gen en_US.UTF-8
```

`00_host_setup.sh` does this. Verified afterwards: `locale -a` shows
`en_US.utf8`, and `std::locale("en_US.UTF-8")` resolves.

---

## 2. `/bin/sh` must be bash, and i386 must be enabled

UG1144 requirements; `dash` breaks the build scripts and `zlib1g:i386` needs the
foreign architecture. `00_host_setup.sh` handles both:

```bash
sudo dpkg-reconfigure dash        # answer: No
sudo dpkg --add-architecture i386
```

Also note the 22.04 package-name drift from the UG1144 list:
`pylint3` → **`pylint`**, `tftpd` → **`tftpd-hpa`**, plus **`bc`**.
All in `00_host_setup.sh`.

---

## 3. `CONFIG_YOCTO_PARALLEL_MAKE` wants a bare number, not `-jN`

**Symptom**

```
ExpansionError ... ValueError: invalid literal for int() with base 10: '-j8'
```

**Cause** — `components/yocto/.../gen_plnx_machine.py` formats it itself:

```python
override_string += 'PARALLEL_MAKE = "-j %s"\n' % parallel_make
```

So writing `-j8` produces `PARALLEL_MAKE = "-j -j8"`, and Poky's
`parallel_make()` strips one `-j` then feeds `-j8` to `int()`.

**Misleading** — the Kconfig prompt shows
`Set number of parallel make -j (PARALLEL_MAKE) [-j8]`; that bracket is the
current value echoed back, not the required format.

**Fix** — `CONFIG_YOCTO_PARALLEL_MAKE="8"`. `petalinux-build` itself has no `-j`
option; parallelism is these Yocto settings only.

---

## 4. `package-management` is an **image feature**, not a recipe

**Symptom**

```
ERROR: Nothing RPROVIDES 'package-management'
  (but petalinux-image-minimal.bb RDEPENDS on or otherwise requires it)
```

**Cause** — the widely copied Vitis tutorial list mixes image features with real
packages. PetaLinux treats every entry in `user-rootfsconfig` as a **package** and
puts it in `IMAGE_INSTALL`. `package-management` is an `IMAGE_FEATURE`, so no
recipe provides it.

`rootfs_config` actually carries two separate symbols:

```
# CONFIG_imagefeature-package-management is not set     <-- the correct one
...
# user packages
CONFIG_package-management=y                             <-- the wrong one
```

**How to tell them apart** — a real package has a recipe
(`recipes-*/.../*.bb`); an image feature appears as `CONFIG_imagefeature-<name>`
and must **not** go into `user-rootfsconfig`.

**Fix** — enable `CONFIG_imagefeature-package-management=y`, drop the bogus
entry from `user-rootfsconfig` (`plnx_rootfs_packages.sh` does this).

---

## 5. DWC3 must stay in **DUAL_ROLE**; host-only breaks the vmlinux link

**Symptom**

```
aarch64-xilinx-linux-ld.bfd: drivers/usb/dwc3/core.o: in function `dwc3_remove':
core.c:(.text+0x580): undefined reference to `dwc3_gadget_exit_hibernation'
core.c:(.text+0x86c): undefined reference to `dwc3_gadget_exit_hibernation'
make[1]: *** [scripts/Makefile.vmlinux:34: vmlinux] Error 1
```

**Cause** — the Xilinx kernel calls a gadget-only helper from `core.c` **without**
a gadget guard:

- `drivers/usb/dwc3/core.c:2104` in `dwc3_remove`
- `drivers/usb/dwc3/core.c:2399` in `dwc3_suspend`

both inside `#ifdef CONFIG_PM_SLEEP`, while the definition lives in the
gadget-only `drivers/usb/dwc3/gadget_hibernation.c:399`. With
`CONFIG_USB_DWC3_HOST=y` and `GADGET`/`DUAL_ROLE` off, that file is not compiled
and the symbol is undefined.

`drivers/usb/dwc3/Kconfig` even says so under `USB_DWC3_HOST`:
*"thereby the gadget feature will be regressed"*.

**Fix** — keep the defconfig default:

```
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_DUAL_ROLE=y
```

Host behaviour comes from the device tree, which the **zcu104-revc board DTSI**
already provides:

```dts
&dwc3_0 {
    dr_mode = "host";
    snps,usb3_lpm_capable;
    maximum-speed = "super-speed";
};
```

Do **not** try to "optimise" this to host-only.

---

## 6. `app build` hangs forever inside `xsct` batch mode

**Symptom** — the Vitis software build script stalls at `app build` with no
further output (observed 4+ minutes of silence, no CPU use).

**Fix** — do not use `app build`. Create the platform, then compile with the
cross compiler directly (see `gcc_build_zcu104.sh` in the bring-up notes) or, as
this project now does for the Linux side, ship the sources as a Yocto recipe.

---

## 7. Things that are already fine — do not "fix" them

Verified by reading the generated artifacts; each of these would have cost a
25-minute kernel rebuild for nothing:

| Item | Fact | Evidence |
|---|---|---|
| `clk_ignore_unused` | **already** in bootargs | `images/linux/system.dtb` → `chosen/bootargs` |
| `CONFIG_DEVMEM=y` | **already on** | kernel `.config` |
| `# CONFIG_STRICT_DEVMEM is not set` | **already off** | kernel `.config` |
| `CONFIG_UIO_PDRV_GENIRQ=m` | available as fallback | kernel `.config` |
| `v4l2-ctl` / `lsusb` | **already in the rootfs** | `rootfs.manifest` → `v4l-utils 1.23.0`, `usbutils 014` |
| `lsusb` is a **symlink**, not a file | `/usr/bin/lsusb` → `/usr/bin/lsusb.usbutils` (**absolute** link, Yocto `update-alternatives`); the real binary is 301312 B | `debugfs -R "stat /usr/bin/lsusb"` → `Type: symlink`, `Fast link dest: "/usr/bin/lsusb.usbutils"` |
| **PL is configured by the FSBL, from inside `BOOT.BIN`** | the bitstream is baked into `BOOT.BIN` by `petalinux-package --boot ... --fpga system.bit`. **`boot.scr` does not load `system.bit`** — it only `fatload`s `image.ub` and `bootm`s it | `BOOT.BIN` 21 073 168 B = `system.bit` 19 311 211 B + 1 761 957 B (FSBL/PMUFW/ATF/U-Boot); 3 of 6 sampled 64-byte windows of `system.bit` appear **verbatim** in `BOOT.BIN` |
| PL clock not claimed by a driver | handled by `clk_ignore_unused` | above |
| SD boot | already the default (`root=/dev/mmcblk0p2`) | `configs/config` |

> The `BOOT.BIN` row matters: drop `--fpga` from the packaging step and the board
> still boots Linux happily, but the PL is never programmed — the NPU register
> reads come back dead and `gf_npu_probe` fails with no obvious cause. Copying
> `system.bit` onto the FAT partition (as `04_make_sd.sh` does) is **not** what
> programs the PL; `boot.scr` has no `fpga load` in it.

A kernel config fragment is checksummed, so **adding only comments** to it also
invalidates the kernel and forces a rebuild. Keep findings in this file, not in
`kernel_uvc.cfg`.

---

## 8. Compile-time-constant conditions mean diagnostic strings vanish from the binary

**This one wastes hours if you don't know it.** Symptom: you add a diagnostic
`fprintf`, the code compiles cleanly, but `strings` on the binary does not show
the message — so you conclude the new code never got compiled in and go hunting
in the build system. It is nothing of the sort.

**Concrete case in this project.** `gf_npu.c` guards an arena-bound check with:

```c
const size_t bytes_needed = /* a sum of sizeof() and #define'd byte counts */;
if (bytes_needed > (size_t)GF_BUF_SIZE) {      /* 578 KB > 16 MiB -- always false */
    fprintf(stderr, "gf_npu: device-tree scratch region too small: ..."
                    "Widen the reserved-memory node in system-user.dtsi.\n");
    return -1;
}
```

Both sides are **compile-time constants**, so GCC proves the branch is dead and
deletes it along with the string literals. Neither
`Widen the reserved-memory node` nor
`device-tree scratch region too small` appears in the ELF.

Meanwhile strings whose condition depends on **runtime** data survive:

| string | condition | in the ELF? |
|---|---|---|
| `staged weights + activations` | normal path | yes |
| `PL id ok (MAGIC` | normal path | yes |
| `first difference at byte` | depends on memcmp result | yes |
| `CONTENT MISMATCH` | depends on memcmp result | yes |
| `scratch region too small for weight image` | depends on a runtime table | yes |
| `device-tree scratch region too small` | **constant comparison** | **no** |
| `Widen the reserved-memory node` | **constant comparison** | **no** |

**Rule** — when picking a string to prove "the new code is in the binary", the
condition guarding it must depend on something the compiler cannot fold:
a register read, a `memcmp` result, an `ioctl` return. Never pick a message
guarded by a comparison between constants.

Two related non-pitfalls, so nobody chases them again:

- **`log.do_compile` is always ~85 bytes.** It contains only
  `DEBUG: Executing shell function do_compile` and `finished`. `gcc` prints
  nothing on success and the recipe's `do_compile` is just two `gcc` calls, so
  identical log sizes across runs are **normal**, not evidence of caching.
- **`WORKDIR` being empty except `temp/` is normal.** `do_rm_work` deletes the
  sources and `recipe-sysroot` after the build finishes. This is not a failure
  and not evidence that unpacking did not happen. To inspect the sources, run
  `petalinux-build -c gf-npu -x do_unpack` first.

The real verification is in `05_verify_image.sh` sections `[4]` and `[5]`: it
dumps the ELF out of `rootfs.ext4` with `debugfs` (no root needed) and matches
strings **both ways** between the binary and the source.

For completeness, `file://` sources genuinely do not contribute a content hash
to Yocto's sstate signature, so `do_cleanall` is still the correct response when
you want a guaranteed recompile — but it was **not** the cause of this incident.

---

## 9. `MACHINE_NAME` is what makes the ZCU104 native

Without `DTG Settings → MACHINE_NAME = zcu104-revc`, the generated device tree is
a generic `zynqmp-generic-xczu7ev` one and you have to hand-write PHY, USB and SD
nodes. With it, DTG merges the official board DTSI and you get for free:

- `&usb0 : phys = <&psgtr 2 PHY_TYPE_USB3 0 2>` (PS-GTR lane 2, ref clk 2)
- `&dwc3_0 : dr_mode = "host"`, `maximum-speed = "super-speed"`
- `&sdhci1` with the ZCU104-specific SD compatibility fixups
- 128 MB CMA in `chosen`

Confirm it took effect by checking for two things together:

```bash
grep -r 'YAML_DT_BOARD_FLAGS' build/conf/machine/*.conf     # ?= "{BOARD zcu104-revc}"
grep MACHINE_NAME <dtg log>                                 # [zcu104-revc]
```

and then, on the built tree:

```bash
dtc -I dtb -O dts images/linux/system.dtb | grep -E 'dr_mode|usb3-phy'
```

---

## 10. WSL workflow notes

- **Never** run big file operations over `/mnt/*`. The PetaLinux installer reads
  its payload repeatedly; from `/mnt/c` it measured **31 MB/s** because of 9p.
  Copy the installer to ext4 first — an order of magnitude faster.
- PetaLinux **only** installs on Linux (RHEL/CentOS/Ubuntu). AMD's own guidance
  for Windows users is "a virtual machine running one of these Linux operating
  systems", i.e. WSL2 is the supported path, not a workaround.
- Vivado / Vitis / XSCT stay on the **Windows** side (`E:\Xilinx`); WSL only
  launches them through `cmd.exe`. Synthesis, implementation, bitstream and JTAG
  programming are Windows-native processes.
- The whole `petalinux-config` menu tree can be driven non-interactively: write
  `project-spec/configs/config` and run `petalinux-config --silentconfig`. No
  menuconfig interaction is ever required.

---

## 11. `sudo` resets `$HOME` to `/root`, so the scripts looked in the wrong tree

**Symptom (real, 2026-09-12):**

```
$ sudo bash 04_make_sd.sh /dev/sde
ERROR: missing /root/gf_linux_ws/gf_linux/images/linux/BOOT.BIN
       (run plnx_driver.sh package first)
$ ls ~/gf_linux_ws/gf_linux/images/linux/BOOT.BIN      # it is right there
```

The image existed the whole time. The script was looking under `/root`.

**Cause.** These scripts need root (`parted` / `mkfs` / `dd` / `mount`), but the
PetaLinux tree and the git repo live under the **invoking** user's home. `sudo`
resets `$HOME`, so any bare `$HOME` in the script silently points at the wrong
tree. Line 30 was `PROJ="${PROJ:-$HOME/gf_linux_ws/gf_linux}"`.

**Same root cause had four instances**, and only the first one is obvious:

| script | it looked for | would have failed as |
|---|---|---|
| `04_make_sd.sh` | `$HOME/gf_linux_ws/gf_linux` | `missing /root/.../BOOT.BIN` |
| `05_verify_image.sh` | `$HOME/coralnpu-gesture`, `$HOME/gf_linux_ws/...` | `RESULT: FAIL`, phantom "stale image" |
| `06_install_app.sh` | `$HOME/coralnpu-gesture`, `$HOME/petalinux/2023.2` | `找不到源码目录` |
| `07_make_sd_image.sh` | `$HOME/gf_linux_ws/gf_linux` | `缺少 /root/.../BOOT.BIN` |

`05` is the dangerous one: `04`'s **GATE 0 calls it**, so under `sudo` the gate
itself would break — and it would have reported a *content* failure, which reads
like "your image is stale" rather than "I looked in the wrong directory".

**Secondary hazard (subtler, same root cause).** `05`'s scratch dir used to be
`$HOME/gf_linux_ws/_imgverify`. When `04` runs it as root, root owns that
directory and the dumped ELFs. The next **non-sudo** run then cannot overwrite
them, the `debugfs` dump fails, and `05` reports `FAIL` for every probe — a
completely spurious failure caused by file ownership.

**Fix (both, in the same commit):**

1. Every script resolves the caller's home before using it, and exports it:

   ```bash
   if [ -z "${GF_HOME:-}" ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
       GF_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
   fi
   if [ -n "${GF_HOME:-}" ] && [ -d "$GF_HOME" ]; then
       HOME="$GF_HOME"; export HOME
   fi
   ```

   `GF_HOME=/path` overrides explicitly when the guess is wrong.
2. `05` now uses `TMP="$(mktemp -d ...)"` + `trap 'rm -rf "$TMP"' EXIT`, so it
   leaves nothing behind regardless of who runs it.

**Also fixed in the same pass:** `04` located `05`/`06` with
`dirname "$0"`. That is only correct while `$0` carries a directory component;
`07` already used the robust form. `04` now does
`HERE="$(cd "$(dirname "$0")" && pwd)"` too.

**Why it went unnoticed.** The failure only exists under `sudo`. Every earlier
run of these scripts in this project was as the normal user (`05`, `06`) or was
never executed end-to-end (`04`, `07` — they had only been syntax-checked).
"Syntax OK" cannot catch this class of bug; **only running the thing can.**

**How to reproduce a `sudo` environment without being root** — this is the test
worth keeping:

```bash
env HOME=/root SUDO_USER=<your-user> bash 04_make_sd.sh <device>
```

Fake `HOME` and `SUDO_USER` are enough to exercise the whole resolution path,
with no `sudo`, no password, and no risk. Use it on any script that has to run
as root. (Verify the negative case too: strip the resolve block and confirm the
`/root/...` error comes back — otherwise you have not proven the fix does
anything.)

---

## 12. A false alarm to recognise: counting `b'\r'` does not count CR bytes

While validating the fix above, a probe printed `CR bytes = 1` for
`06_install_app.sh` and `0` for the others. That reads like a stray carriage
return. It was not.

In a Python f-string, `f"...{d.count(b'\\r')}"` contains the bytes literal
`b'\\r'`, which is **backslash followed by `r`** — two printable characters, not
a CR byte. What it actually counted was the intentional text `$'\r'` inside
`06`'s CR-detection gate. The real check is:

```bash
python3 -c "d=open('f','rb').read(); print(d.count(b'\r\n'), d.count(b'\r')-d.count(b'\r\n'))"
```

Always confirm a suspected stray CR by locating its byte offset and printing the
surrounding bytes — not by trusting a count whose literal you have not read.
Related: `grep -c $'\r'` also matches the *text* `\r` in a script that mentions
it, and `grep sde /proc/mounts` matches `nsdelegate`.

---

## 13. `[ -e ]` on a mounted foreign rootfs is wrong for absolute symlinks

**Symptom (real, 2026-09-12, right after the first SD write):**

```
OK   /usr/bin/gf_npu_probe
OK   /usr/bin/gf_camera
OK   /usr/bin/v4l2-ctl
MISS /usr/bin/lsusb                      <-- wrong
WARNING: some expected files are missing - check the build
```

`lsusb` was there the whole time.

**Cause.** `04_make_sd.sh` mounts the freshly written `p2` read-only at
`$ROOTMNT` and checks `[ -e "$ROOTMNT/$p" ]`. But `test -e` **follows the
symlink**, and the link is **absolute**:

```
/usr/bin/lsusb -> /usr/bin/lsusb.usbutils
```

The kernel resolves an absolute target against the **host's** root, not against
`$ROOTMNT`. The host (WSL) has no `/usr/bin/lsusb.usbutils`, so the test fails.
Reproduce in three lines:

```bash
T=$(mktemp -d); mkdir -p "$T/usr/bin"
ln -s /usr/bin/lsusb.usbutils "$T/usr/bin/lsusb"
[ -e "$T/usr/bin/lsusb" ] && echo present || echo MISSING   # -> MISSING
[ -L "$T/usr/bin/lsusb" ] && echo symlink                   # -> symlink
```

**Fix.** Resolve the target **inside** the mounted tree — and do not simply
accept any symlink, or a *dangling* one would pass:

```bash
ent="$ROOTMNT/$p"; shown="$p"
if [ -L "$ent" ]; then
    tgt="$(readlink "$ent")"; shown="$p  -> $tgt"
    case "$tgt" in
      /*) target="$ROOTMNT$tgt" ;;                 # absolute
      *)  target="$(dirname "$ent")/$tgt" ;;        # relative
    esac
else
    target="$ent"
fi
[ -e "$target" ] && echo "  OK   /$shown" || echo "  MISS /$shown"
```

Four cases must be exercised, not just the happy one: absolute link with the
target present (OK), **dangling** absolute link (MISS — a bare `[ -L ]` test
gets this wrong), relative link with the target present (OK), plain missing path
(MISS).

**Two general rules this yields:**

1. **Checking paths inside someone else's root is not the same as checking paths
   inside yours.** Anything that follows a link is suspect. The same trap
   applies to `debugfs`, `chroot`, `find -L`, and `/proc` inspection.
2. **Verify the write, then verify the verifier.** The write was perfect; the
   alarm was mine. When a check fires, first ask whether the *check* is sound —
   especially when every other line of evidence says the artifact is fine.

`05_verify_image.sh` was never affected because it queries `debugfs` (inode
lookups, no symlink following). It now also has a `[2b]` section that confirms
every command the on-board runbook tells you to type actually exists in the
rootfs — so this class of surprise is caught **before** the card is written.

---

## 14. `no-map` reserved memory + `/dev/mem` hangs the CPU on arm64 (kernel 6.1)

**This is the bug that finally surfaced when the Linux side ran on real hardware
for the first time (2026-09-12).** The board booted Linux fine, the camera
enumerated, and `busybox devmem 0xa0000000` read the NPU magic `0x47464E50`
("GFNP") — but `gf_npu_probe` died with `Bus error` (SIGBUS, `sig=7`) before
printing anything, and `busybox devmem 0x70000000` **hung the CPU** (rcu_sched
stall, busybox stuck in the running state).

**Symptom:**

```
$ gf_npu_probe
Bus error                          # SIGBUS, no output at all
$ busybox devmem 0xa0000000 32     # 0x47464E50  -> PL register, fine
$ busybox devmem 0x70000000 32     # -> HANG (rcu_sched stall)
```

**Cause.** The NPU scratch buffer at `0x70000000` (16 MB) was reserved with a
`no-map` `reserved-memory` node. The comment in `system-user.dtsi` claimed that
`no-map` == `memblock_remove()` and therefore made the range "no longer RAM".
**That was wrong.** `no-map` actually calls `memblock_mark_nomap()`:

- the range **stays** in the kernel's memory map (`pfn_valid()` is still true),
- it is only **dropped from the linear map**,
- so `/dev/mem` maps it **cacheable** (it still looks like RAM), but there is
  **no linear-map backing** → the first access hangs / faults.

The baremetal JTAG bring-up (`0x600D600D`) never hit this because baremetal uses
a flat 1:1 mapping and has no `no-map` reservation at all.  So the Linux
`/dev/mem` + `no-map` path had never actually been exercised before.

**Fix.** Don't use `no-map`.  Carve a 16 MB **hole** in the memory node instead,
so the range is genuinely *not* System RAM; `/dev/mem` then maps it with
`pgprot_noncached` (non-cached, which is exactly what the non-coherent HP0
design wants — no flush/invalidate on either side):

```dts
/ {
	/* split the XSA's single 2 GiB bank around 0x70000000 */
	memory@0 {
		device_type = "memory";
		reg = <0x0 0x00000000 0x0 0x70000000>,	/* 0 .. 1.75 GiB */
		      <0x0 0x71000000 0x0 0x0EF00000>;	/* .. 2 GiB-1 MiB */
	};
};
```

The hole is still physical DDR (the controller decodes the full 2 GiB), so the
NPU's HP0 master reaches it unchanged; only the kernel stops treating it as RAM.

**Diagnosis method worth reusing** (bare `busybox devmem`, no tools to install):

```bash
busybox devmem 0xff000000 32   # PS UART -> returns a value => /dev/mem works
busybox devmem 0xa0000000 32   # PL register -> 0x47464E50 "GFNP" => PL is up
busybox devmem 0x70000000 32   # scratch -> HANG => the reserved region is broken
```

Reading the .bit ASCII header (`part`, `date`, `time`) also proved the bitstream
was current and identical to the one inside the XSA (`md5` matched
`images/linux/system.bit`), ruling out a stale bitstream before blaming the DT.

**The deeper lesson.** The whole Linux-side "it works" narrative had been built
on the baremetal JTAG result (`36.96 FPS`), not on the SD-boot Linux path.  The
first time anyone ran `gf_npu_probe` from Linux, it crashed.  Nothing in the
design docs would have caught it — the `no-map` comment actively *asserted the
wrong mechanism*.  Assume nothing works until it has been run on the actual
target, in the actual boot mode.

### 14b. Second layer: the mapping it left behind was Device-nGnRnE, which caps access width

The `no-map` -> memory-hole fix **did** work: after it, `busybox devmem` could
read *and* write `0x70000000` (and its neighbours) with no hang.  But
`gf_npu_probe` still died with SIGBUS — and this time **`dmesg` and
`journalctl -k` showed no `Unhandled fault` line at all**, only the audit
record.  No kernel log for a SIGBUS is the tell: it is not the kernel's fault
handler rejecting an access, it is the CPU refusing an instruction.

What /dev/mem hands out depends only on `pfn_valid()` (see
`arch/arm64/mm/mmap.c phys_mem_access_prot`):

| range state | mapping | what it permits |
|---|---|---|
| `!pfn_valid` (hole, or `no-map` + no linear map) | `pgprot_noncached` = **Device-nGnRnE** | only <= 64-bit, size-aligned accesses |
| `pfn_valid` + `O_SYNC` | `pgprot_writecombine` = **Normal Non-Cacheable** | any width, unaligned ok |
| `pfn_valid`, no `O_SYNC` | cacheable | any width (but needs flush/invalidate) |

So carving the hole traded one bug for another: **Device-nGnRnE**.  And the
driver does exactly the two things Device-nGnRnE forbids:

- `memset(g_bufs, 0, GF_BUF_SIZE)` — glibc memset uses **`DC ZVA`**, which the
  architecture defines only for *Normal* memory;
- `memcpy(...)` in the weight staging — 128-bit `STP`/`LDP`, above the 64-bit
  Device-memory limit.

Hence the signature: **`devmem` (single 32-bit accesses) reads and writes fine,
while the driver faults.**  Single-word access is the loosest case and cannot
see a width/alignment restriction.

**Fix:** leave the range as **System RAM** — plain `reserved-memory`, no
`no-map`, and no hole in the memory node — so `pfn_valid()` stays true and the
driver's existing `O_SYNC` open selects **Normal Non-Cacheable**
(`pgprot_writecombine`).  Still uncached (which is what the non-coherent HP0
port needs), but with no access-width restriction.

```dts
reserved-memory {
    npu-buffers@70000000 {
        reg = <0x0 0x70000000 0x0 0x1000000>;   /* NO no-map */
    };
};
```

**Two debug lessons from this round:**

1. **A SIGBUS with no kernel fault log is not the kernel's memory fault.** Do not
   go looking for "Unhandled fault"; look at what instruction the CPU refused.
2. **`devmem` passing is not the driver passing.** It only does aligned
   8/16/32/64-bit accesses — the one case every mapping type allows.  When the
   driver touches a region over a range with `memcpy`/`memset`, test with those,
   not with `devmem`.
3. Instrument before theorising. `GF_DBG` markers on **stderr** (unbuffered) are
   what survive a hard fault; `printf` to a line-buffered stdout only appears
   after the `\n`, so a crash mid-function is completely silent.

---

## 15. Do not let correctness depend on a memory attribute — make the driver mapping-agnostic

The fix in #14b makes the *device tree* right.  But the previous round burned
three flash-and-reboot cycles discovering DT problems one at a time, which is the
expensive way to learn them.  The lesson is bigger than the fix:

> A userspace driver that reaches a PL buffer through `/dev/mem` can be handed
> either `MT_NORMAL_NC` or `MT_DEVICE_nGnRnE` depending on a device tree it does
> not control.  `memcpy`/`memset`/`memcmp` are correct under one and **fault**
> under the other.  So do not use them on that region.

`gf_copy()`, `gf_zero()` and `gf_diff()` in `gf_npu.c` do the bulk work 32 bits
at a time through a `volatile` pointer.  That is legal under **both** mappings:

| mapping | 8/16/32/64-bit | DC ZVA / 128-bit |
|---|---|---|
| MT_NORMAL_NC (`pgprot_writecombine`) | ok | ok |
| MT_DEVICE_nGnRnE (`pgprot_noncached`) | ok | **fault** |

Cost: a few microseconds per frame against a 27 ms frame.  It buys independence
from a file we only get to change by rewriting the SD card — which is precisely
the thing we cannot afford to iterate on.

Two details that are easy to get subtly wrong:

* The loops must go through `volatile`.  A plain `uint8_t *` lets `-O2`
  auto-vectorise the loop straight back into NEON `LDP/STP`, i.e. back into the
  fault.  The `volatile` qualifier is load-bearing, not decoration.
* Byte accesses are always legal on Device memory (the restriction is a *maximum*
  access size, not a minimum), so the FNV1A and comparison passes were already
  fine and stay byte-wise.

Note the asymmetry: **ordering** still needs the explicit barrier from #16 even
under Device, so the two fixes are independent.

Related, and worth internalising: the baremetal driver got away with none of this
because `Xil_SetTlbAttributes()` put its buffers in Device memory, where the
ordering rules are stronger — and because a single-threaded baremetal loop does
not stress the store buffer.  **"It worked on baremetal" is not evidence about
the Linux mapping.**  Both of this round's real bugs (the width restriction, and
the missing barrier) are invisible on the baremetal path.

---

## 16. The scratch region is weakly ordered — a barrier is required, and it was missing

Once #14b makes the mapping `MT_NORMAL_NC`, stores into it are **buffered and
weakly ordered**.  The register block, by contrast, is `MT_DEVICE_nGnRnE`, where
accesses *are* ordered among themselves.  That difference is the whole bug:

```c
gf_copy(g_in_rgb, rgb96, GF_RGB_BYTES);   /* Normal-NC: may sit in a write buffer */
...
REG(GF_CONTROL) = 2U;                     /* Device: visible to the PL immediately */
```

The PL can therefore start DMA-ing the input before the pixels have reached DDR,
and the failure mode is *wrong numbers*, not a crash — the most expensive kind.

Two barriers per handshake, and they are not the same:

* **before the doorbell**: full `dsb sy`, not `dmb`.  The PL is not an observer in
  the CPU's shareability domain, so the stores must have *reached DDR*, not merely
  be *ordered* with respect to each other.
* **after the PL reports done, before reading the buffer back**: so the CPU cannot
  speculatively consume a half-written tensor.

`GF_MB()` in `gf_npu.c` is `dsb sy` on arm64.  It is placed at all three doorbells
(`GF_CONTROL = 2` used twice, `GF_WEIGHT_DMA_CONTROL = 2`) and in
`wait_layer_done()` on the success path.  Cost ≈ 1 µs per frame; not measurable.

**How this was found:** by diffing the Linux port against the baremetal driver it
claims to mirror.  The baremetal code has exactly one barrier
(`gestureflow_hagrid18_dmp_main.c:171`) — and it is *not* in the handshake, it is
in `store_probe()`, the diagnostic writer.  So the baremetal handshake is
unbarriered too and simply got away with it.  Worth knowing before copying that
file's structure as "the proven reference".

---

## 17. Iterating driver code should not involve the SD card at all

Rewriting a 431 MB rootfs and re-seating the card to test one driver change is
~15 minutes per iteration, and most of it is the same bytes every time.

The board is already running Linux with a root shell, a writable rootfs, and
`python3` that has `base64`, `zlib`, `hashlib` and `struct`.  So:

```bash
# host: extract the just-built binary from the image (debugfs, no root), then
bash plnx/10_push_app.sh               # 09_board_put.sh under the hood
```

`09_board_put.sh` base64s the file, streams it over the console into
`cat > /tmp/x.b64`, decodes on the board, and **verifies md5 and length on both
sides**, retrying up to three times.  Measured **11.3 KiB/s**, which is exactly
the 115200 line rate — i.e. lossless, and the tty's own write buffer provides the
flow control so no pacing is needed.

Facts that make it work, each of which cost a cycle to establish:

* **`stty -echo` on the board first.**  Otherwise every byte is echoed back, which
  both doubles the traffic and can wedge both directions once a buffer fills.
* **Never pipe a `send` into `grep -q`** in a script with `pipefail`.  `grep -q`
  exits on the first match, the writer can take `SIGPIPE`, and a *successful*
  transfer is then reported as a failure.  Capture into a variable and match on
  that.  (And do not send the evidence to `/dev/null` — that is what made the
  first attempt undiagnosable.)
* **Use a persistent fd in raw mode** (`exec 3<>"$DEV"` + `stty ... raw`) and let
  it block; do not sleep to pace.
* **Bootstrap the decoder with a heredoc sent line by line** — that avoids every
  layer of nested quoting, since the board's shell is collecting the heredoc and
  each line is just a line.
* The transport is still **not** verified end to end until the md5 on both sides
  matches.  A serial link that silently drops a byte is a board that produces
  random classifications.

**What still needs the card:** anything outside the rootfs — the device tree, the
kernel, `boot.scr`, `BOOT.BIN`.  Those live in the boot partition / FIT and cannot
be streamed into a running system safely.  Keep `04_make_sd.sh` for those, and
for freezing a version to hand in.

---

## 18. A golden value is a property of the *input*, not of the hardware — gate it on the verification path

The first time a real camera was attached, `gf_camera` failed on frame 0:

```
gf_npu: FAIL stage 0x4103 observed 0x9AD0E9B4
```

`0x9AD0E9B4` is hash-shaped, not status-shaped — it was the FNV register, compared
against the *reference image's* FNV.  Three checks in `gf_npu_run_frame()` had the
same defect:

| code | comparison | why it cannot hold for a camera frame |
|---|---|---|
| `0x4103` | `REG(GF_OUTPUT_FNV1A) != GF_FULL_OUTPUT_FNV1A` | FNV of what the **reference image** produces |
| `0x4105` | `REG(GF_OUTPUT_FNV1A) != GF_BODY2_OUTPUT_FNV1A` | same |
| `0x4133` | `gap_fnv`/`fc_fnv`/`post_class` vs `GF_POST_*_EXPECTED_*` | also input-dependent |

Every camera frame was guaranteed to "fail", because a camera frame is not the
reference image.  Nothing else in the chain was affected: fault bits and the
DMA/store byte counts are hardware properties and stay unconditional.

**The rule:** split each check by what it depends on.

* hardware property (fault bit, byte count, validity of a status register)
  → check it for **every** input;
* input-derived golden value (FNV, expected class, tensor contents)
  → check it **only** on the verification path.

The codebase already had the vehicle for this — `stats != NULL` means "this call
is the reference-image verification pass" — and `verify_tensor()` was already
gated on it.  The FNV/class comparisons simply were not.  `gf_npu_selftest()` now
always supplies its own `stats`, so `gf_camera --selftest` cannot silently skip
the FNV chain either.  The contract is documented on `gf_npu_run_frame()`.

**And add the input-independent check you can:** the class must always be in
`0..GF_POST_FC_OUTPUTS-1`.  That keeps the live path self-validating instead of
turning into "verify nothing".

**Why this survived so long:** the baremetal driver had no camera attached, ever.
The reference image was the only input it ever saw, so a check that only makes
sense for the reference image looked perfectly reasonable.  That is the same
shape as #14b and #16 — **the Linux + real-sensor path had never been exercised**,
so bugs that only exist on it stayed invisible.  When adding a new input source to
a design that has only ever run one, re-read every check that mentions a constant.

---

## 19. libjpeg's error handling is not optional — without setjmp one bad frame kills the process

Symptom, with a real scene in front of the camera:

```
gf_camera: running ('Ctrl-C' to stop)
Empty input file
root@gflinux:~#
```

No frames, and the program is **gone** — not hung, not crashed with a signal, it
simply exited.  `Empty input file` is libjpeg's `JERR_INPUT_EMPTY` text, and
`jpeg_read_header()` raises it as a **fatal** error.  With the default error
manager (`jpeg_std_error`), "fatal" means `exit()`.

`jpeglib.h` says this outright: the caller **must** provide an error manager whose
`error_exit` longjmps to a `setjmp` point the caller established.  The code used
`jpeg_std_error()` and never called `setjmp`, so every decode error was fatal.

What produces such a frame in the first place — uvcvideo telling us so itself:

```
uvcvideo 2-1:1.1: Non-zero status (-71) in video completion handler.
```

An isochronous URB completing with `EPROTO` can leave a dequeued buffer with
`bytesused == 0`, and libjpeg cannot be handed a zero-length source.

Fix, both halves:

```c
struct gf_jpeg_error { struct jpeg_error_mgr pub; jmp_buf unwind; };

static void gf_jpeg_error_exit(j_common_ptr cinfo)
{
    struct gf_jpeg_error *e = (struct gf_jpeg_error *)cinfo->err;
    char msg[JMSG_LENGTH_MAX];
    (*cinfo->err->format_message)(cinfo, msg);
    fprintf(stderr, "gf_camera: JPEG decode error: %s\n", msg);
    longjmp(e->unwind, 1);          /* never exit() */
}
...
    if (len == 0U) return -1;        /* libjpeg rejects a zero-length source */
    cinfo.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = gf_jpeg_error_exit;
    if (setjmp(err.unwind)) { jpeg_destroy_decompress(&cinfo); return -1; }
```

A camera loop has to survive a bad frame.  Any third-party decoder whose only
failure mode is "abort the process" is not usable inside one.

**Two related diagnosis traps from the same session, both about looking at the
wrong thing:**

* **A capture that is "missing bytes" may be a parser bug, not a link bug.** The
  first attempt to pull a 96×96 frame back over the console looked 20 base64
  characters short of a clean md5.  The link was perfect; the regex required
  `[A-Za-z0-9+/=]{40,}` and the **final** base64 line was 20 characters long, so
  it was silently dropped.  Count against the expected length
  (`(zlen+2)//3*4`) and say so, instead of "it's probably the serial line".
* **Do not pipe a running program's output into `tail` and then kill it.** The
  pager buffers, so a timeout kills the pipeline and the buffered frames are lost
  — which reads as "the program produced no output".  Capture to a file.

**And one genuine source of confusion worth remembering:** `gf_camera --save-ppm`
originally saved frame 3.  Frame 3 is ~0.2 s after `STREAMON`, i.e. **before a UVC
camera's auto-exposure has converged** — it saved a near-black image, which looked
like "the camera sees nothing" and made the all-`dislike` classification look like
a model bug.  It now saves the **last** frame when `-n N` is given.  When
instrumenting an auto-exposure camera, sample a settled frame.

## 20. Live HTTP viewer: the contract, and five small traps

The contract first, because it is what makes `--view` safe to leave switched on:
**the capture thread never touches a socket, and nothing is copied unless a client
asked for that stream within the last two seconds.**  Everything below is a
detail.  A benchmark run with no browser attached therefore measures exactly what
it measured before the viewer existed, and a stalled client or a saturated link
can only drop *viewer* frames — never add a millisecond to the pipeline.

Measured on the x86 host with `linux/tests/run.sh`:

```
one memcpy of a 96x96 preview (yardstick) :   418 ns
publish, nobody interested                :    37 ns   = 0.00014% of a 27.3 ms frame
publish, preview stream watched           :   553 ns   = 0.0020%
publish that also copies the scene        : 78485 ns   = 0.29%, but capped at 5/s
```

The "nobody interested" figure is *deterministically* verified, not estimated:
publish a pattern, let the window expire, publish a different pattern, read the
stream back — it must still show the first pattern.  Timing is only corroboration.

1. **`Connection: close` must actually close.**  Writing it into the response
   header and then looping for the next request leaves the peer waiting for an
   EOF that never arrives, until the socket timeout.  The handler has to return
   "close" as well as say it.  (The host test caught this before the board did.)

2. **`strcasestr()` needs `_GNU_SOURCE`, even with `-std=gnu99`.**  gnu99 gives
   you `_DEFAULT_SOURCE`; `strcasestr` is declared under `__USE_GNU`.  Either
   define `_GNU_SOURCE` before the first include, or write the two case variants.

3. **Put `-pthread` in the recipe.**  glibc 2.34+ folded pthreads into libc, so
   omitting the flag often links anyway — which is worse, because it hides the
   intent.  gf_camera runs the viewer on its own thread.  Say so in the flags.

4. **Plain `char` is signed on x86.**  Decoding a little-endian 32-bit field as
   `b[18] | (b[19]<<8) | ...` turns a width of 640 into −128, because `b[18]` is
   0x80.  This bit the *test*, not the server: dumping the bytes showed the header
   was perfect (`80 02 00 00`) and the reader was wrong.  Cast every byte to
   `unsigned char`.  **When a check fails, dump the bytes before believing it.**

5. **The first request on a stream returns 503 — by design.**  A stream is only
   copied while somebody is interested, so the first request arrives *before* any
   copy has happened; that request is what registers the interest, and the second
   one gets a frame.  The page's `onerror` retry covers it.  Do not "fix" this by
   copying unconditionally.

Two smaller notes.  The page is served from a **file**
(`/usr/share/gf/view.html`), not compiled in, so it can be replaced over the
console in about two seconds (`10_push_app.sh page`) while iterating on it.  And
the full-resolution scene is rotated by the browser with a CSS transform, because
only the 96x96 image actually has to be upright — for the model.




## 21. Getting files onto the board, and the viewer's own cost

**The console has exactly one writer.** Two writers interleaving on the same tty
tear long commands and heredocs in half, and the symptom lands a long way from
the cause.  A probe sent while `09_board_put.sh` was mid-install corrupted the
on-board decoder, which then surfaced as "the decoded md5 does not match" on all
three attempts -- i.e. it looked exactly like the serial line dropping bytes.
`09` and `11` now take a `flock` on the tty before doing anything.

Related, same root: **install on-board helpers with a single line**, not a
heredoc.  `python3 -c "import base64;open(p,'wb').write(base64.b64decode('...'))"`
has no multi-line protocol for a second writer to split.  And **selftest the
helper you just installed** -- checking that `python3` runs at all proves
nothing.  Feed it a known input and compare the md5.  (The first version of that
selftest was itself wrong: it wrote the *plaintext* into the decoder's input file
when the decoder's input is base64.  Test the test.)

**Ethernet beats the serial port by about 200x, and there is now a cable.**
592 KB in 0.05 s (11.5 MB/s) via `11_net_put.sh`, against ~60 s for the same file
over 115200 baud.  The board's busybox `nc` is stripped -- `Usage: nc [IPADDR
PORT]`, **no `-l`** -- so the board cannot be the listener; the script instead
starts a one-shot TCP receiver in the board's python3 and the host connects to
it.

Two traps in that script, both of which look like network faults:

* **Create the target directory first.** The receiver's `open()` fails when the
  parent does not exist, the process dies immediately -- but `accept()` has
  already happened, so the sender's data lands in the socket buffer and the
  client reports success.  It reads as "the file transferred but the md5 is
  wrong".
* **`mv` preserves the receiver's mode.** A binary pushed this way arrives as
  644 and will not execute.  Pass the mode explicitly (`755` for binaries, `644`
  for the page).

**The direct link needs no Windows configuration.** A USB Ethernet adapter with
no DHCP server gets an APIPA address (`169.254/16`), so giving the board an
address in the same range is enough -- no adapter settings, no admin rights:

```
ip link set eth0 up
ip addr replace 169.254.10.20/16 dev eth0
```

**The viewer's page has to throttle itself.** Chaining `<img>` off its own
`onload` is fine for correctness (a slow link just slows the loop) but it is an
unbounded rate: on a LAN a browser will happily request the preview at over
100 Hz, and every request costs the board a memcpy and a socket write.  That
would defeat the whole design.  The refresh rate is therefore fixed in the page
(66 ms preview, 220 ms scene) and the board does no timing of its own.

**The first request on a stream returns 503, on purpose.** A stream is copied
only while somebody is interested, so the first request arrives before any copy
has happened -- that request is what registers the interest.  The page's
`onerror` retry covers the ~100 ms gap.  Do not "fix" it by copying always.

**The camera orientation is a runtime parameter, and it has already been flipped
once.** It started upside down and needed `--rotate 180`; the user then remounted
it upright, at which point copying the previous command line inverted a
correct image.  Judge from a captured frame (`--save-ppm` and look at it), not
from history.  See `docs/ZCU104_实时监视器_2026-09-12.md` section 5.

## 22. `petalinux-build` can return 255 *after* producing the artifacts

Observed:

```
Checking sstate mirror object availability...
ERROR: SState: cannot test file://26/b3/sstate:sed:..._package.tar.zst: TimeoutError('timed out')
ERROR: SState: cannot test file://bb/e1/sstate:python3-iniparse:...: TimeoutError('timed out')
Summary: There were 2 ERROR messages, returning a non-zero exit code.
ERROR: Failed to build project.
```

`06_install_app.sh` correctly refuses to claim success (`BUILD_RC=255`), and the
first instinct is to go looking for a mistake in the code.  **Look at the
timestamps first**: in that run `rootfs.ext4`, `rootfs.manifest`, `rootfs.cpio`
and `rootfs.tar.gz` had all been rewritten a minute earlier, i.e. the recipe
built, installed, packaged and the image was assembled.  What failed was
bitbake's *mirror probe* on the way out.

The trigger was the network, and specifically this: **WSL 2.7 automatically
exports the Windows proxy into the WSL environment** (`env` shows
`https_proxy=http://127.0.0.1:7897`, `NO_PROXY=...`).  That proxy was saturated
at the time by an unrelated 400-request HTTP loop over the same host network
stack, so the probe timed out.  Nothing to do with the driver.

So: `BUILD_RC != 0` means "read the log", not "the code is broken".  The judge of
whether the image is usable is still `05_verify_image.sh` -- which reported
`RESULT: PASS` on that very build, because `rootfs.ext4` (18:20) was newer than
the newest source (18:19) and the binaries inside matched the sources byte for
byte by md5.

If it recurs, the cheapest fix is to re-run with the proxy out of the way:

```
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    bash 06_install_app.sh
```

and to avoid running anything else across the same network path while a build is
finishing.
