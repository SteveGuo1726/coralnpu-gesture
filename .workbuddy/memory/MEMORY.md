# MEMORY.md — coralnpu-gesture 长期项目备忘

> 详情见 `gesture_project/docs/` 下的上下文文档与 `会话交接_最高优先级`
> （最新记录在顶部）。这里只放最容易忘、代价最高的。

## 项目
自研 FPGA NPU 跑 HaGRID-18 静态手势（INT8 98.88%），核心创新 **DMP 双乘打包**（一个 DSP48 当两个用）。
- 7020：**41.9 FPS**，`0x600D600D` —— 不可回退的基线。
- ZCU104：**36.96 FPS**（PL 17.02 ms + **CPU 侧 10.04 ms**）；PetaLinux 构建完成，
  镜像含 `gf-npu` / `v4l2-utils` / `usbutils` / `libjpeg62`。

## ⚠️ 这是大创项目，验收标准在申请书里（最容易忽略、代价最大）
`24348025_面向手势识别的RISC-V+NPU设计.pdf` = **中山大学大创申请书**（校级，一年期，
2025-12-27 立项，负责人郭俊扬，指导老师王明羽）。
- **进度**：上板测试阶段 = **2026 年 10 月前**；成果凝练（论文/报告）= 2026 年 11 月前。
- **承诺指标**：静态 ≥95%、动态 ≥92%、**单帧延迟 ≤5 ms**、**功耗 ≤100 mW**、72h 稳定性；
  静态 5 万帧 + 动态 1000 组。
- **承诺路线**：基于 Coral NPU **二次开发** + 3×3 并行 MAC 阵列 + **LSTM 专用子模块** +
  TFLM/INT8/剪枝；数据集 HandGesture / Dynamic Hand Gesture。
- **实际交付**：完全自研 RTL（`coralnpu/` 只读、仅思想借鉴）、**4×4** 主线、HaGRID-18、
  **无 LSTM / 无动态手势 / 无功耗数据 / 无论文**。
- **≤5 ms 的诚实结论**：去 CPU 开销（≈18 ms）+ 提频 137 MHz（≈13.4 ms）后仍 >5 ms；
  单帧串行 + 16-lane 架构下**达不到**，需加宽阵列 + 重叠。**不要改口径凑指标。**
- **最要命的一条**：核心叙事「ZCU104 实时摄像头手势识别」**一次都没上过板**（V1–V6 全待验证），
  但不依赖任何研发，只差 sudo 写卡 + 板子时间。
- 完整对照表与优先级：`docs/项目审计与再评估_2026-09-12.md`、交接记录 **#147**。

## 最容易搞错、代价最高的（都对着源码/RTL 核实过）
1. **输入 −128 重定心由 PL 做，软件只写原始 uint8。**
   `rtl/gestureflow_hp0_rgb_loader.sv`：`{~byte[7], byte[6:0]}` = XOR 0x80 = u−128。
   **软件自己减 128 ⇒ 板上"能跑但类别全乱"。**
2. **预处理 = 整帧直接拉伸 resize**（`train_static_cnn.py:1041`，不裁剪/不保长宽比，PIL BILINEAR
   缩小是抗锯齿的）。C 里用**面积平均**近似；**最近邻会严重混叠**。
3. **DWC3 保持 DUAL_ROLE，不能 host-only**（Xilinx 内核 `dwc3/core.c:2104/2399` 无守卫调用
   `dwc3_gadget_exit_hibernation` ⇒ vmlinux 链接失败）。host 行为由设备树 `dr_mode="host"` 给。
4. **开发板必须设 `MACHINE_NAME`**（ZCU104 用 `zcu104-revc`），否则要手写 PHY/USB/SD 设备树。
5. **kernel config fragment 按内容校验和：连只加注释都触发 ~25 min 内核重编。**
   "本来就对、不要改"的结论写进 `plnx/PITFALLS.md`，不写进 `kernel_uvc.cfg`。
6. **融合池化的层，硬件 `GF_OUTPUT_FNV1A` 报的是池化前卷积输出的 FNV，不是存进 DDR 的池化张量。**
7. **HP0 非相干**，但 `reserved-memory(no-map)` + `/dev/mem` 映射成非缓存后，
   两侧都不需要 cache flush/invalidate。`no-map` 是关键。
8. **编译期常量条件会让诊断字符串从二进制里消失 —— 这不是构建坏了。**
   例：`gf_npu.c` 里 `if (bytes_needed > (size_t)GF_BUF_SIZE)`（~578 KB > 16 MiB）恒假，
   GCC 把分支**连字符串一起删掉**。曾据此**误判**为"sstate 短路了 do_compile、镜像是旧代码"。
   **⇒ 挑回归探针字符串时，条件必须依赖运行期数据**（寄存器 / memcmp / V4L2 返回值）。
9. **`log.do_compile` 恒为 ~85 字节、收尾后 WORKDIR 只剩 `temp/`、多次构建日志字节数相同
   —— 三者都是正常的**，不能用来推断任务被缓存短路。详见 `plnx/PITFALLS.md #8`。

## 镜像校验（`board_zcu104/plnx/`，三件套）
- **`05_verify_image.sh`**：`debugfs` 从 `rootfs.ext4` 里 dump ELF（**无需 sudo**），
  用内嵌字符串与源码交叉比对 → 17 探针 + 反向命中率 + md5 指纹。当前 **`RESULT: PASS`**。
