# Experimental DMP Full-Network Branch

This worktree is `feature/dmp-fullnet-8lane`.  It is intentionally separated
from the verified `stable-2026-09-01` baseline:

- Stable/original version:
  - worktree: `/home/steveguo/coralnpu-gesture/original`
  - branch/tag: `stable-2026-09-01`
- Experimental version:
  - worktree: `/home/steveguo/coralnpu-gesture/experimental`
  - branch: `feature/dmp-fullnet-8lane`

## Goal

Replace the whole HaGRID18 conv data path with the DMP 8-lane engine, keep
single-image full-network board flow, and finish board verification.

## Non-negotiable constraints

1. Do not edit `/home/steveguo/coralnpu-gesture/original`.
2. Do not use the 4-lane DMP compatibility shortcut; it is functionally
   correct but does not fit `OUT_LANES=32` on Zynq-7020.
3. Every RTL change must pass Verilator before Vivado.
4. Preserve the existing `FINAL_RESULT=0x600D600D` acceptance contract.

## Integration order

1. Make `gestureflow_layer_chain_hp0_axil` use the DMP 8-lane conv engine.
2. Add a DMP weight DMA loader for 6x32-bit packed weight words.
3. Update HaGRID18 software to DMP weight/bias arrays.
4. Run full-network Verilator FNV regression.
5. Rebuild XSA/bit/ELF, program 7020, compare full-network cycles/FPS.
