#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv"
RUNFILES_DIR="$ROOT/bazel-bin/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe_cocotb_runner.sh.runfiles/coralnpu_hw"
RUNNER="$ROOT/bazel-bin/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe_cocotb_runner.sh"
LIB_PATH="$RUNFILES_DIR/external/coralnpu_pip_deps_cocotb/cocotb/libs"
PY_PATH="$RUNFILES_DIR/tests/cocotb/tutorial/tfmicro:$RUNFILES_DIR/coralnpu_test_utils"

WARMUP_CYCLES="${1:-8400000}"
TIMEOUT_CYCLES="${2:-40000}"
POLL_INTERVAL_CYCLES="${3:-32}"

env \
  LD_LIBRARY_PATH="$LIB_PATH" \
  PYTHONPATH="$PY_PATH" \
  ROWHANDOFF_POLL_WARMUP_CYCLES="$WARMUP_CYCLES" \
  ROWHANDOFF_POLL_TIMEOUT_CYCLES="$TIMEOUT_CYCLES" \
  ROWHANDOFF_POLL_INTERVAL_CYCLES="$POLL_INTERVAL_CYCLES" \
  "$RUNNER"
