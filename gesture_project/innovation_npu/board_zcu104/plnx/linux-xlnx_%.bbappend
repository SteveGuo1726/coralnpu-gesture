# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Pull the UVC / USB3-host kernel fragment into the PetaLinux linux-xlnx kernel.
# This is the same shape PetaLinux itself generates when you save a fragment in
# `petalinux-config -c kernel`, so it merges cleanly.

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://kernel_uvc.cfg"
