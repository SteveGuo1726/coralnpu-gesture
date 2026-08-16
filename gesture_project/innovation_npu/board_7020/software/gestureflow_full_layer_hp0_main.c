/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/* One real exported 96x96 RGB TFLite layer through PS DDR and PL HP0. */
#include <stdint.h>
#include "sleep.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xtime_l.h"
#include "gestureflow_real_conv4x4_full_layer.h"

#define GF_BASE 0x43C00000U
#define PROBE_BASE 0xFFFF0000U
#define GF_MAGIC 0x000U
#define GF_VERSION 0x004U
#define GF_CONTROL 0x008U
#define GF_STATUS 0x00CU
#define GF_QCFG 0x010U
#define GF_WCTRL 0x014U
#define GF_WDATA 0x018U
#define GF_BIDX 0x01CU
#define GF_BDATA 0x020U
#define GF_RQIDX 0x024U
#define GF_RQMULT 0x028U
#define GF_RQSHIFT 0x02CU
#define GF_CYCLES 0x034U
#define GF_INPUT_PIXELS 0x038U
#define GF_OUTPUT_VECTORS 0x03CU
#define GF_OUTPUT_FNV1A 0x040U
#define GF_DMA_SOURCE 0x044U
#define GF_DMA_BYTES 0x048U
#define GF_DMA_PIXELS 0x04CU
#define GF_DMA_STATUS 0x050U
#define GF_STORE_DESTINATION 0x054U
#define GF_STORE_BYTES 0x058U
#define GF_STORE_CONTROL 0x05CU
#define GF_STORE_STATUS 0x060U

#define GF_RESULT_PASS 0x600D600DU
#define GF_RESULT_FAIL 0xBAD0BAD0U
#define GF_RESULT_DATA_ABORT 0xDA7AAB01U
#define GF_RESULT_PREFETCH_ABORT 0xDA7AAB02U
#define GF_DONE_BIT (1U << 1)
#define GF_FAULT_BIT (1U << 2)
#define GF_LAYER_FAULT_BIT (1U << 6)
#define GF_DMA_FAULT_BIT (1U << 2)
#define GF_DMA_DONE_BIT (1U << 1)
#define GF_DMA_BYTES_READ(value) (((value) >> 3) & 0xFFFFU)
#define GF_STORE_DONE_BIT (1U << 1)
#define GF_STORE_FAULT_BIT (1U << 2)
#define GF_STORE_BYTES_WRITTEN(value) ((value) >> 3)

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static volatile u32 stage;
/* HP0 source must be physically visible and 8-byte aligned. */
static uint8_t gf_hp0_rgb[GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_INPUT_CHANNELS]
  __attribute__((aligned(64)));
/* This is the exact signed INT8 NHWC tensor consumed by body-2 HP0. */
static int8_t gf_hp0_activation[GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_OUTPUT_LANES]
  __attribute__((aligned(64)));

static u32 fnv1a_activation_hash(const int8_t *data, u32 bytes)
{
    u32 hash = 0x811C9DC5U;
    u32 i;
    for (i = 0U; i < bytes; ++i) {
        hash ^= (u8)data[i];
        hash *= 0x01000193U;
    }
    return hash;
}

static void store_probe(u32 index, u32 value)
{
    probe[index] = value;
    __asm__ volatile ("dsb sy" : : : "memory");
}

static void terminal_failure(u32 code, u32 observed)
{
    store_probe(2U, code); store_probe(3U, observed); store_probe(0U, GF_RESULT_FAIL);
    xil_printf("GESTUREFLOW_FULL_LAYER_HP0_FAIL code=%08lx observed=%08lx\r\n",
               (unsigned long)code, (unsigned long)observed);
    while (1) { usleep(100000U); }
}

static void data_abort(void *unused)
{
    (void)unused; store_probe(0U, GF_RESULT_DATA_ABORT); store_probe(1U, stage);
    while (1) { usleep(100000U); }
}

static void prefetch_abort(void *unused)
{
    (void)unused; store_probe(0U, GF_RESULT_PREFETCH_ABORT); store_probe(1U, stage);
    while (1) { usleep(100000U); }
}

static void wait_layer_done(void)
{
    u32 poll, status = 0U;
    for (poll = 0U; poll < 4000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if (status & (GF_FAULT_BIT | GF_LAYER_FAULT_BIT)) terminal_failure(0x2201U, status);
        if (status & GF_DONE_BIT) return;
    }
    terminal_failure(0x2202U, status);
}

