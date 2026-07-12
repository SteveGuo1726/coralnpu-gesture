#include <stdint.h>

#define ROWHANDOFF_BASE_ADDR 0x43C00000u
#define MAILBOX_BASE_ADDR    0x00201000u

#define REG_MAGIC           0x00u
#define REG_VERSION         0x04u
#define REG_CONTROL         0x08u
#define REG_HIT             0x10u
#define REG_MISS            0x14u
#define REG_INVALIDATE      0x18u
#define REG_PRODUCE         0x1Cu
#define REG_TAIL_HIT        0x20u
#define REG_INTERIOR        0x24u
#define REG_RIGHT_EDGE      0x28u
#define REG_ROW_LAST        0x2Cu
#define REG_TRACE_WORD      0x30u
#define REG_EVENT_IN        0x40u
#define REG_EVENT_STATUS    0x44u
#define REG_CORECSR_RADDR   0x80u
#define REG_CORECSR_RDATA0  0x84u
#define REG_CORECSR_RDATA1  0x88u
#define REG_CORECSR_RDATA2  0x8Cu
#define REG_CORECSR_RDATA3  0x90u
#define REG_CORECSR_STATUS  0x94u
#define REG_CORECSR_EVENT_IN 0xB0u

#define MAILBOX_MAGIC       0x5248434Bu
#define MAILBOX_PASS        0x50415353u
#define MAILBOX_FAIL        0x4641494Cu

static const uint32_t rowhandoff_events[] = {
    0x00000001u,
    0x00180040u, 0x00180008u, 0x00180080u, 0x00180120u,
    0x00190040u, 0x00190002u, 0x00190004u, 0x00190080u, 0x00190120u,
    0x001A0040u, 0x001A0002u, 0x001A0004u, 0x001A0080u, 0x001A0120u,
    0x001B0040u, 0x001B0002u, 0x001B0004u, 0x001B0080u, 0x001B0120u,
    0x001C0040u, 0x001C0002u, 0x001C0004u, 0x001C0080u, 0x001C0120u,
    0x001D0040u, 0x001D0002u, 0x001D0004u, 0x001D0080u, 0x001D0120u,
    0x001E0040u, 0x001E0002u, 0x001E0004u, 0x001E0080u, 0x001E0120u,
    0x001F0040u, 0x001F0002u, 0x001F0004u, 0x001F0080u, 0x001F0120u,
    0x00200040u, 0x00200002u, 0x00200004u, 0x00200080u, 0x00200120u,
    0x00210040u, 0x00210002u, 0x00210004u, 0x00210080u, 0x00210120u,
    0x00220040u, 0x00220002u, 0x00220004u, 0x00220080u, 0x00220120u,
    0x00230040u, 0x00230002u, 0x00230004u, 0x00230080u, 0x00230120u,
    0x00240040u, 0x00240002u, 0x00240004u, 0x00240080u, 0x00240120u,
    0x00250040u, 0x00250002u, 0x00250004u, 0x00250080u, 0x00250120u,
    0x00260040u, 0x00260002u, 0x00260004u, 0x00260080u, 0x00260120u,
    0x00270040u, 0x00270002u, 0x00270004u, 0x00270080u, 0x00270120u,
    0x00280040u, 0x00280002u, 0x00280004u, 0x00280080u, 0x00280120u,
    0x00290040u, 0x00290002u, 0x00290004u, 0x00290080u, 0x00290120u,
    0x002A0040u, 0x002A0002u, 0x002A0004u, 0x002A0080u, 0x002A0120u,
    0x002B0040u, 0x002B0002u, 0x002B0004u, 0x002B0080u, 0x002B0120u,
    0x002C0040u, 0x002C0002u, 0x002C0004u, 0x002C0080u, 0x002C0120u,
    0x002D0040u, 0x002D0002u, 0x002D0004u, 0x002D0080u, 0x002D0120u,
    0x002E0010u,
};

static inline void dsb_sy(void) {
  __asm__ volatile("dsb sy" ::: "memory");
}

static void delay_cycles(unsigned count) {
  while (count-- != 0u) {
    __asm__ volatile("nop");
  }
}

static void write32(uint32_t offset, uint32_t value) {
  volatile uint32_t *addr = (volatile uint32_t *)(ROWHANDOFF_BASE_ADDR + offset);
  *addr = value;
  dsb_sy();
}

static uint32_t read32(uint32_t offset) {
  volatile uint32_t *addr = (volatile uint32_t *)(ROWHANDOFF_BASE_ADDR + offset);
  uint32_t value = *addr;
  dsb_sy();
  return value;
}

static void mailbox_write(unsigned index, uint32_t value) {
  volatile uint32_t *mailbox = (volatile uint32_t *)MAILBOX_BASE_ADDR;
  mailbox[index] = value;
  dsb_sy();
}

static uint32_t check_equal(uint32_t observed, uint32_t expected, uint32_t bit) {
  return (observed == expected) ? 0u : bit;
}

