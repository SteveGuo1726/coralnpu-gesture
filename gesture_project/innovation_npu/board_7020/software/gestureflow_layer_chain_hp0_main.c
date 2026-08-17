/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/*
 * Real two-layer 7020 baseline. The PL writes tensor 18 into DDR after the
 * first layer and reads that exact buffer for the second layer. The ARM only
 * changes descriptors and resident weights between layers; it does not copy
 * the intermediate activation.
 */
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
#include "gestureflow_chain_body_data.h"
#include "gestureflow_real_maxpool2d.h"

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
#define GF_LAYER_MODE 0x064U
#define GF_RESULT_PASS 0x600D600DU
#define GF_RESULT_FAIL 0xBAD0BAD0U
#define GF_RESULT_DATA_ABORT 0xDA7AAB01U
#define GF_RESULT_PREFETCH_ABORT 0xDA7AAB02U
#define GF_DONE_BIT (1U << 1)
#define GF_FAULT_BIT (1U << 2)
#define GF_LAYER_FAULT_BIT (1U << 6)
#define GF_DMA_FAULT_BIT (1U << 2)
#define GF_DMA_DONE_BIT (1U << 1)
#define GF_STORE_FAULT_BIT (1U << 2)
#define GF_STORE_DONE_BIT (1U << 1)
#define GF_DMA_BYTES_READ(value) ((value) >> 3)
#define GF_STORE_BYTES_WRITTEN(value) ((value) >> 3)
#define GF_RGB_BYTES (96U * 96U * 3U)
#define GF_ACTIVATION_BYTES (96U * 96U * 16U)

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static volatile u32 stage;
static uint8_t gf_rgb[GF_RGB_BYTES] __attribute__((aligned(64)));
static int8_t gf_activation_1[GF_ACTIVATION_BYTES] __attribute__((aligned(64)));
static int8_t gf_activation_2[GF_ACTIVATION_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool_1[GF_POOL_OUTPUT_BYTES] __attribute__((aligned(64)));

static void store_probe(u32 index, u32 value)
{
    probe[index] = value;
    __asm__ volatile ("dsb sy" : : : "memory");
}

static uint32_t fnv1a_bytes(const int8_t *data, uint32_t count)
{
    uint32_t value = 0x811C9DC5U;
    uint32_t index;
    for (index = 0U; index < count; ++index)
        value = (value ^ (uint8_t)data[index]) * 0x01000193U;
    return value;
}

static void terminal_failure(u32 code, u32 observed)
{
    store_probe(2U, code); store_probe(3U, observed); store_probe(0U, GF_RESULT_FAIL);
    xil_printf("GESTUREFLOW_LAYER_CHAIN_HP0_FAIL code=%08lx observed=%08lx\r\n",
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
    for (poll = 0U; poll < 12000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if (status & (GF_FAULT_BIT | GF_LAYER_FAULT_BIT)) terminal_failure(0x4001U, status);
        if (status & GF_DONE_BIT) return;
    }
    terminal_failure(0x4002U, status);
}

static void load_first_layer(void)
{
    u32 oc, tap, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 0U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_full_folded_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_full_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_full_requant_right_shift[oc]);
        for (tap = 0U; tap < 16U; ++tap) {
            wi = oc * 48U + tap * 3U;
            packed = (uint32_t)(uint8_t)gf_full_weights[wi] |
                     ((uint32_t)(uint8_t)gf_full_weights[wi + 1U] << 8) |
                     ((uint32_t)(uint8_t)gf_full_weights[wi + 2U] << 16);
            Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4U)); Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

static void load_body_layer(void)
{
    u32 oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 1U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_chain_body_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_chain_body_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_chain_body_right_shift[oc]);
        for (tap = 0U; tap < 16U; ++tap) for (group = 0U; group < 4U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                wi = oc * 256U + tap * 16U + group * 4U + lane;
                packed |= (uint32_t)(uint8_t)gf_chain_body_weights[wi] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4U) | (group << 8U));
            Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