int main(void)
{
    u32 oc, tap, index, status, dma_status, store_status, activation_hash, cycles, input_count, output_count, hash;
    XTime t0, t1;
    const u32 image_bytes = GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_INPUT_CHANNELS;

    Xil_DCacheDisable(); Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (index = 0U; index < 32U; ++index) store_probe(index, 0U);
    store_probe(0U, 0x47464E50U);

    stage = 0x10U;
    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) terminal_failure(0x2001U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00030000U) terminal_failure(0x2002U, Xil_In32(GF_BASE + GF_VERSION));
    if ((((u32)(UINTPTR)gf_hp0_rgb) & 7U) != 0U) terminal_failure(0x2003U, (u32)(UINTPTR)gf_hp0_rgb);
    if ((((u32)(UINTPTR)gf_hp0_activation) & 15U) != 0U) terminal_failure(0x2005U, (u32)(UINTPTR)gf_hp0_activation);

    stage = 0x20U;
    for (index = 0U; index < image_bytes; ++index) gf_hp0_rgb[index] = gf_full_camera_rgb[index];
    /* DCache is disabled today; retain this operation for the cached runtime. */
    Xil_DCacheFlushRange((UINTPTR)gf_hp0_rgb, image_bytes);

    Xil_Out32(GF_BASE + GF_CONTROL, 0x1U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    for (oc = 0U; oc < GF_FULL_OUTPUT_LANES; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_full_folded_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_full_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_full_requant_right_shift[oc]);
        for (tap = 0U; tap < 16U; ++tap) {
            u32 wi = (oc * 16U + tap) * GF_FULL_INPUT_CHANNELS;
            u32 packed = (u32)(uint8_t)gf_full_weights[wi] |
              ((u32)(uint8_t)gf_full_weights[wi + 1U] << 8) |
              ((u32)(uint8_t)gf_full_weights[wi + 2U] << 16);
            Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4)); Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }

    stage = 0x30U;
    Xil_Out32(GF_BASE + GF_DMA_SOURCE, (u32)(UINTPTR)gf_hp0_rgb);
    Xil_Out32(GF_BASE + GF_DMA_BYTES, image_bytes);
    Xil_Out32(GF_BASE + GF_DMA_PIXELS, GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT);
    Xil_Out32(GF_BASE + GF_STORE_DESTINATION, (u32)(UINTPTR)gf_hp0_activation);
    Xil_Out32(GF_BASE + GF_STORE_BYTES, GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_OUTPUT_LANES);
    Xil_Out32(GF_BASE + GF_STORE_CONTROL, 1U);
    XTime_GetTime(&t0); Xil_Out32(GF_BASE + GF_CONTROL, 0x2U); wait_layer_done(); XTime_GetTime(&t1);

    status = Xil_In32(GF_BASE + GF_STATUS); cycles = Xil_In32(GF_BASE + GF_CYCLES);
    input_count = Xil_In32(GF_BASE + GF_INPUT_PIXELS); output_count = Xil_In32(GF_BASE + GF_OUTPUT_VECTORS);
    hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    stage = 0x40U;
    activation_hash = fnv1a_activation_hash(gf_hp0_activation, GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_OUTPUT_LANES);
    store_probe(4U, status); store_probe(5U, cycles); store_probe(6U, input_count); store_probe(7U, output_count);
    store_probe(8U, hash); store_probe(9U, dma_status); store_probe(10U, (u32)(UINTPTR)gf_hp0_rgb);
    store_probe(11U, (u32)t0); store_probe(12U, (u32)(t0 >> 32)); store_probe(13U, (u32)t1); store_probe(14U, (u32)(t1 >> 32));
    store_probe(15U, store_status); store_probe(16U, (u32)(UINTPTR)gf_hp0_activation);
    store_probe(17U, activation_hash);
    if ((status & (GF_FAULT_BIT | GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) ||
        !(dma_status & GF_DMA_DONE_BIT) || GF_DMA_BYTES_READ(dma_status) != image_bytes ||
        (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT * GF_FULL_OUTPUT_LANES ||
        input_count != GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT || output_count != GF_FULL_IMAGE_WIDTH * GF_FULL_IMAGE_HEIGHT ||
        hash != GF_FULL_OUTPUT_FNV1A || activation_hash != GF_FULL_OUTPUT_FNV1A || cycles == 0U) terminal_failure(0x2004U, activation_hash);
    store_probe(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_FULL_LAYER_HP0_STORE_BOARD_PASS cycles=%lu hash=%08lx ddr_hash=%08lx rd=%08lx wr=%08lx\r\n",
               (unsigned long)cycles, (unsigned long)hash, (unsigned long)activation_hash,
               (unsigned long)dma_status, (unsigned long)store_status);
    while (1) { usleep(100000U); }
}
