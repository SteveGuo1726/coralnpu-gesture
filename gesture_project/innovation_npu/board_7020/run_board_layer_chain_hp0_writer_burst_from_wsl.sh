#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Board entry point for the writer-burst implementation. The explicit paths
# prevent a future reset_run from silently selecting the rollback bitstream.
export GESTUREFLOW_BIT_PATH_WIN='E:\coralnpu_vivado\projects\gestureflow_layer_chain_hp0_7020_v1\logs\gestureflow_layer_chain_hp0_7020_writer_burst.bit'
export GESTUREFLOW_XSA_PATH_WIN='E:\coralnpu_vivado\projects\gestureflow_layer_chain_hp0_7020_v1\logs\gestureflow_layer_chain_hp0_7020_writer_burst.xsa'
exec "$(dirname "${BASH_SOURCE[0]}")/run_board_layer_chain_hp0_7020_from_wsl.sh" "$@"
