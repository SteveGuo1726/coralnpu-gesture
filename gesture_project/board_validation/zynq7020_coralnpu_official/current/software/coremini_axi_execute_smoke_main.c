#include "sleep.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"

#define PROBE_RESULT_BASE      0xFFFF0000U
#define CORE_IMEM_BASE         0x43C00000U
#define CORE_DMEM_BASE         0x43C10000U
#define CORE_CSR_BASE          0x43C30000U
#define WRAPPER_LOCAL_BASE     0x43C40000U

#define RESULT_DONE            0x600D600DU
#define RESULT_DATA_ABORT      0xDA7AAB01U
#define RESULT_PREFETCH_ABORT  0xDA7AAB02U

static volatile u32 *const probe = (volatile u32 *)PROBE_RESULT_BASE;
static volatile u32 g_stage = 0U;

static const u32 kSmokeProgram[] = {
    0x123450B7U, /* lui    x1, 0x12345    -> x1 = 0x12345000 */
    0x00010137U, /* lui    x2, 0x10       -> x2 = 0x00010000 */
    0x00112023U, /* sw     x1, 0(x2)      -> dtcm[0] = 0x12345000 */
    0x08000073U, /* mpause                -> halt cleanly      */
};

static inline void probe_store(u32 index, u32 value)
{
    probe[index] = value;
    __asm__ volatile ("dsb sy" : : : "memory");
}

static inline void set_stage(u32 stage)
{
    g_stage = stage;
    probe_store(1U, stage);
}

static inline u32 read_dfsr(void)
{
    u32 value;
    __asm__ volatile ("mrc p15, 0, %0, c5, c0, 0" : "=r" (value));
    return value;
}

static inline u32 read_dfar(void)
{
    u32 value;
    __asm__ volatile ("mrc p15, 0, %0, c6, c0, 0" : "=r" (value));
    return value;
}

static inline u32 read_ifsr(void)
{
    u32 value;
    __asm__ volatile ("mrc p15, 0, %0, c5, c0, 1" : "=r" (value));
    return value;
}

static inline u32 read_ifar(void)
{
    u32 value;
    __asm__ volatile ("mrc p15, 0, %0, c6, c0, 2" : "=r" (value));
    return value;
}

static void data_abort_handler(void *data)
{
    (void)data;
    probe_store(0U, RESULT_DATA_ABORT);
    probe_store(2U, g_stage);
    probe_store(3U, read_dfsr());
    probe_store(4U, read_dfar());
    while (1) {
        usleep(100000U);
    }
}

static void prefetch_abort_handler(void *data)
{
    (void)data;
    probe_store(0U, RESULT_PREFETCH_ABORT);
    probe_store(2U, g_stage);
    probe_store(5U, read_ifsr());
    probe_store(6U, read_ifar());
    while (1) {
        usleep(100000U);
    }
}

static void init_probe_area(void)
{
    u32 i;
    for (i = 0U; i < 16U; ++i) {
        probe_store(i, 0U);
    }
}

int main(void)
{
    u32 i;
    u32 value;
    u32 status;
    u32 polls;

    Xil_DCacheDisable();
    Xil_ICacheDisable();

    init_probe_area();

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort_handler, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort_handler, 0);
    Xil_ExceptionEnable();

    Xil_SetTlbAttributes(CORE_IMEM_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(CORE_DMEM_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(CORE_CSR_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(WRAPPER_LOCAL_BASE, DEVICE_MEMORY);
    set_stage(0x08U);

    set_stage(0x10U);
    probe_store(8U, Xil_In32(WRAPPER_LOCAL_BASE + 0x0U));
    probe_store(9U, Xil_In32(WRAPPER_LOCAL_BASE + 0x8U));
    probe_store(10U, Xil_In32(CORE_CSR_BASE + 0x0U));

    set_stage(0x20U);
    Xil_Out32(CORE_CSR_BASE + 0x0U, 0x00000003U);
    probe_store(12U, Xil_In32(CORE_CSR_BASE + 0x8U));

    set_stage(0x21U);
    Xil_Out32(CORE_DMEM_BASE + 0x0U, 0x00000000U);
    for (i = 0U; i < (sizeof(kSmokeProgram) / sizeof(kSmokeProgram[0])); ++i) {
        Xil_Out32(CORE_IMEM_BASE + (i * 4U), kSmokeProgram[i]);
    }

    set_stage(0x22U);
    probe_store(11U, Xil_In32(CORE_IMEM_BASE + 0x0U));

    set_stage(0x23U);
    Xil_Out32(CORE_CSR_BASE + 0x4U, 0x00000000U);
    Xil_Out32(CORE_CSR_BASE + 0x0U, 0x00000001U);
    Xil_Out32(CORE_CSR_BASE + 0x0U, 0x00000000U);

    set_stage(0x24U);
    status = 0U;
    polls = 0U;
    while (polls < 1000000U) {
        status = Xil_In32(CORE_CSR_BASE + 0x8U);
        if ((status & 0x3U) != 0U) {
            break;
        }
        ++polls;
    }
    probe_store(13U, status);
    probe_store(14U, polls);

    set_stage(0x25U);
    value = Xil_In32(CORE_DMEM_BASE + 0x0U);
    probe_store(15U, value);

    set_stage(0x30U);
    probe_store(7U, Xil_In32(WRAPPER_LOCAL_BASE + 0x4U));
    probe_store(0U, RESULT_DONE);

    while (1) {
        usleep(100000U);
    }

    return 0;
}
