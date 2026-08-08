#include <cstdint>
#include <cstdio>
#include <vector>

#include "Vstage3b_dma_integration_top.h"

using s8 = int8_t;
using s32 = int32_t;
#include "static_cnn_stage3b_real_fist_int8.h"

namespace {
constexpr uint32_t kInputBase = 0x01000000u;
constexpr uint32_t kWeightBase = 0x01100000u;
constexpr uint32_t kBiasBase = 0x01200000u;
constexpr uint32_t kMultBase = 0x01300000u;
constexpr uint32_t kShiftBase = 0x01400000u;
constexpr uint32_t kPoolBase = 0x01500000u;

void tick(Vstage3b_dma_integration_top& dut) {
  dut.clk = 0;
  dut.eval();
  dut.clk = 1;
  dut.eval();
}

uint32_t pack4(const s8* values) {
  return static_cast<uint32_t>(static_cast<uint8_t>(values[0])) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[1])) << 8) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[2])) << 16) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[3])) << 24);
}

uint32_t source_word(uint32_t address) {
  const uint32_t index = (address & 0x000fffffu) >> 2;
  if (address >= kInputBase && address < kInputBase + STAGE3B_INPUT_BYTES)
    return pack4(&kStage3bTensor24[index * 4]);
  if (address >= kWeightBase && address < kWeightBase + STAGE3B_WEIGHT_BYTES)
    return pack4(&kStage3bWeights[index * 4]);
  if (address >= kBiasBase && address < kBiasBase + STAGE3B_C * 4)
    return static_cast<uint32_t>(kStage3bBias[index]);
  if (address >= kMultBase && address < kMultBase + STAGE3B_C * 4)
    return static_cast<uint32_t>(kStage3bMultiplier[index]);
  if (address >= kShiftBase && address < kShiftBase + STAGE3B_C * 4)
    return static_cast<uint32_t>(kStage3bShift[index]);
  return 0xdeadbeefu;
}

void drive_idle(Vstage3b_dma_integration_top& dut) {
  dut.m_axi_awready = 1;
  dut.m_axi_wready = 1;
  dut.m_axi_arready = 1;
  dut.m_axi_bvalid = 0;
  dut.m_axi_bresp = 0;
  dut.m_axi_rvalid = 0;
  dut.m_axi_rdata = 0;
  dut.m_axi_rresp = 0;
  dut.m_axi_rlast = 0;
}
}  // namespace

int main() {
  Vstage3b_dma_integration_top dut;
  dut.clk = 0;
  dut.rstn = 0;
  dut.start_load = 0;
  dut.start_engine = 0;
  dut.start_store = 0;
  dut.input_base_addr = kInputBase;
  dut.weight_base_addr = kWeightBase;
  dut.bias_base_addr = kBiasBase;
  dut.multiplier_base_addr = kMultBase;
  dut.shift_base_addr = kShiftBase;
  dut.pool_base_addr = kPoolBase;
  drive_idle(dut);
  for (int i = 0; i < 3; ++i) tick(dut);
  dut.rstn = 1;

  bool read_pending = false;
  uint32_t read_addr = 0;
  unsigned read_words = 0;
  unsigned read_index = 0;
  unsigned read_bursts = 0;
  dut.start_load = 1;
  tick(dut);
  dut.start_load = 0;
  for (unsigned cycles = 0; dut.dma_busy && cycles < 100000; ++cycles) {
    dut.m_axi_rvalid = read_pending;
    dut.m_axi_rdata = source_word(read_addr + read_index * 4);
    dut.m_axi_rlast = read_pending && (read_index + 1 == read_words);
    dut.eval();
    const bool ar_fire = dut.m_axi_arvalid && dut.m_axi_arready;
    const bool r_fire = dut.m_axi_rvalid && dut.m_axi_rready;
    const uint32_t araddr = dut.m_axi_araddr;
    const unsigned arwords = dut.m_axi_arlen + 1;
    tick(dut);
    if (ar_fire) {
      if (read_pending || arwords > 256) return 2;
      read_pending = true;
      read_addr = araddr;
      read_words = arwords;
      read_index = 0;
      ++read_bursts;
    }
    if (r_fire && ++read_index == read_words) read_pending = false;
  }
  if (dut.dma_busy || dut.dma_fault || read_bursts != 75) {
    std::fprintf(stderr, "DMA_LOAD_FAILED busy=%u fault=%u bursts=%u\n",
                 dut.dma_busy, dut.dma_fault, read_bursts);
    return 3;
  }

  dut.start_engine = 1;
  tick(dut);
  dut.start_engine = 0;
  unsigned long long engine_cycles = 0;
  while (!dut.engine_done && engine_cycles < 12000000ULL) {
    drive_idle(dut);
    tick(dut);
    ++engine_cycles;
  }
  if (!dut.engine_done || dut.engine_fault) {
    std::fprintf(stderr, "ENGINE_FAILED done=%u fault=%u cycles=%llu\n",
                 dut.engine_done, dut.engine_fault, engine_cycles);
    return 4;
  }

  std::vector<uint32_t> ddr_pool(STAGE3B_POOL_BYTES, 0);
  bool b_pending = false;
  uint32_t write_addr = 0;
  unsigned write_bursts = 0;
  dut.start_store = 1;
  tick(dut);
  dut.start_store = 0;
  for (unsigned cycles = 0; dut.dma_busy && cycles < 100000; ++cycles) {
    dut.m_axi_bvalid = b_pending;
    dut.eval();
    const bool aw_fire = dut.m_axi_awvalid && dut.m_axi_awready;
    const bool w_fire = dut.m_axi_wvalid && dut.m_axi_wready;
    const bool wlast = dut.m_axi_wlast;
    const bool b_fire = dut.m_axi_bvalid && dut.m_axi_bready;
    const uint32_t awaddr = dut.m_axi_awaddr;
    const uint32_t wdata = dut.m_axi_wdata;
    tick(dut);
    if (aw_fire) {
      if (dut.m_axi_awlen + 1 > 256) return 5;
      write_addr = awaddr;
      ++write_bursts;
    }
    if (w_fire) {
      const unsigned index = (write_addr - kPoolBase) >> 2;
      if (index >= ddr_pool.size()) return 6;
      ddr_pool[index] = wdata;
      write_addr += 4;
      if (wlast) b_pending = true;
    }
    if (b_fire) b_pending = false;
  }
  if (dut.dma_busy || dut.dma_fault || write_bursts != 36) {
    std::fprintf(stderr, "DMA_STORE_FAILED busy=%u fault=%u bursts=%u\n",
                 dut.dma_busy, dut.dma_fault, write_bursts);
    return 7;
  }
  for (unsigned index = 0; index < ddr_pool.size(); ++index) {
    const s32 actual = static_cast<s32>(ddr_pool[index]);
    if (actual != kStage3bTensor26Expected[index]) {
      std::fprintf(stderr, "POOL_MISMATCH index=%u got=%d expected=%d\n",
                   index, actual, kStage3bTensor26Expected[index]);
      return 8;
    }
  }
  std::printf("PASS stage3b DMA integration load_bursts=%u engine_cycles=%llu store_bursts=%u pool_bytes=%u\n",
              read_bursts, engine_cycles, write_bursts, STAGE3B_POOL_BYTES);
  return 0;
}
