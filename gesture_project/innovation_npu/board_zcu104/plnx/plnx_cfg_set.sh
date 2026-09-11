#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Non-interactive setter for PetaLinux Kconfig files.
#
# `petalinux-config` only offers an interactive menuconfig, which cannot be
# driven from a batch script.  The generated config file is plain Kconfig
# though, so the menu items can be set by editing it directly and then
# re-applying with `petalinux-config --silentconfig`.
#
# usage:
#   plnx_cfg_set.sh <config-file> KEY=VALUE [KEY=VALUE ...]
#
# Handles all three Kconfig line shapes:
#   CONFIG_KEY="old"              -> CONFIG_KEY="new"
#   # CONFIG_KEY is not set       -> CONFIG_KEY=new
#   (absent)                      -> appended at the end
#
# examples:
#   plnx_cfg_set.sh project-spec/configs/config \
#       CONFIG_SUBSYSTEM_MACHINE_NAME='"zcu104-revc"'
#   plnx_cfg_set.sh project-spec/configs/rootfs_config \
#       CONFIG_packagegroup-petalinux-v4lutils=y

set -uo pipefail

CFG="${1:-}"
shift || true
[ -n "$CFG" ] || { echo "usage: $0 <config-file> KEY=VALUE [...]" >&2; exit 2; }
[ -f "$CFG" ] || { echo "no such config file: $CFG" >&2; exit 2; }
[ $# -gt 0 ] || { echo "no KEY=VALUE pairs given" >&2; exit 2; }

changed=0
for kv in "$@"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  if grep -qE "^${key}=" "$CFG"; then
    # already present and enabled -> rewrite the value
    sed -i -E "s|^${key}=.*|${key}=${val}|" "$CFG"
    echo "set   ${key}=${val}"
  elif grep -qE "^# ${key} is not set" "$CFG"; then
    # present but disabled -> enable it
    sed -i -E "s|^# ${key} is not set|${key}=${val}|" "$CFG"
    echo "enable ${key}=${val}"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CFG"
    echo "append ${key}=${val}"
  fi
  changed=$((changed+1))
done
echo "--- $changed key(s) applied to $CFG ---"
