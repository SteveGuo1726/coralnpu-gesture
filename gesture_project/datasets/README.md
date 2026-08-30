# datasets 目录说明

本目录只保留数据组织说明和数据准备脚本，不默认上传任何大体积原始数据或处理后图片数据。

## 2026-08-15 当前静态主数据

当前静态训练只使用 HaGRID-v1 来源的低分辨率全类别训练主体：

```text
gesture_project/datasets/raw/hagrid_v1_500k_384p/hagrid-sample-500k-384p.zip
gesture_project/datasets/processed/hagrid_v1_500k_384p_subject_split_20260815/
```

- 原始归档为 13,418,776,353 字节，SHA-256：`461ad5746eb95c3605f4fa2ba7daa19e2fcd4d7d91d4d26c7c31dfe228feb68e`；已通过 `unzip -t` 压缩完整性检查。
- 归档为 HaGRID-v1 来源的 384p 低分辨率版本，包含 18 类、509,323 张图像。它覆盖该归档的全部类别和图像，但不是原始 HaGRID-v1 的 552,992 张 1080p 文件，文档和报告不得把两者混写。
- 处理目录采用 `user_id` 全局人物隔离：训练 357,748 张、验证 66,264 张、独立测试 85,311 张。所有集合均含完整 18 类；旧六类 HaGRID 目录不可再用于主线训练或准确率结论。
- 归档没有 `no_gesture`，当前只能训练 18 类手势分类模型。后续产品级拒识和空闲态必须补充独立背景或无手势数据。
- 当前训练教师可复现命令和参数记录在 `docs/会话交接_最高优先级_2026-07-11.md` 顶部。教师用于精度与蒸馏，不直接作为 CoralNPU 部署模型。

## 当前数据策略

- `raw/`：原始图片、视频、帧序列和上游标注，只保留在本地。
- `processed/`：整理后的图像目录、视频片段或清单，只保留在本地。
- `tools/`：数据准备脚本，纳入版本管理。

## 2026-08-14 起的数据分层

HaGRID 六类原图本阶段停止训练，仅保留为历史可复现实验。它仍有公开权威性，但当前用户已经明确要求用其他数据集替代，因此不能继续把它写成静态产品主线。

当前静态任务的第一候选是已实际取得并训练的 NUS Hand Posture Dataset II；静态和动态任务分为四个不可混写的层次：

1. 当前静态算法候选：使用 NUS Hand Posture Dataset II。它是已取得的原生静态彩色图像，已经完成项目侧受试者划分重建、教师训练、普通卷积学生训练、导出和全整型测试。人物划分不是官方清单提供的划分，报告中必须明确这一点。
2. 静态软件和量化回归：使用 Sign Language Digits。它是已取得的原生静态十类图像，许可明确，但应用语义较弱，只用于训练、导出、量化和 CoralNPU 算子回归。
3. 智能家居应用补充：使用 IPN Hand。它是 RGB、30 帧每秒、面向无接触屏幕控制的连续视频；动态训练暂停，静态阶段最多只抽取单帧可判断类别，点击、抛动、缩放等必须留给动态阶段。
4. VR 第一人称手势：使用 EgoGesture 的独立基准。它是头戴相机 RGB-D 数据，训练和测试必须保持官方跨受试者划分；当前数据尚未取得。

静态最终产品结果必须使用项目组自采的真实家居环境测试集，不能用受控姿态库宣称产品准确率。数据集权威性、许可、实际训练结果和淘汰原因见[静态手势数据集候选与主线判定](../docs/静态手势数据集候选与主线判定_2026-08-14.md)。

当前 NUS 候选模型及小型报告已经允许纳入版本控制，位于：

`gesture_project/models/nus_hand_posture_ii_repvgg_3x3_distill_20260814/`

原始压缩包、解压后的图片和其他训练产物继续由 `.gitignore` 忽略。

数据路线、许可、规模和硬件部署边界见：

- [数据集重选与产品任务定义 2026-08-14](../docs/数据集重选与产品任务定义_2026-08-14.md)

### IPN Hand 本地准备

IPN Hand 数据文件不上传。先从数据集项目页获取 RGB 视频或官方帧序列，再按项目侧脚本建立不改变上游划分的清单：

