/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
#include "sleep.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "gestureflow_real_conv4x4_probe.h"

#define GF_BASE             0x43C00000U
#define PROBE_BASE          0xFFFF0000U
#define GF_MAGIC            0x000U
#define GF_VERSION          0x004U
#define GF_CONTROL          0x008U
#define GF_STATUS           0x00CU
#define GF_WCTRL            0x010U
#define GF_WDATA            0x014U
#define GF_BIDX             0x018U
#define GF_BDATA            0x01CU
#define GF_ACTRL            0x020U
#define GF_ADATA            0x024U
#define GF_RESULT_IDX       0x028U
#define GF_RESULT_DATA      0x02CU
#define GF_CYCLES           0x030U
#define GF_ACT_STAGE_ADDR   0x034U
#define GF_ACT_STAGE_DATA   0x038U
#define GF_JOB_CFG          0x03CU
#define GF_RQIDX            0x040U
#define GF_RQMULT           0x044U
#define GF_RQSHIFT          0x048U
#define GF_RQCTRL           0x04CU
#define GF_OUT_STAGE_ADDR   0x050U
#define GF_OUT_READ_CTRL    0x054U
#define GF_OUT_READ_DATA    0x058U
#define GF_QUANT_RESULT_IDX 0x05CU
#define GF_QUANT_RESULT_DATA 0x060U

#define RESULT_PASS         0x600D600DU
#define RESULT_FAIL         0xBAD0BAD0U
#define RESULT_DATA_ABORT   0xDA7AAB01U
#define RESULT_PREFETCH_ABORT 0xDA7AAB02U

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static volatile u32 stage = 0U;

static void store_probe(u32 index, u32 value)
{
    probe[index] = value;
    __asm__ volatile ("dsb sy" : : : "memory");
}

static void data_abort(void *unused)
{
    (void)unused;
    store_probe(0U, RESULT_DATA_ABORT);
    store_probe(1U, stage);
    while (1) { usleep(100000U); }
}

static void prefetch_abort(void *unused)
{
    (void)unused;
    store_probe(0U, RESULT_PREFETCH_ABORT);
    store_probe(1U, stage);
    while (1) { usleep(100000U); }
}

static void fail(u32 code, u32 observed)
{
    store_probe(2U, code);
    store_probe(3U, observed);
    store_probe(0U, RESULT_FAIL);
    xil_printf("GESTUREFLOW_AXIL_BASELINE_FAIL code=%08lx observed=%08lx\r\n", (unsigned long)code, (unsigned long)observed);
    while (1) { usleep(100000U); }
}

