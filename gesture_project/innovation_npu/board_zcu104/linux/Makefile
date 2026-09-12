# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# ZCU104 GestureFlow NPU userspace programs (aarch64 Linux).
#
# ---------------------------------------------------------------------------
# Getting a toolchain
#
# Preferred (recommended once, then iterate fast):
#     cd ~/gf_linux_ws/gf_linux
#     petalinux-build --sdk
#     ./images/linux/sdk.sh -d ~/gf_sdk -y
#     source ~/gf_sdk/environment-setup-cortexa72-cortexa53-xilinx-linux
#     cd <this dir> && make            # $CC is already the cross compiler
#
# Or point at a compiler explicitly:
#     make CROSS_COMPILE=aarch64-xilinx-linux-
#
# There is also a Yocto recipe (gf-npu_1.0.bb) that builds both binaries
# straight into the rootfs image, so the board does not need an SDK at all.
# ---------------------------------------------------------------------------
#
# The weight/parameter tables live in the generated headers under
# board_7020/software; this driver consumes them unchanged so there is exactly
# one source of truth for the quantised model.
WEIGHT_INC ?= ../../board_7020/software

CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
STRIP   := $(CROSS_COMPILE)strip

# -static by default: the PetaLinux rootfs is minimal, and a static binary
# removes any uncertainty about which libc is on the board.
STATIC  ?= 1
JPEG    ?= auto     # auto | 0 | 1  -- MJPEG camera support (needs libjpeg)

# -pthread: gf_camera's --view option runs the HTTP viewer on its own thread
# (see gf_view.c).  The pipeline itself stays single-threaded.
CFLAGS  := -O2 -Wall -Wextra -std=gnu99 -pthread -I. -I$(WEIGHT_INC)
LDLIBS  :=

ifeq ($(STATIC),1)
CFLAGS  += -static
endif

ifeq ($(JPEG),1)
CFLAGS  += -DGF_HAVE_JPEG
LDLIBS  += -ljpeg
else ifeq ($(JPEG),auto)
# Probe for libjpeg; if absent, build without MJPEG (YUYV still works).
JPEG_HDR := $(shell echo '\#include <jpeglib.h>' | $(CC) -E - >/dev/null 2>&1 && echo yes)
ifeq ($(JPEG_HDR),yes)
CFLAGS  += -DGF_HAVE_JPEG
LDLIBS  += -ljpeg
endif
endif

BINS := gf_npu_probe gf_camera

.PHONY: all clean check-toolchain

all: check-toolchain $(BINS)

check-toolchain:
	@command -v $(CC) >/dev/null 2>&1 || { \
	  echo "error: '$(CC)' not found."; \
	  echo "       source the PetaLinux SDK environment first, or pass CROSS_COMPILE=..."; \
	  exit 1; }

# Shared object file: the NPU driver.
gf_npu.o: gf_npu.c gf_npu.h
	$(CC) $(CFLAGS) -c -o $@ $<

# The live HTTP viewer (gf_camera --view PORT).  Depends on gf_npu.h only for
# gf_npu_class_name().
gf_view.o: gf_view.c gf_view.h gf_npu.h
	$(CC) $(CFLAGS) -c -o $@ $<

# Small CLI around the driver: --selftest is the port-validation step.
gf_npu_probe: gf_npu_probe.o gf_npu.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

gf_camera: gf_camera.o gf_view.o gf_npu.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c gf_npu.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f *.o $(BINS)
