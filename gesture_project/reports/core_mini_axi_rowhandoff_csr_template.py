# Copyright 2026
# rowhandoff CoreAxiCSR readback template

import cocotb
import numpy as np

from coralnpu_test_utils.core_mini_axi_interface import AxiResp, CoreMiniAxiInterface


@cocotb.test()
async def core_mini_axi_rowhandoff_csr_template(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    # 这里默认 DUT 已经把 rowhandoff counter bank 接到 CoreAxiCSR。
    # 第一阶段不要求真实运行 full program，先确认 CSR decode 可读。

    valid_addrs = [
        0x30000 + 0x820,
        0x30000 + 0x824,
        0x30000 + 0x828,
        0x30000 + 0x82c,
        0x30000 + 0x830,
        0x30000 + 0x834,
        0x30000 + 0x838,
        0x30000 + 0x83c,
    ]
    for addr in valid_addrs:
        _ = await core_mini_axi.read_word(addr)

    # 邻居探针：左边一个非法地址，右边一个非法地址。
    await core_mini_axi.read_word(0x30000 + 0x081c, expected_resp=AxiResp.SLVERR)
    await core_mini_axi.read_word(0x30000 + 0x0840, expected_resp=AxiResp.SLVERR)

    # 如果后续接入 trace-only mode1_full，可把这里改成固定值断言：
    # hit = await core_mini_axi.read_word(0x30820)
    # assert hit.view(np.uint32)[0] == 45