int main(void)
{
    u32 oc, tap, group, poll, value, status, cycles, real_mismatch;
    const u32 expected_base = 1024U;

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (oc = 0U; oc < 64U; ++oc) { store_probe(oc, 0U); }
    store_probe(0U, 0x47464E50U);

    stage = 0x10U;
    value = Xil_In32(GF_BASE + GF_MAGIC);
    store_probe(4U, value);
    if (value != 0x47464E50U) { fail(0x1001U, value); }
    value = Xil_In32(GF_BASE + GF_VERSION);
    store_probe(5U, value);
    if (value != 0x00010003U) { fail(0x1002U, value); }

    /* Complete deterministic 4x4 x 16-Cin-group tile transaction.
     * Every weight/activation is +1; lane N starts at bias N. */
    stage = 0x20U;
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc);
        Xil_Out32(GF_BASE + GF_BDATA, oc);
        for (tap = 0U; tap < 16U; ++tap) {
            for (group = 0U; group < 16U; ++group) {
                Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4) | (group << 8));
                Xil_Out32(GF_BASE + GF_WDATA, 0x01010101U);
            }
        }
    }

    stage = 0x30U;
    for (tap = 0U; tap < 16U; ++tap) {
      for (group = 0U; group < 16U; ++group) {
        Xil_Out32(GF_BASE + GF_ACT_STAGE_ADDR, (tap << 4) | group);
        Xil_Out32(GF_BASE + GF_ACT_STAGE_DATA, 0x01010101U);
      }
    }
    Xil_Out32(GF_BASE + GF_CONTROL, 0x2U);
    /* bit2 selects autonomous activation-BRAM execution after start. */
    Xil_Out32(GF_BASE + GF_CONTROL, 0x5U);

    stage = 0x40U;
    status = 0U;
    for (poll = 0U; poll < 1000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if ((status & (1U << 3)) != 0U) { break; }
    }
    store_probe(6U, status);
    if ((status & (1U << 4)) != 0U || (status & (1U << 3)) == 0U) { fail(0x1003U, status); }
    cycles = Xil_In32(GF_BASE + GF_CYCLES);
    store_probe(7U, cycles);
    if (cycles == 0U) { fail(0x1004U, cycles); }

    stage = 0x50U;
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_RESULT_IDX, oc);
        value = Xil_In32(GF_BASE + GF_RESULT_DATA);
        store_probe(8U + oc, value);
        if (value != expected_base + oc) { fail(0x1100U + oc, value); }
    }
    value = Xil_In32(GF_BASE + GF_RESULT_IDX);
    store_probe(24U, value);
    if (value != 0x0000FFFFU) { fail(0x1010U, value); }

    /* Exercise the actual static-model stem shape: 4x4 x RGB(Cin=3).
     * taps=16, groups=1, final input mask=0b0111, all 16 outputs active. */
    stage = 0x60U;
    Xil_Out32(GF_BASE + GF_JOB_CFG, 0xFFFF070FU);
    for (tap = 0U; tap < 16U; ++tap) {
        Xil_Out32(GF_BASE + GF_ACT_STAGE_ADDR, tap);
        Xil_Out32(GF_BASE + GF_ACT_STAGE_DATA, 0x01010101U);
    }
    Xil_Out32(GF_BASE + GF_CONTROL, 0x2U);
    Xil_Out32(GF_BASE + GF_CONTROL, 0x5U);
    status = 0U;
    for (poll = 0U; poll < 1000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if ((status & (1U << 3)) != 0U) { break; }
    }
    store_probe(25U, status);
    if ((status & (1U << 4)) != 0U || (status & (1U << 3)) == 0U) { fail(0x1020U, status); }
    cycles = Xil_In32(GF_BASE + GF_CYCLES);
    store_probe(26U, cycles);
    if (cycles == 0U || cycles >= 100U) { fail(0x1021U, cycles); }
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_RESULT_IDX, oc);
        value = Xil_In32(GF_BASE + GF_RESULT_DATA);
        if (value != 48U + oc) { fail(0x1200U + oc, value); }
    }

    /* Real model first-window check. The generated header contains weights,
     * bias, and activation bytes from the project-local 4x4 INT8 TFLite
     * model. Compare the raw INT32 accumulator before requantization. */
    stage = 0x70U;
    Xil_Out32(GF_BASE + GF_JOB_CFG, 0xFFFF070FU);
    Xil_Out32(GF_BASE + GF_OUT_STAGE_ADDR, 0U);
    for (oc = 0U; oc < GF_REAL_PROBE_OUTPUT_LANES; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc);
        Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_real_probe_bias[oc]);
        for (tap = 0U; tap < GF_REAL_PROBE_TAPS; ++tap) {
            u32 base = (oc * GF_REAL_PROBE_TAPS + tap) * 3U;
            u32 packed = (u32)(uint8_t)gf_real_probe_weights[base]
                       | ((u32)(uint8_t)gf_real_probe_weights[base + 1U] << 8)
                       | ((u32)(uint8_t)gf_real_probe_weights[base + 2U] << 16);
            Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4));
            Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
        Xil_Out32(GF_BASE + GF_RQIDX, oc);
        Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_real_probe_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)(-gf_real_probe_requant_shift[oc]));
    }
    /* Output scale is per channel in the model; the generated multipliers
     * already include input scale, weight scale and output scale. The shared
     * output zero point and fused ReLU match the first TFLite CONV_2D. */
    Xil_Out32(GF_BASE + GF_RQCTRL, 0x00008003U);
    for (tap = 0U; tap < GF_REAL_PROBE_TAPS; ++tap) {
        u32 packed = (u32)(uint8_t)gf_real_probe_activation[tap * 3U]
                   | ((u32)(uint8_t)gf_real_probe_activation[tap * 3U + 1U] << 8)
                   | ((u32)(uint8_t)gf_real_probe_activation[tap * 3U + 2U] << 16);
        Xil_Out32(GF_BASE + GF_ACT_STAGE_ADDR, tap);
        Xil_Out32(GF_BASE + GF_ACT_STAGE_DATA, packed);
    }
    Xil_Out32(GF_BASE + GF_CONTROL, 0x2U);
    Xil_Out32(GF_BASE + GF_CONTROL, 0x5U);
    status = 0U;
    for (poll = 0U; poll < 1000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if ((status & (1U << 3)) != 0U) { break; }
    }
    store_probe(27U, status);
    if ((status & (1U << 4)) != 0U || (status & (1U << 3)) == 0U) { fail(0x1030U, status); }
    cycles = Xil_In32(GF_BASE + GF_CYCLES);
    store_probe(28U, cycles);
    if (cycles == 0U || cycles >= 100U) { fail(0x1031U, cycles); }
    real_mismatch = 0U;
    for (oc = 0U; oc < GF_REAL_PROBE_OUTPUT_LANES; ++oc) {
        Xil_Out32(GF_BASE + GF_RESULT_IDX, oc);
        value = Xil_In32(GF_BASE + GF_RESULT_DATA);
        store_probe(8U + oc, value);
        if ((int32_t)value != gf_real_probe_expected_accum[oc]) { ++real_mismatch; }
    }
    if (real_mismatch != 0U) { fail(0x13FFU, real_mismatch); }

    /* Read the post-quantized vector through the debug selector and verify
     * every lane. Normal layer consumers will use the output BRAM/DMA path,
     * not these AXI-Lite reads; this is a board-level numerical probe. */
    for (oc = 0U; oc < GF_REAL_PROBE_OUTPUT_LANES; ++oc) {
        Xil_Out32(GF_BASE + GF_QUANT_RESULT_IDX, oc);
        value = Xil_In32(GF_BASE + GF_QUANT_RESULT_DATA);
        store_probe(32U + oc, value);
        if ((int8_t)value != gf_real_probe_expected_quantized[oc]) { fail(0x1400U + oc, value); }
    }
    /* The same 16-byte vector was written to one output-bank address. The
     * four reads below prove the BRAM path without treating AXI-Lite as the
     * future layer transport. */
    for (group = 0U; group < 4U; ++group) {
        u32 expected_word = 0U;
        for (oc = 0U; oc < 4U; ++oc) {
            expected_word |= (u32)(uint8_t)gf_real_probe_expected_quantized[group * 4U + oc] << (oc * 8U);
        }
        Xil_Out32(GF_BASE + GF_OUT_READ_CTRL, group << 8);
        value = Xil_In32(GF_BASE + GF_OUT_READ_DATA);
        store_probe(48U + group, value);
        if (value != expected_word) { fail(0x1500U + group, value); }
    }

    store_probe(0U, RESULT_PASS);
    xil_printf("GESTUREFLOW_REAL_CONV4X4_PASS full_cycles=%lu rgb_cycles=%lu real_cycles=%lu lane0=0x%08lx lane15=0x%08lx\r\n",
               (unsigned long)probe[7], (unsigned long)probe[26], (unsigned long)cycles,
               (unsigned long)probe[8], (unsigned long)probe[23]);
    while (1) { usleep(100000U); }
    return 0;
}
