#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv"
RUNFILES_DIR="$ROOT/bazel-bin/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_silent_probe_cocotb_runner.sh.runfiles/coralnpu_hw"
RUNNER="$ROOT/bazel-bin/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_silent_probe_cocotb_runner.sh"
LIB_PATH="$RUNFILES_DIR/external/coralnpu_pip_deps_cocotb/cocotb/libs"
PY_PATH="$RUNFILES_DIR/tests/cocotb/tutorial/tfmicro:$RUNFILES_DIR/coralnpu_test_utils"

if [[ $# -eq 0 ]]; then
  echo "用法: $0 cycles1 [cycles2 ...]" >&2
  exit 1
fi

for cycles in "$@"; do
  log_path="/tmp/rowhandoff_dm_snapshot_${cycles}.log"
  if [[ -f "$log_path" ]] && grep -q "dm_snapshot_counters=" "$log_path"; then
    echo "=== ROWHANDOFF_DM_SNAPSHOT_RUN_CYCLES=$cycles 已有完整日志，跳过 ==="
    continue
  fi
  echo "=== ROWHANDOFF_DM_SNAPSHOT_RUN_CYCLES=$cycles ==="
  rm -f "$log_path"
  env \
    LD_LIBRARY_PATH="$LIB_PATH" \
    PYTHONPATH="$PY_PATH" \
    ROWHANDOFF_DM_SNAPSHOT_RUN_CYCLES="$cycles" \
    ROWHANDOFF_DM_SNAPSHOT_STRICT=0 \
    "$RUNNER" \
    2>&1 | tee "$log_path"
done