static u32 run_layer(uint32_t mode, uint32_t source, uint32_t bytes, uint32_t destination,
                     uint32_t store_bytes, uint32_t store_control)
{
    Xil_Out32(GF_BASE + GF_LAYER_MODE, mode);
    Xil_Out32(GF_BASE + GF_DMA_SOURCE, source);
    Xil_Out32(GF_BASE + GF_DMA_BYTES, bytes);
    Xil_Out32(GF_BASE + GF_DMA_PIXELS, 9216U);
    Xil_Out32(GF_BASE + GF_STORE_DESTINATION, destination);
    Xil_Out32(GF_BASE + GF_STORE_BYTES, store_bytes);
    Xil_Out32(GF_BASE + GF_STORE_CONTROL, store_control);
    Xil_Out32(GF_BASE + GF_CONTROL, 2U);
    wait_layer_done();
    return Xil_In32(GF_BASE + GF_CYCLES);
}

int main(void)
{
    u32 index, status, dma_status, store_status, hash, ddr_hash, cycles0, cycles1, pool_cycles, pool_hash;
    XTime t0, t1;
    Xil_DCacheDisable(); Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY); Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_rgb, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_activation_1, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_activation_2, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_pool_1, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (index = 0U; index < 32U; ++index) store_probe(index, 0U);
    store_probe(0U, 0x47464E50U);
    stage = 0x10U;
    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) terminal_failure(0x4101U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00040001U) terminal_failure(0x4102U, Xil_In32(GF_BASE + GF_VERSION));
    for (index = 0U; index < GF_RGB_BYTES; ++index) gf_rgb[index] = gf_full_camera_rgb[index];
    Xil_DCacheFlushRange((UINTPTR)gf_rgb, GF_RGB_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_activation_2, GF_ACTIVATION_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool_1, GF_POOL_OUTPUT_BYTES);

    stage = 0x20U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_first_layer();
    XTime_GetTime(&t0); cycles0 = run_layer(0U, (u32)(UINTPTR)gf_rgb, GF_RGB_BYTES, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, 1U); XTime_GetTime(&t1);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    ddr_hash = fnv1a_bytes(gf_activation_1, GF_ACTIVATION_BYTES);
    store_probe(4U,status); store_probe(5U,cycles0); store_probe(6U,Xil_In32(GF_BASE+GF_INPUT_PIXELS)); store_probe(7U,Xil_In32(GF_BASE+GF_OUTPUT_VECTORS)); store_probe(8U,hash); store_probe(9U,dma_status); store_probe(10U,store_status); store_probe(11U,ddr_hash);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_RGB_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_ACTIVATION_BYTES || hash != GF_FULL_OUTPUT_FNV1A || ddr_hash != GF_FULL_OUTPUT_FNV1A) terminal_failure(0x4103U, ddr_hash);

    stage = 0x30U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_body_layer();
    cycles1 = run_layer(1U, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, (u32)(UINTPTR)gf_activation_2, GF_ACTIVATION_BYTES, 1U);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    ddr_hash = fnv1a_bytes(gf_activation_2, GF_ACTIVATION_BYTES);
    store_probe(12U,cycles1); store_probe(13U,hash); store_probe(14U,dma_status); store_probe(15U,store_status); store_probe(16U,ddr_hash); store_probe(17U,(u32)t0); store_probe(18U,(u32)t1);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_ACTIVATION_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_ACTIVATION_BYTES || hash != gf_chain_body_output_fnv1a || ddr_hash != gf_chain_body_output_fnv1a) terminal_failure(0x4104U, ddr_hash);
    stage = 0x40U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_body_layer();
    pool_cycles = run_layer(1U, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, (u32)(UINTPTR)gf_pool_1, GF_POOL_OUTPUT_BYTES, 3U);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    pool_hash = fnv1a_bytes(gf_pool_1, GF_POOL_OUTPUT_BYTES);
    store_probe(19U,pool_cycles); store_probe(20U,hash); store_probe(21U,store_status); store_probe(22U,pool_hash);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_ACTIVATION_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL_OUTPUT_BYTES || hash != gf_chain_body_output_fnv1a || pool_hash != GF_POOL_OUTPUT_FNV1A) terminal_failure(0x4105U, pool_hash);
    store_probe(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_LAYER_CHAIN_HP0_POOL_BOARD_PASS c0=%lu c1=%lu pool=%lu hash0=%08lx hash1=%08lx ddr1=%08lx ddr2=%08lx poolddr=%08lx\r\n",
      (unsigned long)cycles0,(unsigned long)cycles1,(unsigned long)pool_cycles,(unsigned long)GF_FULL_OUTPUT_FNV1A,(unsigned long)hash,
      (unsigned long)GF_FULL_OUTPUT_FNV1A,(unsigned long)ddr_hash,(unsigned long)pool_hash);
    while (1) { usleep(100000U); }
}
