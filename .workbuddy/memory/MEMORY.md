# MEMORY.md — coralnpu-gesture 长期项目备忘

> 详情见 `gesture_project/docs/` 下的上下文文档与 `会话交接_最高优先级`
> （最新记录在顶部）。这里只放最容易忘、代价最高的。

## 项目
自研 FPGA NPU 跑 HaGRID-18 静态手势（INT8 98.88%），核心创新 **DMP 双乘打包**（一个 DSP48 当两个用）。
- 7020：**41.9 FPS**，`0x600D600D` —— 不可回退的基线。
- ZCU104：**36.96 FPS**（PL 17.02 ms + **CPU 侧 10.04 ms**）；PetaLinux 构建完成，
  镜像含 `gf-npu` / `v4l2-utils` / `usbutils` / `libjpeg62`。

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
- Windows 快进前要先 `git checkout -- .`（丢弃已提交的本地改动）+ `git clean -fd gesture_project`
  （清未跟踪副本），否则 ff 被拒。
- **提交信息里不要用反引号**：会被 shell 当命令替换吃掉（已踩过一次）。

## 环境
WSL2 `Ubuntu-22.04`；PetaLinux 2023.2 在 `~/petalinux/2023.2`，工程 `~/gf_linux_ws/gf_linux`。
Vivado/Vitis/XSCT 在 **Windows** `E:\Xilinx`；WSL 只用
`cmd.exe /d /s /c "pushd <win-dir> && call <tool>.bat ..."` 拉起（**必须 pushd**）。
**大文件绝不直接操作 `/mnt/*`**（9p 实测 ~30 MB/s 且被反复读）——先 `cp` 到 `$HOME`。
**需要 sudo 的直接让用户跑，不要绕。**

## 相关技能
`wsl-vivado-build`（WSL 驱动 Windows Vivado）、`petalinux-wsl-build`（PetaLinux 在 WSL 上的坑）。
