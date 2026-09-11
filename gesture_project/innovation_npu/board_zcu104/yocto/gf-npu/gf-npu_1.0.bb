# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# GestureFlow NPU userspace driver + USB camera pipeline (ZCU104).
#
# Built straight into the rootfs so the board needs no SDK: boot and run
#   gf_npu_probe --selftest
#   gf_camera -s 640x480
#
# The weight tables are copied verbatim from board_7020/software so there is
# exactly one source of truth for the quantised model.

SUMMARY = "GestureFlow NPU userspace driver and UVC camera pipeline"
DESCRIPTION = "Userspace driver for the GestureFlow HaGRID-18 DMP NPU on the ZCU104 PL, plus a V4L2 camera pipeline."
HOMEPAGE = "https://github.com/SteveGuo1726/coralnpu-gesture"
LICENSE = "CLOSED"
LIC_FILES_CHKSUM = ""

SRC_URI = " \
    file://gf_npu.c \
    file://gf_npu.h \
    file://gf_npu_probe.c \
    file://gf_camera.c \
    file://gestureflow_real_conv4x4_full_layer.h \
    file://gestureflow_dmp_full_layer.h \
    file://gestureflow_chain_body_data.h \
    file://gestureflow_dmp_body2_layer.h \
    file://gestureflow_real_maxpool2d.h \
    file://gestureflow_real_conv4x4_conv2a_layer.h \
    file://gestureflow_dmp_conv2a_layer.h \
    file://gestureflow_real_conv4x4_conv2b_layer.h \
    file://gestureflow_dmp_conv2b_layer.h \
    file://gestureflow_real_maxpool2d_pool2.h \
    file://gestureflow_real_conv4x4_conv3a_layer.h \
    file://gestureflow_dmp_conv3a_layer.h \
    file://gestureflow_real_conv4x4_conv3b_layer.h \
    file://gestureflow_dmp_conv3b_layer.h \
    file://gestureflow_real_maxpool2d_pool3.h \
    file://gestureflow_real_conv4x4_head1x1_layer.h \
    file://gestureflow_dmp_head1x1_layer.h \
    file://gestureflow_real_gap_fc.h \
"

S = "${WORKDIR}"

# MJPEG camera support.  libjpeg-turbo lives in poky
# (meta/recipes-graphics/jpeg/libjpeg-turbo_2.1.5.1.bb).  Yocto resolves the
# runtime dependency from the ELF NEEDED entry, so no explicit RDEPENDS.
# YUYV still works if a camera offers no MJPEG, and this is a compile-time
# option only because uvcvideo hands the raw JPEG bytes to userspace.
DEPENDS = "libjpeg-turbo"

# The generated headers hold a lot of golden reference data this driver does
# not need; silence the unused-static noise so real warnings stay visible.
GF_CFLAGS = "-O2 -std=gnu99 -Wall -Wextra -Wno-unused-const-variable -Wno-unused-but-set-variable -DGF_HAVE_JPEG -I${S}"
GF_LDLIBS = "-ljpeg"

do_compile() {
    ${CC} ${GF_CFLAGS} ${CFLAGS} -o gf_npu_probe gf_npu_probe.c gf_npu.c ${GF_LDLIBS} ${LDFLAGS}
    ${CC} ${GF_CFLAGS} ${CFLAGS} -o gf_camera    gf_camera.c    gf_npu.c ${GF_LDLIBS} ${LDFLAGS}
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 gf_npu_probe ${D}${bindir}/gf_npu_probe
    install -m 0755 gf_camera    ${D}${bindir}/gf_camera
}

FILES:${PN} = "${bindir}/gf_npu_probe ${bindir}/gf_camera"
