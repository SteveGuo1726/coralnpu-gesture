# Original Hardware Backup

This directory is a snapshot of the verified 2026-09-01 hardware baseline.

It contains:

- `rtl/`
- `tests/`
- `tools/`
- `board_7020/`
- `configs/`

Experiments are performed directly under `innovation_npu/`. If an experiment
breaks the main hardware path, restore only the affected subdirectory from
this backup instead of resetting the whole repository.

Example:

```bash
cp -a backup_original_2026-09-01/rtl/gestureflow_mac_tile.sv rtl/
```
