/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
#include "sleep.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"

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
    u32 oc, tap, group, poll, value, status, cycles;
    const u32 expected_base = 1024U;

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (oc = 0U; oc < 32U; ++oc) { store_probe(oc, 0U); }
    store_probe(0U, 0x47464E50U);

    stage = 0x10U;
    value = Xil_In32(GF_BASE + GF_MAGIC);
    store_probe(4U, value);
    if (value != 0x47464E50U) { fail(0x1001U, value); }
    value = Xil_In32(GF_BASE + GF_VERSION);
    store_probe(5U, value);
    if (value != 0x00010000U) { fail(0x1002U, value); }

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
    Xil_Out32(GF_BASE + GF_CONTROL, 0x2U);
    Xil_Out32(GF_BASE + GF_CONTROL, 0x1U);
    for (tap = 0U; tap < 16U; ++tap) {
        for (group = 0U; group < 16U; ++group) {
            u32 last = (tap == 15U && group == 15U) ? (1U << 8) : 0U;
            Xil_Out32(GF_BASE + GF_ACTRL, tap | (group << 4) | last);
            Xil_Out32(GF_BASE + GF_ADATA, 0x01010101U);
        }
    }

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

    store_probe(0U, RESULT_PASS);
    xil_printf("GESTUREFLOW_AXIL_BASELINE_PASS cycles=%lu lane0=%lu lane15=%lu\r\n",
               (unsigned long)cycles, (unsigned long)probe[8], (unsigned long)probe[23]);
    while (1) { usleep(100000U); }
    return 0;
}
