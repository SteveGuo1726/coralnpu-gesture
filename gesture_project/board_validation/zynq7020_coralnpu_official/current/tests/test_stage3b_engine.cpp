// PROJECT_LOCAL_MOD: data-level Verilator regression for the stage3b tensor
// engine. It loads the real exported tensors and checks every output byte.
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vcoralnpu_stage3b_tensor_engine.h"

using s8 = int8_t;
using s32 = int32_t;
#include "static_cnn_stage3b_real_fist_int8.h"

static void tick(Vcoralnpu_stage3b_tensor_engine& dut) {
  dut.clk = 0;
  dut.eval();
  dut.clk = 1;
  dut.eval();
}

static void write_word(Vcoralnpu_stage3b_tensor_engine& dut, unsigned kind,
                       unsigned address, uint32_t value) {
  dut.mem_we = 1;
  dut.mem_kind = kind;
  dut.mem_addr = address;
  dut.mem_wdata = value;
  tick(dut);
  dut.mem_we = 0;
}

static uint32_t read_word(Vcoralnpu_stage3b_tensor_engine& dut,
                          unsigned kind, unsigned address) {
  dut.mem_we = 0;
  dut.mem_re = 1;
  dut.mem_kind = kind;
  dut.mem_addr = address;
  tick(dut);  // Explicit read command reaches the engine.
  dut.mem_re = 0;
  tick(dut);  // Engine issues one full-width synchronous BRAM read.
  tick(dut);  // The selected 64-bit RAM word reaches the response pipeline.
  tick(dut);  // The requested 32-bit half is now visible on mem_rdata.
  return dut.mem_rdata;
}

static uint32_t pack4(const s8* values) {
  return static_cast<uint32_t>(static_cast<uint8_t>(values[0])) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[1])) << 8) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[2])) << 16) |
         (static_cast<uint32_t>(static_cast<uint8_t>(values[3])) << 24);
}

int main() {
  Vcoralnpu_stage3b_tensor_engine dut;
  dut.rstn = 0;
  dut.start = 0;
  dut.mem_we = 0;
  dut.mem_re = 0;
  dut.mem_kind = 0;
  dut.mem_addr = 0;
  dut.mem_wdata = 0;
  dut.dma_we = 0;
  dut.dma_kind = 0;
  dut.dma_addr = 0;
  dut.dma_wdata = 0;
  dut.dma_pool_re = 0;
  dut.dma_pool_addr = 0;
  for (int i = 0; i < 3; ++i) tick(dut);
  dut.rstn = 1;

  for (unsigned word = 0; word < STAGE3B_INPUT_BYTES / 4; ++word)
    write_word(dut, 0, word, pack4(&kStage3bTensor24[word * 4]));

  for (unsigned word = 0; word < STAGE3B_WEIGHT_BYTES / 4; ++word)
    write_word(dut, 1, word, pack4(&kStage3bWeights[word * 4]));

  for (unsigned ch = 0; ch < STAGE3B_C; ++ch) {
    write_word(dut, 2, ch, static_cast<uint32_t>(kStage3bBias[ch]));
    write_word(dut, 3, ch, static_cast<uint32_t>(kStage3bMultiplier[ch]));
    write_word(dut, 4, ch, static_cast<uint32_t>(kStage3bShift[ch]));
  }

  dut.start = 1;
  tick(dut);
  dut.start = 0;
  unsigned long long cycles = 0;
  while (!dut.done && cycles < 12000000ULL) {
    tick(dut);
    ++cycles;
  }
  if (!dut.done) {
    std::fprintf(stderr, "TIMEOUT cycles=%llu fault=%u\n", cycles, dut.fault);
    return 2;
  }

  for (unsigned word = 0; word < STAGE3B_OUTPUT_BYTES / 8; ++word) {
    uint32_t low = read_word(dut, 5, word * 2);
    uint32_t high = read_word(dut, 5, word * 2 + 1);
    uint32_t actual[2] = {low, high};
    for (unsigned half = 0; half < 2; ++half) {
      const unsigned byte_base = word * 8 + half * 4;
      for (unsigned byte = 0; byte < 4; ++byte) {
        const unsigned index = byte_base + byte;
        const int got = static_cast<int8_t>((actual[half] >> (byte * 8)) & 0xff);
        const int expected = kStage3bTensor25Expected[index];
        if (got != expected) {
          std::fprintf(stderr, "MISMATCH index=%u got=%d expected=%d cycles=%llu\n",
                       index, got, expected, cycles);
          return 3;
        }
      }
    }
  }
  for (unsigned word = 0; word < STAGE3B_POOL_BYTES / 4; ++word) {
    uint32_t actual_word = read_word(dut, 6, word);
    for (unsigned byte = 0; byte < 4; ++byte) {
      const unsigned index = word * 4 + byte;
      const int got = static_cast<int8_t>((actual_word >> (byte * 8)) & 0xff);
      const int expected = kStage3bTensor26Expected[index];
      if (got != expected) {
        std::fprintf(stderr, "POOL_MISMATCH index=%u got=%d expected=%d cycles=%llu\n",
                     index, got, expected, cycles);
        return 4;
      }
    }
  }
  std::printf("PASS stage3b tensor engine cycles=%llu tensor25=%u tensor26=%u\n",
              cycles, STAGE3B_OUTPUT_BYTES, STAGE3B_POOL_BYTES);
  return 0;
}