static void corecsr_read128(uint32_t official_addr, uint32_t out_words[4]) {
  write32(REG_CORECSR_RADDR, official_addr);
  delay_cycles(256u);
  out_words[0] = read32(REG_CORECSR_RDATA0);
  out_words[1] = read32(REG_CORECSR_RDATA1);
  out_words[2] = read32(REG_CORECSR_RDATA2);
  out_words[3] = read32(REG_CORECSR_RDATA3);
}

void rowhandoff_main(void) {
  mailbox_write(0u, 0u);
  mailbox_write(1u, 0u);
  mailbox_write(2u, 0u);

  write32(REG_CONTROL, 0x00000014u);
  delay_cycles(1024u);

  write32(REG_CONTROL, 0x00000010u);

  volatile uint32_t *event_in =
      (volatile uint32_t *)(ROWHANDOFF_BASE_ADDR + REG_CORECSR_EVENT_IN);
  for (unsigned i = 0u; i < sizeof(rowhandoff_events) / sizeof(rowhandoff_events[0]); ++i) {
    *event_in = rowhandoff_events[i];
    dsb_sy();
  }

  uint32_t magic = read32(REG_MAGIC);
  uint32_t version = read32(REG_VERSION);
  uint32_t control = read32(REG_CONTROL);
  uint32_t hit = read32(REG_HIT);
  uint32_t miss = read32(REG_MISS);
  uint32_t invalidate = read32(REG_INVALIDATE);
  uint32_t produce = read32(REG_PRODUCE);
  uint32_t tail_hit = read32(REG_TAIL_HIT);
  uint32_t interior = read32(REG_INTERIOR);
  uint32_t right_edge = read32(REG_RIGHT_EDGE);
  uint32_t row_last = read32(REG_ROW_LAST);
  uint32_t trace_word = read32(REG_TRACE_WORD);
  uint32_t event_status = read32(REG_CORECSR_STATUS);
  uint32_t corecsr_820[4];
  uint32_t corecsr_830[4];
  uint32_t corecsr_840[4];
  corecsr_read128(0x00000820u, corecsr_820);
  corecsr_read128(0x00000830u, corecsr_830);
  corecsr_read128(0x00000840u, corecsr_840);

  uint32_t fail_mask = 0u;
  fail_mask |= check_equal(magic, 0x52484F57u, 1u << 0);
  fail_mask |= check_equal(version, 0x20260710u, 1u << 1);
  fail_mask |= check_equal(control, 0x00000010u, 1u << 2);
  fail_mask |= check_equal(hit, 21u, 1u << 3);
  fail_mask |= check_equal(miss, 1u, 1u << 4);
  fail_mask |= check_equal(invalidate, 1u, 1u << 5);
  fail_mask |= check_equal(produce, 22u, 1u << 6);
  fail_mask |= check_equal(tail_hit, 21u, 1u << 7);
  fail_mask |= check_equal(interior, 22u, 1u << 8);
  fail_mask |= check_equal(right_edge, 22u, 1u << 9);
  fail_mask |= check_equal(row_last, 45u, 1u << 10);
  fail_mask |= check_equal((event_status >> 16) & 0xFFFFu, 111u, 1u << 11);
  fail_mask |= check_equal(corecsr_820[0], 21u, 1u << 12);
  fail_mask |= check_equal(corecsr_820[1], 1u, 1u << 13);
  fail_mask |= check_equal(corecsr_820[2], 1u, 1u << 14);
  fail_mask |= check_equal(corecsr_820[3], 22u, 1u << 15);
  fail_mask |= check_equal(corecsr_830[0], 21u, 1u << 16);
  fail_mask |= check_equal(corecsr_830[1], 22u, 1u << 17);
  fail_mask |= check_equal(corecsr_830[2], 22u, 1u << 18);
  fail_mask |= check_equal(corecsr_830[3], 45u, 1u << 19);

  mailbox_write(0u, MAILBOX_MAGIC);
  mailbox_write(1u, (fail_mask == 0u) ? MAILBOX_PASS : MAILBOX_FAIL);
  mailbox_write(2u, fail_mask);
  mailbox_write(3u, control);
  mailbox_write(4u, hit);
  mailbox_write(5u, miss);
  mailbox_write(6u, invalidate);
  mailbox_write(7u, produce);
  mailbox_write(8u, tail_hit);
  mailbox_write(9u, interior);
  mailbox_write(10u, right_edge);
  mailbox_write(11u, row_last);
  mailbox_write(12u, trace_word);
  mailbox_write(13u, event_status);
  mailbox_write(14u, corecsr_820[0]);
  mailbox_write(15u, corecsr_820[1]);
  mailbox_write(16u, corecsr_820[2]);
  mailbox_write(17u, corecsr_820[3]);
  mailbox_write(18u, corecsr_830[0]);
  mailbox_write(19u, corecsr_830[1]);
  mailbox_write(20u, corecsr_830[2]);
  mailbox_write(21u, corecsr_830[3]);
  mailbox_write(22u, corecsr_840[1]);
}

__attribute__((naked, noreturn, section(".text.start")))
void _start(void) {
  __asm__ volatile(
      "ldr sp, =0x00200000\n"
      "bl rowhandoff_main\n"
      "1:\n"
      "wfe\n"
      "b 1b\n");
}