```bash
gesture_project/algorithms/.venv/bin/python \
  gesture_project/datasets/tools/prepare_ipn_hand_manifests.py \
  --annotation_dir gesture_project/datasets/raw/ipn_hand/annotation_ipnGesture \
  --frames_root gesture_project/datasets/raw/ipn_hand \
  --out_dir gesture_project/datasets/processed/ipn_hand_rgb14_manifest
```

省略 `--frames_root` 可先只核验官方标注和生成清单；正式训练前必须带上该参数，确保每条标注对应的帧目录真实存在。默认输出 `train.jsonl` 和 `val.jsonl`。只有在另外准备好严格留人的四列标注文件后，才通过 `--test_annotation` 生成 `test.jsonl`；不能把 `val` 改名为 `test`。

2026-08-14 的官方标注核验结果为：14 个标签，训练 4,039 段/588,281 帧，验证 1,480 段/212,183 帧。上述统计来自实际转换器运行；视频和帧数据尚未放入本机，因此本次没有执行帧目录存在性校验。

静态稳定帧子集的项目侧命令如下。它只读取官方标注和本地帧，不修改原始数据；输出建议放在 `/tmp`，避免把大体积图片提交到仓库：

```bash
gesture_project/algorithms/.venv/bin/python \
  gesture_project/datasets/tools/prepare_ipn_static_frames.py \
  --frames_root gesture_project/datasets/raw/ipn_hand/frames \
  --annotation_dir gesture_project/datasets/raw/ipn_hand_annotations_direct/annotation_ipnGesture \
  --out_dir /tmp/ipn_static_pointing_20260814 \
  --labels D0X B0A B0B
```

该脚本是项目侧工具，不是 IPN 官方代码。它按完整视频目录做固定测试留出，不能把同一视频的不同帧拆到训练和测试。

输入尺寸主线为：

- `96x96`

## 目录格式要求

静态图像训练脚本仍要求数据目录整理为：

```text
<dataset_root>/
  train/
    class_a/
    class_b/
  val/
    class_a/
    class_b/
  test/
    class_a/
    class_b/
```

### HaGRID 人物隔离静态基准

旧的 `hagrid_sample_static_6cls` 是按图片随机抽样的历史回归目录，不能用于严格泛化结论。当前新基准由：

```bash
gesture_project/algorithms/.venv/bin/python \
  gesture_project/datasets/tools/extract_hagrid_subject_split.py \
  --zip_path gesture_project/datasets/raw/hagrid_sample_120k_384p/hagrid-sample-120k-384p.zip \
  --out_dir gesture_project/datasets/processed/hagrid_subject_static_6cls_20260814 \
  --max_per_class 2500
```

按官方标注中的 `user_id` 做人物隔离，输出训练、验证、测试三部分。脚本只处理本地实验副本，不修改上游压缩包；真实图片目录仍由 `.gitignore` 忽略。完整判定见[静态手势数据集候选与主线判定](../docs/静态手势数据集候选与主线判定_2026-08-14.md)。

动态视频训练不应先把所有帧复制成重复图片目录。应保留原视频或帧根目录，并用 JSONL 记录视频级来源和起止帧，使后续可按固定长度窗口流式读取。

## 当前保留的数据准备脚本

- `tools/prepare_hagrid_subset.py`
  作用：历史 HaGRID 实验工具；当前禁止用它启动静态主线训练。
- `tools/extract_hagrid_sample_subset.py`
  作用：历史 HaGRID 样本抽取工具，不用于当前静态主线。
- `tools/prepare_sign_language_digits.py`
  作用：整理早期数字手势 smoke-test 数据，仅用于基础链路快速验证。
- `tools/prepare_ipn_hand_manifests.py`
  作用：把 IPN Hand 官方标注转换为训练、验证 JSONL 清单；可选加入项目侧留人测试清单；不复制视频，不改变原始划分。
- `tools/prepare_ipn_static_frames.py`
  作用：从 IPN 官方片段中抽取单帧可判断类别的中间帧；点击、抛动、缩放等时序类别不得通过该脚本加入静态训练。

## 共享仓库注意事项

- 不要把 `raw/` 和 `processed/` 的真实图片直接提交到仓库。
- 团队成员应按脚本和说明在本地重建数据目录。
- 正式结果应以 `reports/` 下的评估 JSON 和总结文档为准，而不是依赖本机图片副本。
