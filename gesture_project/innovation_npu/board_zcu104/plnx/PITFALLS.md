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
| PL clock not claimed by a driver | handled by `clk_ignore_unused` | above |
| SD boot | already the default (`root=/dev/mmcblk0p2`) | `configs/config` |

A kernel config fragment is checksummed, so **adding only comments** to it also
invalidates the kernel and forces a rebuild. Keep findings in this file, not in
`kernel_uvc.cfg`.

---

## 8. `MACHINE_NAME` is what makes the ZCU104 native

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

## 9. WSL workflow notes

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
