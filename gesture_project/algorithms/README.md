# algorithms 目录说明

本目录保存项目当前活跃的算法训练、量化、评估、official 回放桥接、patch 量化、rowhandoff trace 解析与重建脚本。

## 当前最重要的几类脚本

### 1. 训练与量化

- `static_cnn/train_static_cnn.py`
  当前静态卷积主线训练入口。
- `static_cnn/quantize_tflite.py`
  当前主线模型和对照模型的 INT8 量化入口。
- `mobilenet_candidates/train_mobilenet_candidate.py`
  MobileNet 家族对照训练入口。

### 2. 模型评估与画像

- `tools/evaluate_keras_classifier.py`
  浮点模型逐图评估。
- `tools/evaluate_tflite_classifier.py`
  INT8 TFLite 模型逐图评估。
- `tools/profile_tflite_ops.py`
  TFLite 算子画像。
- `tools/estimate_npu_cycles.py`
  NPU 周期估算。
- `tools/compare_model_candidates.py`
  候选模型统一对比。
- `tools/summarize_candidate_hardware.py`
  候选模型的硬件导向摘要汇总。

### 3. official 回放与 current best 收敛

- `tools/run_core_3x3_worktree_replay.py`
  当前四个主体层 official worktree 回放主入口。
- `tools/build_worktree_core_3x3_bridge.py`
  项目侧模型信息和 official worktree 参数桥接工具。
- `tools/compare_two_strategy_runs.py`
  两轮 strategy 结果对比。
- `tools/compare_core_3x3_strategy_totals.py`
  四层总周期汇总与比较。
- `tools/analyze_strategy8_tail_patch_candidates.py`
  尾部 patch 候选分析。
- `tools/analyze_strategy8_tail_micro_patch_candidates.py`
  更细粒度尾部 patch 候选分析。
- `tools/analyze_strategy8_row_end_tail_candidates.py`
  row-end 与 tail 候选分析。
- `tools/analyze_strategy8_official_patch_entry.py`
  official 最小 patch 入口定位。
- `tools/estimate_strategy8_residual_control_headroom.py`
  在 current best 基础上估算剩余控制空间。

### 4. rowhandoff 与硬件参考线

- `tools/export_strategy8_rowhandoff_min_sideband_patch.py`
  最小 sideband patch 导出。
- `tools/export_strategy8_rowhandoff_source_event_anchor_map.py`
  source 事件锚点映射导出。
- `tools/export_strategy8_rowhandoff_trace_csr_integration.py`
  trace 与 CSR 接入口径导出。
- `tools/export_strategy8_rowhandoff_board_contract.py`
  板级验证合同导出。
- `tools/export_strategy8_rowhandoff_board_csr_map.py`
  CSR 地址映射导出。
- `tools/export_strategy8_rowhandoff_corecsr_patch.py`
  CoreAxiCSR 接入 patch 方案导出。
- `tools/parse_strategy8_rowhandoff_cocotb_log.py`
  cocotb 日志解析。
- `tools/reconstruct_strategy8_rowhandoff_event_trace.py`
  row 生命周期重建。

## 当前主线使用建议

### 算法侧

优先围绕：

- `static_cnn_regularized_3x3_i96_e70_hagrid6_sample`

而不是重新大规模铺开候选模型。

### software current best 侧

优先围绕：

- `strategy=8 + x4_id32/x4_id64 + 静态主体块调度 + interior 6tap + 顶/底 4/6/4`

而不是回头捡已判死的 `repack`、`postprocess` 或边界窄特化路线。

### rowhandoff 侧

优先围绕：

- `rowhandoff_rowbase_recur mode=1`

以及 `CoreAxi / CoreAxiCSR / RowhandoffCounterBank / CSR readback / trace 对账` 这条 official 风格收口路径。

## 进一步说明

完整的活跃代码文件逐项说明见：

- `../docs/仓库共享版_活跃代码与文件说明.md`
