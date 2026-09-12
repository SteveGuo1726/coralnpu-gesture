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