- **`06_install_app.sh`**：投放源码（`cmp` 保证不漏）→ `do_cleanall` → 全量重编 → 自动校验。
- **`04_make_sd.sh`**：内置 **GATE 0**，`05` 不过就拒绝写卡；写卡后打印 md5 供对账。
- 当前镜像内指纹：`gf_npu_probe md5=2ed2ef05ab52e145`、`gf_camera md5=bb04ced68ea693e9`、
  `gf_npu.c md5=65976d8f94d320d3`。

## 架构硬门禁（不可违反）
**只报 MAC/cycle 而不报数据搬运和 PS 开销，不能作为性能结论** ⇒ 性能数字必须分离 PL 计算与 CPU 开销。
已证实边界：**跨帧权重驻留在当前硬件上不可能**（权重 SRAM 32 KB vs 整网 ~200 KB）；
板上第一优先是**用 DMA burst 装权重**，不是"打开驻留开关"。

## 仓库与两端同步
`github.com/SteveGuo1726/coralnpu-gesture`（public）。Windows `C:\Users\SteveGuo\Documents\coralnpu-gesture\`
与 WSL `/home/steveguo/coralnpu-gesture/` 是**同一仓库的两份克隆**。
- **单一权威推送侧 = Ubuntu**（Windows 无 SSH 密钥）：fetch 走 HTTPS、push 走 SSH。
- 工具：仓库根 `sync_repo.sh`（`status` / `ubuntu-push` / `win-pull` / `win-to-ubuntu`）。
- **本机 agent 环境 git 陷阱**：ref 锁写入可能被拦 → `fetch` 报成功但 ref 不存在 → 本地静默分叉；
  `commit` 可能报成功却不含预期改动。**推完必须从远端回读校验**。分叉时 reset 到远端再叠加，比 merge 稳。
- **`push` 后紧跟 `fetch`，`refs/remotes/origin/main` 可能"退回"旧提交，看起来像推送失败。**
  **真实远端一律用 `git ls-remote origin refs/heads/main` 确认**（它不写本地 ref，不受锁影响）；
  回读内容用 `git show <sha>:<path>` 指定提交号，不要用会过期的 tracking ref。
- **更精确的一次实测（2026-09-12，Windows 侧）**：`git fetch` **打印了**
  `c1fe99b..01b8e2e  main -> origin/main` 却**根本没创建** `.git/refs/remotes/origin/main`
  （连 `refs/remotes/origin/` 目录都不存在）⇒ 随后 `git merge --ff-only origin/main` 报
  `not something we can merge`。
  **判别**：`git cat-file -t <sha>` —— 对象其实已经下载到本地。
  **对策**：直接用远端 SHA 快进 `git merge --ff-only <sha>`，
  再手动补 ref：`mkdir -p .git/refs/remotes/origin && printf '%s\n' <sha> > .git/refs/remotes/origin/main`
  （手动写 ref 文件不受这个锁问题影响，实测有效）。
- Windows 快进前要先 `git checkout -- .`（丢弃已提交的本地改动）+ `git clean -fd gesture_project`
  （清未跟踪副本），否则 ff 被拒。
  **另外**：远端提交里的文件若在 Windows 侧是**未跟踪**的（如 `.workbuddy/`、`zcu104_build_out/`、
  `gf_probe_b_out.log`），ff 会报 `untracked working tree files would be overwritten`。
  **对策**：先逐个 md5 确认与远端版本相同，再 `rm` 掉这些未跟踪副本，然后 ff。
- **提交信息里不要用反引号**：会被 shell 当命令替换吃掉（已踩过一次）。
- **`wsl.exe -- bash -lc '...for f in ...; do ... "$f" ...'` 里的 `$f` 会被外层 shell 吃掉**，
  循环体拿到空值（症状：所有输出相同 / 读到空输入）。**对策**：把循环写进 `.sh` 文件再 `bash <file>`；
  或改用 `wsl.exe -u steveguo -- <cmd> <literal-args>`。
  **同理：含反斜杠转义的代码（`'\r'` 之类）不要用 heredoc 传**，heredoc 曾把 `\\r` 变成真 CR 字节。
- **`sync_repo.sh` 只能在 WSL 内运行**（硬编码 `/mnt/c/...` 与 `/home/...`）。
  从 Windows 侧跑会把**两端**都报成"(不是 git 仓库)" —— 已加前置检查直接拦下并给正确用法。
- **换行策略已固定**：仓库根 `.gitattributes` 把会被执行的文本钉成 LF（`*.sh/*.py/*.c/*.h/*.sv/*.tcl/*.bb/*.dtsi/...`）。
  历史上仓库本来就是 1181/1181 全 LF；问题出在 Windows 侧写入方式，**不要再用"自愈"补丁去修换行**。

## 环境
WSL2 `Ubuntu-22.04`；PetaLinux 2023.2 在 `~/petalinux/2023.2`，工程 `~/gf_linux_ws/gf_linux`。
Vivado/Vitis/XSCT 在 **Windows** `E:\Xilinx`；WSL 只用
`cmd.exe /d /s /c "pushd <win-dir> && call <tool>.bat ..."` 拉起（**必须 pushd**）。
**大文件绝不直接操作 `/mnt/*`**（9p 实测 ~30 MB/s 且被反复读）——先 `cp` 到 `$HOME`。
**需要 sudo 的直接让用户跑，不要绕。**

## 相关技能
`wsl-vivado-build`（WSL 驱动 Windows Vivado）、`petalinux-wsl-build`（PetaLinux 在 WSL 上的坑）。
