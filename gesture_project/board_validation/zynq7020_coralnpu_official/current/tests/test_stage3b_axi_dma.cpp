#include <cstdint>
#include <cstdio>
#include <vector>

#include "Vcoralnpu_stage3b_axi_dma.h"

namespace {
constexpr unsigned kInputWords = 9216;
constexpr unsigned kWeightWords = 9216;
constexpr unsigned kChannelWords = 64;
constexpr unsigned kPoolElements = 9216;

void tick(Vcoralnpu_stage3b_axi_dma& dut) {
  dut.clk = 0;
  dut.eval();
  dut.clk = 1;
  dut.eval();
}

uint32_t pattern(unsigned section, unsigned index) {
  return 0x51000000u | (section << 20) | index;
}
}  // namespace

int main() {
  Vcoralnpu_stage3b_axi_dma dut;
  dut.clk = 0;
  dut.rstn = 0;
  dut.start_load = 0;
  dut.start_store = 0;
  dut.input_base_addr = 0x00100000;
  dut.weight_base_addr = 0x00200000;
  dut.bias_base_addr = 0x00300000;
  dut.multiplier_base_addr = 0x00400000;
  dut.shift_base_addr = 0x00500000;
  dut.pool_base_addr = 0x00600000;
  dut.m_axi_awready = 1;
  dut.m_axi_wready = 1;
  dut.m_axi_arready = 1;
  dut.m_axi_bvalid = 0;
  dut.m_axi_bid = 1;
  dut.m_axi_bresp = 0;
  dut.m_axi_rvalid = 0;
  dut.m_axi_rdata = 0;
  dut.m_axi_rid = 1;
  dut.m_axi_rresp = 0;
  dut.m_axi_rlast = 0;
  dut.pool_rdata = 0;
  for (int i = 0; i < 3; ++i) tick(dut);
  dut.rstn = 1;

  std::vector<uint32_t> staged[5];
  staged[0].resize(kInputWords);
  staged[1].resize(kWeightWords);
  staged[2].resize(kChannelWords);
  staged[3].resize(kChannelWords);
  staged[4].resize(kChannelWords);

  bool read_pending = false;
  uint32_t read_addr = 0;
  unsigned read_words = 0;
  unsigned read_index = 0;
  unsigned burst_count = 0;
  dut.start_load = 1;
  tick(dut);
  dut.start_load = 0;

  for (unsigned cycles = 0; dut.busy && cycles < 100000; ++cycles) {
    dut.m_axi_rvalid = read_pending ? 1 : 0;
    dut.m_axi_rlast = read_pending && (read_index + 1 == read_words);
    unsigned section = 0;
    unsigned base = 0x00100000;
    if (read_addr >= 0x00500000) { section = 4; base = 0x00500000; }
    else if (read_addr >= 0x00400000) { section = 3; base = 0x00400000; }
    else if (read_addr >= 0x00300000) { section = 2; base = 0x00300000; }
    else if (read_addr >= 0x00200000) { section = 1; base = 0x00200000; }
    dut.m_axi_rdata = pattern(section, ((read_addr - base) >> 2) + read_index);

    dut.eval();
    const bool ar_fire = dut.m_axi_arvalid && dut.m_axi_arready;
    const bool r_fire = dut.m_axi_rvalid && dut.m_axi_rready;
    const bool stage_fire = dut.stage_we;
    if (stage_fire) {
      const unsigned kind = dut.stage_kind;
      const unsigned address = dut.stage_addr;
      if (kind > 4 || address >= staged[kind].size() ||
          dut.stage_wdata != pattern(kind, address)) {
        std::fprintf(stderr, "LOAD_MISMATCH kind=%u addr=%u data=%08x\n",
                     kind, address, dut.stage_wdata);
        return 2;
      }
      staged[kind][address] = dut.stage_wdata;
    }
    tick(dut);
    if (ar_fire) {
      if (read_pending || dut.m_axi_arlen > 255) {
        std::fprintf(stderr, "AR_PROTOCOL_ERROR\n");
        return 3;
      }
      read_pending = true;
      read_addr = dut.m_axi_araddr;
      read_words = dut.m_axi_arlen + 1;
      read_index = 0;
      ++burst_count;
    }
    if (r_fire) {
      if (++read_index == read_words) read_pending = false;
    }
  }
  if (dut.busy || dut.fault || burst_count != 75) {
    std::fprintf(stderr, "LOAD_FAILED busy=%u fault=%u bursts=%u\n",
                 dut.busy, dut.fault, burst_count);
    return 4;
  }
  for (unsigned kind = 0; kind < 5; ++kind) {
    for (unsigned i = 0; i < staged[kind].size(); ++i) {
      if (staged[kind][i] != pattern(kind, i)) {
        std::fprintf(stderr, "LOAD_MISSING kind=%u addr=%u\n", kind, i);
        return 5;
      }
    }
  }

  std::vector<uint64_t> pool64(kPoolElements / 8);
  std::vector<uint32_t> stored(kPoolElements, 0);
  for (unsigned i = 0; i < pool64.size(); ++i) {
    uint64_t packed = 0;
    for (unsigned byte = 0; byte < 8; ++byte) {
      const uint8_t value = static_cast<uint8_t>((i * 8 + byte) * 37U);
      packed |= static_cast<uint64_t>(value) << (byte * 8);
    }
    pool64[i] = packed;
  }
  bool write_response_pending = false;
  uint32_t write_addr = 0;
  unsigned store_bursts = 0;
  dut.start_store = 1;
  tick(dut);
  dut.start_store = 0;
  for (unsigned cycles = 0; dut.busy && cycles < 100000; ++cycles) {
    dut.pool_rdata = pool64[dut.pool_addr];
    dut.m_axi_bvalid = write_response_pending ? 1 : 0;
    dut.eval();
    const bool aw_fire = dut.m_axi_awvalid && dut.m_axi_awready;
    const bool w_fire = dut.m_axi_wvalid && dut.m_axi_wready;
    const bool b_fire = dut.m_axi_bvalid && dut.m_axi_bready;
    if (aw_fire) {
      write_addr = dut.m_axi_awaddr;
      if (dut.m_axi_awlen + 1 > 256) {
        std::fprintf(stderr, "AW_BURST_TOO_LONG\n");
        return 6;
      }
      ++store_bursts;
    }
    if (w_fire) {
      const unsigned word = ((write_addr - 0x00600000) >> 2);
      if (word >= stored.size()) {
        std::fprintf(stderr, "STORE_ADDRESS_ERROR word=%u write_addr=%08x bursts=%u awlen=%u state_wlast=%u\n",
                     word, write_addr, store_bursts, dut.m_axi_awlen, dut.m_axi_wlast);
        return 7;
      }
      stored[word] = dut.m_axi_wdata;
      write_addr += 4;
      if (dut.m_axi_wlast) write_response_pending = true;
    }
    tick(dut);
    if (b_fire) write_response_pending = false;
  }
  if (dut.busy || dut.fault || store_bursts != 36) {
    std::fprintf(stderr, "STORE_FAILED busy=%u fault=%u bursts=%u\n",
                 dut.busy, dut.fault, store_bursts);
    return 8;
  }
  for (unsigned i = 0; i < stored.size(); ++i) {
    const int8_t source = static_cast<int8_t>(static_cast<uint8_t>(i * 37U));
    const uint32_t expected = static_cast<uint32_t>(static_cast<int32_t>(source));
    if (stored[i] != expected) {
      std::fprintf(stderr, "STORE_MISMATCH addr=%u got=%08x expected=%08x\n",
                   i, stored[i], expected);
      return 9;
    }
  }
  std::printf("PASS stage3b AXI DMA load_bursts=%u store_bursts=%u words=%u\n",
              burst_count, store_bursts, kInputWords + kWeightWords + 3 * kChannelWords + kPoolElements);
  return 0;
}
