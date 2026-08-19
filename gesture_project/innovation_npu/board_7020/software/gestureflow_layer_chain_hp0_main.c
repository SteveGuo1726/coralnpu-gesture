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
#include "gestureflow_real_conv4x4_conv2a_layer.h"
#include "gestureflow_real_conv4x4_conv2b_layer.h"
#include "gestureflow_real_maxpool2d_pool2.h"
#include "gestureflow_real_conv4x4_conv3a_layer.h"
#include "gestureflow_real_conv4x4_conv3b_layer.h"
#include "gestureflow_real_maxpool2d_pool3.h"

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
#define GF_JOB_WIDTH 0x068U
#define GF_JOB_HEIGHT 0x06CU
#define GF_OUTPUT_LANE_MASK 0x070U
#define GF_STORE_STRIDE 0x074U
#define GF_STORE_VALID_BYTES 0x078U
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
#define GF_POOL1_BYTES GF_POOL_OUTPUT_BYTES
#define GF_CONV2A_BYTES (48U * 48U * 40U)
#define GF_CONV2A_TILE_BYTES (48U * 48U * 16U)
#define GF_CONV2B_BYTES (48U * 48U * 40U)
#define GF_CONV2B_TILE_BYTES (48U * 48U * 16U)
#define GF_POOL2_BYTES GF_POOL2_OUTPUT_BYTES
#define GF_POOL2_TILE_BYTES (24U * 24U * 16U)
#define GF_CONV3A_BYTES (24U * 24U * 80U)
#define GF_CONV3A_TILE_BYTES (24U * 24U * 16U)
#define GF_CONV3B_BYTES (24U * 24U * 80U)
#define GF_CONV3B_TILE_BYTES (24U * 24U * 16U)
#define GF_POOL3_BYTES GF_POOL3_OUTPUT_BYTES
#define GF_POOL3_TILE_BYTES (12U * 12U * 16U)

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static volatile u32 stage;
static uint8_t gf_rgb[GF_RGB_BYTES] __attribute__((aligned(64)));
static int8_t gf_activation_1[GF_ACTIVATION_BYTES] __attribute__((aligned(64)));
static int8_t gf_activation_2[GF_ACTIVATION_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool_1[GF_POOL_OUTPUT_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv2a[GF_CONV2A_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv2b[GF_CONV2B_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool2[GF_POOL2_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv3a[GF_CONV3A_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv3b[GF_CONV3B_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool3[GF_POOL3_BYTES] __attribute__((aligned(64)));

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

static int bytes_equal(const int8_t *left, const int8_t *right, uint32_t count)
{
    uint32_t index;
    for (index = 0U; index < count; ++index)
        if (left[index] != right[index]) return 0;
    return 1;
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

static void load_conv2a_tile(uint32_t first_oc, uint32_t lane_mask)
{
    u32 physical_oc, model_oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 1U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, lane_mask);
    for (physical_oc = 0U; physical_oc < 16U; ++physical_oc) {
      model_oc = first_oc + physical_oc;
        if (model_oc >= GF_CONV2A_OUTPUT_LANES) {
            Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, 0U);
            Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, 0U); Xil_Out32(GF_BASE + GF_RQSHIFT, 0U);
            continue;
        }
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_conv2a_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_conv2a_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_conv2a_requant_right_shift[model_oc]);
        for (tap = 0U; tap < 16U; ++tap) for (group = 0U; group < 4U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                wi = model_oc * 256U + tap * 16U + group * 4U + lane;
                packed |= (uint32_t)(uint8_t)gf_conv2a_weights[wi] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, physical_oc | (tap << 4U) | (group << 8U));
            Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

/* The 40-channel body path is mode 2: 10 resident four-lane input groups.
 * Each output tile remains in the same 16-output DSP array and all INT32
 * channel partial sums stay local until the tenth group completes. */
static void load_conv2b_tile(uint32_t first_oc, uint32_t lane_mask)
{
    u32 physical_oc, model_oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 2U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, lane_mask);
    for (physical_oc = 0U; physical_oc < 16U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        if (model_oc >= GF_CONV2B_OUTPUT_LANES) {
            Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, 0U);
            Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, 0U); Xil_Out32(GF_BASE + GF_RQSHIFT, 0U);
            continue;
        }
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_conv2b_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_conv2b_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_conv2b_requant_right_shift[model_oc]);
        for (tap = 0U; tap < 16U; ++tap) for (group = 0U; group < 10U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                wi = model_oc * 640U + tap * 40U + group * 4U + lane;
                packed |= (uint32_t)(uint8_t)gf_conv2b_weights[wi] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, physical_oc | (tap << 4U) | (group << 8U)); Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

/* conv3_a keeps the proven 40-channel, ten-group input dataflow. The 80
 * model channels are serialized as five 16-output tiles; no second array or
 * off-chip INT32 partial-sum merge is introduced. */
static void load_conv3a_tile(uint32_t first_oc)
{
    u32 physical_oc, model_oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 2U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffU);
    for (physical_oc = 0U; physical_oc < 16U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_conv3a_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_conv3a_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_conv3a_requant_right_shift[model_oc]);
        for (tap = 0U; tap < 16U; ++tap) for (group = 0U; group < 10U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                wi = model_oc * 640U + tap * 40U + group * 4U + lane;
                packed |= (uint32_t)(uint8_t)gf_conv3a_weights[wi] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, physical_oc | (tap << 4U) | (group << 8U)); Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

/* conv3_b is the first 80-input-channel layer. Mode 3 feeds an 80-byte NHWC
 * vector into the widened rolling window, while this same physical 16x4 DSP
 * tile walks all 20 Cin groups and keeps its INT32 accumulator local. */
static void load_conv3b_tile(uint32_t first_oc)
{
    u32 physical_oc, model_oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 3U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffU);
    for (physical_oc = 0U; physical_oc < 16U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_conv3b_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_conv3b_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_conv3b_requant_right_shift[model_oc]);
        for (tap = 0U; tap < 16U; ++tap) for (group = 0U; group < 20U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                wi = model_oc * 1280U + tap * 80U + group * 4U + lane;
                packed |= (uint32_t)(uint8_t)gf_conv3b_weights[wi] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, physical_oc | (tap << 4U) | (group << 8U)); Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

static u32 run_layer(uint32_t mode, uint32_t source, uint32_t bytes, uint32_t destination,
                     uint32_t store_bytes, uint32_t store_control, uint32_t width,
                     uint32_t height, uint32_t stride_bytes, uint32_t valid_bytes)
{
    Xil_Out32(GF_BASE + GF_LAYER_MODE, mode);
    Xil_Out32(GF_BASE + GF_DMA_SOURCE, source);
    Xil_Out32(GF_BASE + GF_DMA_BYTES, bytes);
    Xil_Out32(GF_BASE + GF_DMA_PIXELS, width * height);
    Xil_Out32(GF_BASE + GF_JOB_WIDTH, width);
    Xil_Out32(GF_BASE + GF_JOB_HEIGHT, height);
    Xil_Out32(GF_BASE + GF_STORE_DESTINATION, destination);
    Xil_Out32(GF_BASE + GF_STORE_BYTES, store_bytes);
    Xil_Out32(GF_BASE + GF_STORE_STRIDE, stride_bytes);
    Xil_Out32(GF_BASE + GF_STORE_VALID_BYTES, valid_bytes);
    Xil_Out32(GF_BASE + GF_STORE_CONTROL, store_control);
    Xil_Out32(GF_BASE + GF_CONTROL, 2U);
    wait_layer_done();
    return Xil_In32(GF_BASE + GF_CYCLES);
}

int main(void)
{
    u32 index, status, dma_status, store_status, hash, ddr_hash, cycles0, cycles1, pool_cycles, pool_hash;
    u32 conv2_cycles[3], conv2_hash[3], conv2_ddr_hash;
    u32 conv2b_cycles[3], conv2b_hash[3], conv2b_ddr_hash;
    u32 pool2_cycles[3], pool2_hash[3], pool2_ddr_hash;
    u32 conv3a_cycles[5], conv3a_hash[5], conv3a_ddr_hash;
    u32 conv3b_cycles[5], conv3b_hash[5], conv3b_ddr_hash;
    u32 pool3_cycles[5], pool3_hash[5], pool3_ddr_hash;
    XTime t0, t1;
    Xil_DCacheDisable(); Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY); Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_rgb, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_activation_1, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_activation_2, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_pool_1, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_conv2a, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_conv2b, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_pool2, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_conv3a, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_conv3b, DEVICE_MEMORY); Xil_SetTlbAttributes((UINTPTR)gf_pool3, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (index = 0U; index < 112U; ++index) store_probe(index, 0U);
    store_probe(0U, 0x47464E50U);
    stage = 0x10U;
    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) terminal_failure(0x4101U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00040003U) terminal_failure(0x4102U, Xil_In32(GF_BASE + GF_VERSION));
    for (index = 0U; index < GF_RGB_BYTES; ++index) gf_rgb[index] = gf_full_camera_rgb[index];
    Xil_DCacheFlushRange((UINTPTR)gf_rgb, GF_RGB_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_activation_2, GF_ACTIVATION_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool_1, GF_POOL_OUTPUT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv2a, GF_CONV2A_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv2b, GF_CONV2B_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool2, GF_POOL2_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv3a, GF_CONV3A_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv3b, GF_CONV3B_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool3, GF_POOL3_BYTES);

    stage = 0x20U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_first_layer();
    XTime_GetTime(&t0); cycles0 = run_layer(0U, (u32)(UINTPTR)gf_rgb, GF_RGB_BYTES, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, 1U, 96U, 96U, 16U, 16U); XTime_GetTime(&t1);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    ddr_hash = fnv1a_bytes(gf_activation_1, GF_ACTIVATION_BYTES);
    store_probe(4U,status); store_probe(5U,cycles0); store_probe(6U,Xil_In32(GF_BASE+GF_INPUT_PIXELS)); store_probe(7U,Xil_In32(GF_BASE+GF_OUTPUT_VECTORS)); store_probe(8U,hash); store_probe(9U,dma_status); store_probe(10U,store_status); store_probe(11U,ddr_hash);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_RGB_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_ACTIVATION_BYTES || hash != GF_FULL_OUTPUT_FNV1A || ddr_hash != GF_FULL_OUTPUT_FNV1A) terminal_failure(0x4103U, ddr_hash);

    stage = 0x30U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_body_layer();
    cycles1 = run_layer(1U, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, (u32)(UINTPTR)gf_activation_2, GF_ACTIVATION_BYTES, 1U, 96U, 96U, 16U, 16U);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    ddr_hash = fnv1a_bytes(gf_activation_2, GF_ACTIVATION_BYTES);
    store_probe(12U,cycles1); store_probe(13U,hash); store_probe(14U,dma_status); store_probe(15U,store_status); store_probe(16U,ddr_hash); store_probe(17U,(u32)t0); store_probe(18U,(u32)t1);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_ACTIVATION_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_ACTIVATION_BYTES || hash != gf_chain_body_output_fnv1a || ddr_hash != gf_chain_body_output_fnv1a) terminal_failure(0x4104U, ddr_hash);
    stage = 0x40U; Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_body_layer();
    pool_cycles = run_layer(1U, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, (u32)(UINTPTR)gf_pool_1, GF_POOL_OUTPUT_BYTES, 3U, 96U, 96U, 16U, 16U);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS); hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    pool_hash = fnv1a_bytes(gf_pool_1, GF_POOL_OUTPUT_BYTES);
    store_probe(19U,pool_cycles); store_probe(20U,hash); store_probe(21U,store_status); store_probe(22U,pool_hash);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_ACTIVATION_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL_OUTPUT_BYTES || hash != gf_chain_body_output_fnv1a || pool_hash != GF_POOL_OUTPUT_FNV1A) terminal_failure(0x4105U, pool_hash);
    if (fnv1a_bytes(gf_pool_1, GF_POOL1_BYTES) != fnv1a_bytes(gf_conv2a_layer_input, GF_POOL1_BYTES)) terminal_failure(0x4106U, fnv1a_bytes(gf_pool_1, GF_POOL1_BYTES));
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = index * 16U;
        u32 mask = index == 2U ? 0x00ffU : 0xffffU;
        u32 destination = (u32)(UINTPTR)gf_conv2a + first_oc;
        stage = 0x50U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv2a_tile(first_oc, mask);
        conv2_cycles[index] = run_layer(1U, (u32)(UINTPTR)gf_pool_1, GF_POOL1_BYTES, destination,
                                         index == 2U ? 48U * 48U * 8U : GF_CONV2A_TILE_BYTES,
                                         1U, 48U, 48U, 40U, index == 2U ? 8U : 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        conv2_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); conv2_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_POOL1_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != (index == 2U ? 48U * 48U * 8U : GF_CONV2A_TILE_BYTES)) terminal_failure(0x4107U + index, store_status);
        store_probe(23U + index * 3U, conv2_cycles[index]); store_probe(24U + index * 3U, conv2_hash[index]); store_probe(25U + index * 3U, store_status);
    }
    conv2_ddr_hash = fnv1a_bytes(gf_conv2a, GF_CONV2A_BYTES);
    store_probe(32U, conv2_ddr_hash);
    if (conv2_ddr_hash != GF_CONV2A_OUTPUT_FNV1A) terminal_failure(0x410aU, conv2_ddr_hash);
    if (fnv1a_bytes(gf_conv2a, GF_CONV2A_BYTES) != fnv1a_bytes(gf_conv2b_layer_input, GF_CONV2A_BYTES))
        terminal_failure(0x410bU, fnv1a_bytes(gf_conv2a, GF_CONV2A_BYTES));
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = index * 16U;
        u32 mask = index == 2U ? 0x00ffU : 0xffffU;
        u32 destination = (u32)(UINTPTR)gf_conv2b + first_oc;
        stage = 0x60U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv2b_tile(first_oc, mask);
        conv2b_cycles[index] = run_layer(2U, (u32)(UINTPTR)gf_conv2a, GF_CONV2A_BYTES, destination,
                                          index == 2U ? 48U * 48U * 8U : GF_CONV2B_TILE_BYTES,
                                          1U, 48U, 48U, 40U, index == 2U ? 8U : 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        conv2b_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); conv2b_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_CONV2A_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != (index == 2U ? 48U * 48U * 8U : GF_CONV2B_TILE_BYTES)) terminal_failure(0x410cU + index, store_status);
        store_probe(33U + index * 3U, conv2b_cycles[index]); store_probe(34U + index * 3U, conv2b_hash[index]); store_probe(35U + index * 3U, store_status);
    }
    conv2b_ddr_hash = fnv1a_bytes(gf_conv2b, GF_CONV2B_BYTES);
    store_probe(42U, conv2b_ddr_hash);
    if (conv2b_ddr_hash != GF_CONV2B_OUTPUT_FNV1A) terminal_failure(0x410fU, conv2b_ddr_hash);
    if (!bytes_equal(gf_conv2b, gf_pool2_input, GF_POOL2_INPUT_BYTES)) terminal_failure(0x4110U, conv2b_ddr_hash);
    /* Re-run the proven conv2_b tiles with pool fused into the writer. This
     * is the deployed path: no conv2_b activation is read back from DDR for
     * pool2. The preceding full DDR comparison proves its pool input. */
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = index * 16U;
        u32 mask = index == 2U ? 0x00ffU : 0xffffU;
        u32 destination = (u32)(UINTPTR)gf_pool2 + first_oc;
        stage = 0x70U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv2b_tile(first_oc, mask);
        pool2_cycles[index] = run_layer(2U, (u32)(UINTPTR)gf_conv2a, GF_CONV2A_BYTES, destination,
                                         index == 2U ? 24U * 24U * 8U : GF_POOL2_TILE_BYTES,
                                         3U, 48U, 48U, 40U, index == 2U ? 8U : 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        pool2_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); pool2_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_CONV2A_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != (index == 2U ? 24U * 24U * 8U : GF_POOL2_TILE_BYTES)) terminal_failure(0x4111U + index, store_status);
        store_probe(43U + index * 3U, pool2_cycles[index]); store_probe(44U + index * 3U, pool2_hash[index]); store_probe(45U + index * 3U, store_status);
    }
    pool2_ddr_hash = fnv1a_bytes(gf_pool2, GF_POOL2_BYTES);
    store_probe(52U, pool2_ddr_hash);
    if (pool2_ddr_hash != GF_POOL2_OUTPUT_FNV1A) terminal_failure(0x4114U, pool2_ddr_hash);
    if (!bytes_equal(gf_pool2, gf_conv3a_layer_input, GF_POOL2_BYTES)) terminal_failure(0x4115U, pool2_ddr_hash);
    for (index = 0U; index < 5U; ++index) {
        u32 first_oc = index * 16U;
        u32 destination = (u32)(UINTPTR)gf_conv3a + first_oc;
        stage = 0x80U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv3a_tile(first_oc);
        conv3a_cycles[index] = run_layer(2U, (u32)(UINTPTR)gf_pool2, GF_POOL2_BYTES, destination,
                                         GF_CONV3A_TILE_BYTES, 1U, 24U, 24U, 80U, 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        conv3a_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); conv3a_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_POOL2_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != GF_CONV3A_TILE_BYTES) terminal_failure(0x4116U + index, store_status);
        store_probe(53U + index * 3U, conv3a_cycles[index]); store_probe(54U + index * 3U, conv3a_hash[index]); store_probe(55U + index * 3U, store_status);
    }
    conv3a_ddr_hash = fnv1a_bytes(gf_conv3a, GF_CONV3A_BYTES);
    store_probe(68U, conv3a_ddr_hash);
    if (conv3a_ddr_hash != GF_CONV3A_OUTPUT_FNV1A) terminal_failure(0x411bU, conv3a_ddr_hash);
    if (!bytes_equal(gf_conv3a, gf_conv3b_layer_input, GF_CONV3A_BYTES)) terminal_failure(0x411cU, conv3a_ddr_hash);
    for (index = 0U; index < 5U; ++index) {
        u32 first_oc = index * 16U;
        u32 destination = (u32)(UINTPTR)gf_conv3b + first_oc;
        stage = 0x90U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv3b_tile(first_oc);
        conv3b_cycles[index] = run_layer(3U, (u32)(UINTPTR)gf_conv3a, GF_CONV3A_BYTES, destination,
                                         GF_CONV3B_TILE_BYTES, 1U, 24U, 24U, 80U, 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        conv3b_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); conv3b_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_CONV3A_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != GF_CONV3B_TILE_BYTES) terminal_failure(0x411dU + index, store_status);
        store_probe(69U + index * 3U, conv3b_cycles[index]); store_probe(70U + index * 3U, conv3b_hash[index]); store_probe(71U + index * 3U, store_status);
    }
    conv3b_ddr_hash = fnv1a_bytes(gf_conv3b, GF_CONV3B_BYTES);
    store_probe(84U, conv3b_ddr_hash);
    if (conv3b_ddr_hash != GF_CONV3B_OUTPUT_FNV1A) terminal_failure(0x4122U, conv3b_ddr_hash);
    if (!bytes_equal(gf_conv3b, gf_pool3_input, GF_POOL3_INPUT_BYTES)) terminal_failure(0x4123U, conv3b_ddr_hash);
    /* The deployed pool3 route reuses the conv3_b output bank: the writer
     * performs signed 2x2 max before HP0 writes, so this does not read the
     * 46,080-byte conv3_b tensor back through DDR. The preceding comparison
     * establishes the exact pool input once for this board regression. */
    for (index = 0U; index < 5U; ++index) {
        u32 first_oc = index * 16U;
        u32 destination = (u32)(UINTPTR)gf_pool3 + first_oc;
        stage = 0xA0U + index;
        Xil_Out32(GF_BASE + GF_CONTROL, 1U); load_conv3b_tile(first_oc);
        pool3_cycles[index] = run_layer(3U, (u32)(UINTPTR)gf_conv3a, GF_CONV3A_BYTES, destination,
                                        GF_POOL3_TILE_BYTES, 3U, 24U, 24U, 80U, 16U);
        status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        pool3_cycles[index] = Xil_In32(GF_BASE + GF_CYCLES); pool3_hash[index] = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
        if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
            GF_DMA_BYTES_READ(dma_status) != GF_CONV3A_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
            GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL3_TILE_BYTES) terminal_failure(0x4124U + index, store_status);
        store_probe(85U + index * 3U, pool3_cycles[index]); store_probe(86U + index * 3U, pool3_hash[index]); store_probe(87U + index * 3U, store_status);
    }
    pool3_ddr_hash = fnv1a_bytes(gf_pool3, GF_POOL3_BYTES);
    store_probe(100U, pool3_ddr_hash);
    if (pool3_ddr_hash != GF_POOL3_OUTPUT_FNV1A) terminal_failure(0x4129U, pool3_ddr_hash);
    store_probe(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_LAYER_CHAIN_HP0_POOL3_BOARD_PASS c0=%lu c1=%lu pool=%lu conv2a=%lu,%lu,%lu conv2b=%lu,%lu,%lu pool2=%lu,%lu,%lu conv3a=%lu,%lu,%lu,%lu,%lu conv3b=%lu,%lu,%lu,%lu,%lu pool3=%lu,%lu,%lu,%lu,%lu hash0=%08lx hash1=%08lx pool=%08lx conv2a=%08lx conv2b=%08lx pool2=%08lx conv3a=%08lx conv3b=%08lx pool3=%08lx\r\n",
      (unsigned long)cycles0,(unsigned long)cycles1,(unsigned long)pool_cycles,(unsigned long)conv2_cycles[0],(unsigned long)conv2_cycles[1],(unsigned long)conv2_cycles[2],
      (unsigned long)conv2b_cycles[0],(unsigned long)conv2b_cycles[1],(unsigned long)conv2b_cycles[2],
      (unsigned long)pool2_cycles[0],(unsigned long)pool2_cycles[1],(unsigned long)pool2_cycles[2],
      (unsigned long)conv3a_cycles[0],(unsigned long)conv3a_cycles[1],(unsigned long)conv3a_cycles[2],(unsigned long)conv3a_cycles[3],(unsigned long)conv3a_cycles[4],
      (unsigned long)conv3b_cycles[0],(unsigned long)conv3b_cycles[1],(unsigned long)conv3b_cycles[2],(unsigned long)conv3b_cycles[3],(unsigned long)conv3b_cycles[4],
      (unsigned long)pool3_cycles[0],(unsigned long)pool3_cycles[1],(unsigned long)pool3_cycles[2],(unsigned long)pool3_cycles[3],(unsigned long)pool3_cycles[4],
      (unsigned long)GF_FULL_OUTPUT_FNV1A,(unsigned long)gf_chain_body_output_fnv1a,(unsigned long)pool_hash,
      (unsigned long)conv2_ddr_hash,(unsigned long)conv2b_ddr_hash,(unsigned long)pool2_ddr_hash,(unsigned long)conv3a_ddr_hash,(unsigned long)conv3b_ddr_hash,(unsigned long)pool3_ddr_hash);
    while (1) { usleep(100000U); }
}
