#include <stdbool.h>
#include <stdint.h>

#define CORALNPU_BASE 0x70000000u
#define CORALNPU_CSR_BASE (CORALNPU_BASE + 0x30000u)

#define CORALNPU_RESET_CONTROL (CORALNPU_CSR_BASE + 0x0000u)
#define CORALNPU_PC_START      (CORALNPU_CSR_BASE + 0x0004u)
#define CORALNPU_STATUS        (CORALNPU_CSR_BASE + 0x0008u)

#define ROWHANDOFF_HIT_COUNT        (CORALNPU_CSR_BASE + 0x0820u)
#define ROWHANDOFF_MISS_COUNT       (CORALNPU_CSR_BASE + 0x0824u)
#define ROWHANDOFF_INVALIDATE_COUNT (CORALNPU_CSR_BASE + 0x0828u)
#define ROWHANDOFF_PRODUCE_COUNT    (CORALNPU_CSR_BASE + 0x082cu)
#define ROWHANDOFF_TAIL_HIT_COUNT   (CORALNPU_CSR_BASE + 0x0830u)
#define INTERIOR_ROW_ENTER_COUNT    (CORALNPU_CSR_BASE + 0x0834u)
#define RIGHT_EDGE_DONE_COUNT       (CORALNPU_CSR_BASE + 0x0838u)
#define ROWHANDOFF_ROW_OUT_Y_LAST   (CORALNPU_CSR_BASE + 0x083cu)

static inline volatile uint32_t *reg32(uint32_t addr) {
  return (volatile uint32_t *)(uintptr_t)addr;
}

struct RowhandoffCounters {
  uint32_t hit_count;
  uint32_t miss_count;
  uint32_t invalidate_count;
  uint32_t produce_count;
  uint32_t tail_hit_count;
  uint32_t interior_row_enter_count;
  uint32_t right_edge_done_count;
  uint32_t row_out_y_last;
};

static inline void coralnpu_start(uint32_t start_pc) {
  *reg32(CORALNPU_PC_START) = start_pc;
  *reg32(CORALNPU_RESET_CONTROL) = 1u;
  *reg32(CORALNPU_RESET_CONTROL) = 0u;
}

static inline bool coralnpu_wait_halted(void) {
  while (true) {
    uint32_t status = *reg32(CORALNPU_STATUS);
    bool halted = (status & 0x1u) != 0;
    bool fault = (status & 0x2u) != 0;
    if (fault) {
      return false;
    }
    if (halted) {
      return true;
    }
  }
}

static inline struct RowhandoffCounters read_rowhandoff_counters(void) {
  struct RowhandoffCounters counters;
  counters.hit_count = *reg32(ROWHANDOFF_HIT_COUNT);
  counters.miss_count = *reg32(ROWHANDOFF_MISS_COUNT);
  counters.invalidate_count = *reg32(ROWHANDOFF_INVALIDATE_COUNT);
  counters.produce_count = *reg32(ROWHANDOFF_PRODUCE_COUNT);
  counters.tail_hit_count = *reg32(ROWHANDOFF_TAIL_HIT_COUNT);
  counters.interior_row_enter_count = *reg32(INTERIOR_ROW_ENTER_COUNT);
  counters.right_edge_done_count = *reg32(RIGHT_EDGE_DONE_COUNT);
  counters.row_out_y_last = *reg32(ROWHANDOFF_ROW_OUT_Y_LAST);
  return counters;
}

static inline bool rowhandoff_mode1_full_match(struct RowhandoffCounters c) {
  return c.hit_count == 45u &&
         c.miss_count == 1u &&
         c.invalidate_count == 1u &&
         c.produce_count == 46u &&
         c.tail_hit_count == 21u &&
         c.interior_row_enter_count == 46u &&
         c.right_edge_done_count == 46u &&
         c.row_out_y_last == 46u;
}
