#!/usr/bin/env bash
#
# Host-side (x86) tests for the Linux userspace, runnable without the board.
#
#     bash tests/run.sh
#
# Two programs:
#
#   t_geom  The 96x96 area-average resize, its --rotate index math, and the
#           --crop window.  It pulls the real gf_camera.c in with `main` renamed
#           out of the way, so what is under test is the shipped code rather
#           than a paraphrase of it.  Covers: all four rotations against an
#           independently derived expectation, rot180 == reverse,
#           rot90+rot270 == identity, the 640x480 geometry, the box bounds at
#           the edges, and crop_window()'s centre offsets and clamps.
#
#   t_view  The HTTP viewer end to end.  Covers: the routes, the 503-before-
#           first-frame behaviour, byte-exact BMP for both the 96x96 preview and
#           the *strided* scene window (bottom-up row order included), the
#           /stats JSON fields, and -- deterministically, not by timing -- the
#           claim that publishing is free when nobody is watching.
#
# Why these exist: the rotation sign and the BMP row order are the two things
# that look obviously right and are 180 degrees / upside down, and the board is
# the least convenient place to discover either.  Both tests run in about five
# seconds on a laptop.
#
# Nothing here needs the PL, /dev/mem, libjpeg, or the generated weight headers.
#
set -uo pipefail
export PATH=/usr/bin:/bin:$PATH

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gftests.XXXXXX")"
trap 'rm -rf "$W"' EXIT

cd "$W"
cp "$SRC"/gf_camera.c "$SRC"/gf_npu.h "$SRC"/gf_view.c "$SRC"/gf_view.h "$SRC"/view.html .
cp "$HERE"/t_geom.c "$HERE"/t_view.c .
# The dashboard scripts are authored on Windows; a stray CR turns into
# "command not found" in the most confusing way possible.
sed -i 's/\r$//' ./*.c 2>/dev/null || true

rc=0

echo "=== t_geom: resize_rgb96 + --rotate ==="
if gcc -O1 -g -std=gnu99 -Wall -Wextra -pthread -I. \
       -ffunction-sections -fdata-sections -Wl,--gc-sections \
       -o t_geom t_geom.c; then
    ./t_geom || rc=1
else
    echo "  compile failed"; rc=2
fi

echo
echo "=== t_view: HTTP viewer + interest gate ==="
if gcc -O1 -g -std=gnu99 -Wall -Wextra -pthread -I. -o t_view t_view.c gf_view.c; then
    ./t_view 18080 view.html || rc=1
else
    echo "  compile failed"; rc=2
fi

exit $rc
