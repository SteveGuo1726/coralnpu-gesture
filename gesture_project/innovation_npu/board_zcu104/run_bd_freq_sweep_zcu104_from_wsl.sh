#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Stage-1 tool: check that the ZCU104 block design still validates across
# candidate PL frequencies, WITHOUT paying for a full implementation.
#
# This isolates one specific Stage-1 risk: the packaged IP pins the clock
# interface FREQ_HZ, so every pl_clk0 change must keep the IP and the block
# design consistent.  A pass here does NOT prove timing closure -- that still
# comes from the full build (bitstream + WNS) and per-module OOC synthesis.
#
# Usage:
#   bash run_bd_freq_sweep_zcu104_from_wsl.sh            # 100 150 200 250
#   bash run_bd_freq_sweep_zcu104_from_wsl.sh 100 200 300
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  freqs=("$@")
else
  freqs=(100 150 200 250)
fi

status=0
for f in "${freqs[@]}"; do
  echo "==================== ZCU104 BD @ ${f} MHz ===================="
  if bash "$root/board_zcu104/run_build_gestureflow_hagrid18_dmp_zcu104_from_wsl.sh" "$f" bd_only \
       | tee "/tmp/zcu104_bd_${f}mhz.log" \
       | grep -E "pl_freq_mhz|BD_ONLY_PASS|^ERROR|CRITICAL WARNING"; then
    if grep -q "BD_ONLY_PASS" "/tmp/zcu104_bd_${f}mhz.log"; then
      echo "RESULT ${f}MHz: PASS"
    else
      echo "RESULT ${f}MHz: FAIL"; status=1
    fi
  else
    echo "RESULT ${f}MHz: FAIL (no pass marker)"; status=1
  fi
done
exit $status
