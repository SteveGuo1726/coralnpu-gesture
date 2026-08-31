/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * HaGRID-18 distilled-student full-network board driver.
 *
 * Deployment graph: 4x4/4x4/4x4 with channels 16/32/48, a 48->64 1x1 head,
 * GAP(64) and FC(18). The PL uses a parameterized 32-output x 4-input-lane
 * INT8 MAC tile; 16-output tails remain supported through lane masking. The
 * 1x1 head uses pointwise mode and the GAP/FC tail uses mode 4. Weights are
 * burst-loaded through WEIGHT_DMA; no per-pixel ARM path.
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
#include "gestureflow_real_conv4x4_head1x1_layer.h"
#include "gestureflow_real_gap_fc.h"

#ifndef GF_FAST_RELEASE
#define GF_FAST_RELEASE 0
#endif
#define PROBE_BASE 0xFFFF0000U
#define GF_BASE 0x43C00000U

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
#define GF_POST_GAP_MULT 0x080U
#define GF_POST_GAP_SHIFT 0x084U
#define GF_POST_QCFG 0x088U
#define GF_POST_GAP_FNV1A_REG 0x08CU
#define GF_POST_FC_FNV1A_REG 0x090U
#define GF_POST_CLASS_REG 0x094U
#define GF_POST_CYCLES_REG 0x098U
#define GF_POST_PROGRESS_REG 0x09CU
#define GF_WEIGHT_KEY 0x0C0U
#define GF_WEIGHT_RESIDENT_KEY 0x0C4U
#define GF_WEIGHT_WRITE_COUNT 0x0C8U
#define GF_WEIGHT_HIT_COUNT 0x0CCU
#define GF_WEIGHT_BYTES 0x0D0U
#define GF_WEIGHT_STATUS 0x0D4U
#define GF_WEIGHT_COMMIT 0x0D8U
#define GF_WEIGHT_MISS_COUNT 0x0DCU
#define GF_WEIGHT_DMA_SOURCE 0x0E0U
#define GF_WEIGHT_DMA_BYTES 0x0E4U
#define GF_WEIGHT_DMA_CFG 0x0E8U
#define GF_WEIGHT_DMA_CONTROL 0x0ECU
#define GF_WEIGHT_DMA_STATUS 0x0F0U
#define GF_WEIGHT_DMA_BYTES_READ 0x0F4U
#define GF_WEIGHT_DMA_WRITE_COUNT 0x0F8U
#define GF_WEIGHT_BANK_SELECT 0x0FCU
#define GF_WEIGHT_READ_BANK_SELECT 0x15CU

#define GF_RESULT_PASS 0x600D600DU
#define GF_RESULT_FAIL 0xBAD0BAD0U
#define GF_RESULT_DATA_ABORT 0xDA7AAB01U
#define GF_RESULT_PREFETCH_ABORT 0xDA7AAB02U
#define GF_DONE_BIT (1U << 1)
#define GF_FAULT_BIT (1U << 2)
#define GF_LAYER_FAULT_BIT (1U << 6)
#define GF_DMA_FAULT_BIT (1U << 2)
#define GF_DMA_DONE_BIT (1U << 1)
#define GF_DMA_BUSY_BIT (1U << 0)
#define GF_STORE_FAULT_BIT (1U << 2)
#define GF_STORE_DONE_BIT (1U << 1)
#define GF_WEIGHT_KEY_HIT_BIT (1U << 4)
#define GF_WEIGHT_DMA_BUSY_BIT (1U << 0)
#define GF_WEIGHT_DMA_DONE_BIT (1U << 1)
#define GF_WEIGHT_DMA_FAULT_BIT (1U << 2)
#define GF_DMA_BYTES_READ(value) ((value) >> 3)
#define GF_STORE_BYTES_WRITTEN(value) ((value) >> 3)

/* 18-class tensor sizes. */
#define GF_RGB_BYTES (96U * 96U * 3U)
#define GF_ACTIVATION_BYTES (96U * 96U * 16U)
#define GF_POOL1_BYTES GF_POOL_OUTPUT_BYTES
#define GF_CONV2_BYTES (48U * 48U * 32U)
#define GF_CONV2_TILE_BYTES (48U * 48U * 16U)
#define GF_CONV2_TILE32_BYTES (48U * 48U * 32U)
#define GF_CONV3_BYTES (48U * 48U * 32U)
#define GF_POOL2_TILE_BYTES (24U * 24U * 16U)
#define GF_POOL2_BYTES GF_POOL2_OUTPUT_BYTES
#define GF_CONV4_BYTES (24U * 24U * 48U)
#define GF_CONV4_TILE_BYTES (24U * 24U * 16U)
#define GF_CONV4_TILE32_BYTES (24U * 24U * 32U)
#define GF_CONV5_BYTES (24U * 24U * 48U)
#define GF_POOL3_TILE_BYTES (12U * 12U * 16U)
#define GF_POOL3_TILE32_BYTES (12U * 12U * 32U)
#define GF_POOL3_BYTES GF_POOL3_OUTPUT_BYTES
#define GF_HEAD1X1_BYTES (12U * 12U * 64U)
#define GF_HEAD1X1_TILE_BYTES (12U * 12U * 16U)
#define GF_HEAD1X1_TILE32_BYTES (12U * 12U * 32U)
#define GF_HEAD1X1_EMBEDDED_CENTER_TAP 5U

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static volatile u32 stage;
static uint8_t gf_rgb[GF_RGB_BYTES] __attribute__((aligned(64)));
static int8_t gf_activation_1[GF_ACTIVATION_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool1[GF_POOL1_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv2[GF_CONV2_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv3[GF_CONV3_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool2[GF_POOL2_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv4[GF_CONV4_BYTES] __attribute__((aligned(64)));
static int8_t gf_conv5[GF_CONV5_BYTES] __attribute__((aligned(64)));
static int8_t gf_pool3[GF_POOL3_BYTES] __attribute__((aligned(64)));
static int8_t gf_head1x1[GF_HEAD1X1_BYTES] __attribute__((aligned(64)));
static XTime g_weight_dma_ticks;

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
    xil_printf("GESTUREFLOW_HAGRID18_FAIL code=%08lx observed=%08lx\r\n",
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

static void weight_dma_load(const uint32_t *src, uint32_t words, uint32_t taps, uint32_t groups,
                            uint32_t output_lanes)
{
    uint32_t status;
    XTime dma_t0, dma_t1;
    uint32_t bytes = words * 4U;
    /* The exported packed weight image is in .rodata and may be cached. */
    Xil_DCacheFlushRange((UINTPTR)src, bytes);
    Xil_Out32(GF_BASE + GF_WEIGHT_DMA_SOURCE, (uint32_t)(UINTPTR)src);
    Xil_Out32(GF_BASE + GF_WEIGHT_DMA_BYTES, bytes);
    Xil_Out32(GF_BASE + GF_WEIGHT_DMA_CFG, taps | (groups << 8U) | (output_lanes << 16U));
    Xil_Out32(GF_BASE + GF_WEIGHT_DMA_CONTROL, 2U);
    XTime_GetTime(&dma_t0);
    do {
        status = Xil_In32(GF_BASE + GF_WEIGHT_DMA_STATUS);
    } while (status & GF_WEIGHT_DMA_BUSY_BIT);
    XTime_GetTime(&dma_t1);
    if (!(status & GF_WEIGHT_DMA_DONE_BIT) || (status & GF_WEIGHT_DMA_FAULT_BIT)) {
        terminal_failure(0x4D01U, status);
    }
    g_weight_dma_ticks += dma_t1 - dma_t0;
}

/* Generic spatial tile loader. dma_weights is the pre-packed WEIGHT_DMA image
 * (oc -> tap -> 4-lane group) emitted by the exporter. The physical engine is
 * 32 lanes wide, while output_lanes permits a final 16-lane tile without
 * sending dummy weights. */
static void load_conv_tile(u32 mode, u32 first_oc, u32 lane_mask,
                           const uint32_t *dma_weights, const int32_t *folded_bias,
                           const int32_t *multiplier, const uint8_t *right_shift,
                           u32 output_lanes, u32 groups, u32 tile_lanes)
{
    u32 physical_oc, model_oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, mode);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, lane_mask);
    for (physical_oc = 0U; physical_oc < 32U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        if (physical_oc >= tile_lanes || model_oc >= output_lanes) {
            Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, 0U);
            Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, 0U); Xil_Out32(GF_BASE + GF_RQSHIFT, 0U);
            continue;
        }
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)right_shift[model_oc]);
    }
    weight_dma_load(dma_weights + (uint32_t)first_oc * 16U * groups,
                    tile_lanes * 16U * groups, 16U, groups, tile_lanes);
}

/* First layer: RGB 3->16, one 4-lane group with lane 3 masked. */
static void load_first_layer(void)
{
    u32 oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 0U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffU);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_full_folded_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_full_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_full_requant_right_shift[oc]);
    }
    weight_dma_load(gf_full_weights_dma, 16U * 16U * 1U, 16U, 1U, 16U);
}

/* Head 1x1: only the embedded center tap (1,1) is nonzero. */
static void load_head1x1_tile(uint32_t first_oc)
{
    u32 physical_oc, model_oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 5U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffffffU);
    for (physical_oc = 0U; physical_oc < 32U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_head1x1_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_head1x1_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_head1x1_requant_right_shift[model_oc]);
    }
    weight_dma_load(gf_head1x1_weights_dma + (uint32_t)first_oc * 12U, 32U * 12U, 1U, 12U, 32U);
}

/* Ping-pong bank selectors. The physical weight bank is dual-bank: the MSB of
 * the weight address selects the bank. Writing bank B while computing from
 * bank A is legal after the MAC/chain enablement in records 122/123. */
static void set_weight_write_bank(u32 bank)
{
    Xil_Out32(GF_BASE + GF_WEIGHT_BANK_SELECT, bank & 1U);
}

static void set_weight_read_bank(u32 bank)
{
    Xil_Out32(GF_BASE + GF_WEIGHT_READ_BANK_SELECT, bank & 1U);
}

/* Config-only tile setup: mode/QCFG/lane mask + folded bias + per-channel
 * requant. Weights are loaded separately so their DMA can overlap the previous
 * layer's compute. */
static void config_conv_tile(u32 mode, u32 first_oc, u32 lane_mask,
                             const int32_t *folded_bias, const int32_t *multiplier,
                             const uint8_t *right_shift, u32 output_lanes, u32 tile_lanes)
{
    u32 physical_oc, model_oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, mode);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, lane_mask);
    for (physical_oc = 0U; physical_oc < 32U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        if (physical_oc >= tile_lanes || model_oc >= output_lanes) {
            Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, 0U);
            Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, 0U); Xil_Out32(GF_BASE + GF_RQSHIFT, 0U);
            continue;
        }
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)right_shift[model_oc]);
    }
}

/* Config-only first RGB layer (no weight DMA). */
static void config_first_layer(void)
{
    u32 oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 0U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffU);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_full_folded_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_full_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_full_requant_right_shift[oc]);
    }
}

/* Config-only 1x1 head tile (no weight DMA). */
static void config_head1x1_tile(uint32_t first_oc)
{
    u32 physical_oc, model_oc;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 5U);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_OUTPUT_LANE_MASK, 0xffffffffU);
    for (physical_oc = 0U; physical_oc < 32U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_head1x1_folded_bias[model_oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, physical_oc); Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_head1x1_requant_multiplier[model_oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_head1x1_requant_right_shift[model_oc]);
    }
}

/* Launch a layer without waiting so the next layer's weight DMA can overlap. */
static void launch_layer(uint32_t mode, uint32_t source, uint32_t bytes, uint32_t destination,
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
}

/* Wait until the input loader has fully read the input (dma_done==1), so a
 * weight DMA can start without colliding on the AR read channel. Polling
 * dma_done (rather than dma_busy==0) avoids the launch race where dma_busy has
 * not yet asserted when the first poll runs. */
static void wait_input_loaded(void)
{
    u32 poll;
    for (poll = 0U; poll < 12000000U; ++poll) {
        if (Xil_In32(GF_BASE + GF_DMA_STATUS) & GF_DMA_DONE_BIT) return;
    }
    terminal_failure(0x4D02U, Xil_In32(GF_BASE + GF_DMA_STATUS));
}

/* Weight-only preload for a spatial tile; mirrors the tail of load_conv_tile. */
static void preload_conv_tile(const uint32_t *dma_weights, u32 first_oc, u32 groups, u32 tile_lanes)
{
    weight_dma_load(dma_weights + first_oc * 16U * groups, tile_lanes * 16U * groups, 16U, groups, tile_lanes);
}

/* Weight-only preload for a 1x1 head tile. */
static void preload_head1x1_tile(u32 first_oc)
{
    weight_dma_load(gf_head1x1_weights_dma + first_oc * 12U, 32U * 12U, 1U, 12U, 32U);
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

static void load_gap_fc_descriptor(void)
{
    u32 class_index, group, lane, packed;
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 4U);
    Xil_Out32(GF_BASE + GF_POST_GAP_MULT, (u32)GF_POST_GAP_MULTIPLIER);
    Xil_Out32(GF_BASE + GF_POST_GAP_SHIFT, GF_POST_GAP_RIGHT_SHIFT);
    Xil_Out32(GF_BASE + GF_POST_QCFG,
              ((u32)(uint8_t)GF_POST_GAP_INPUT_ZERO_POINT) |
              ((u32)(uint8_t)GF_POST_GAP_OUTPUT_ZERO_POINT << 8U) |
              ((u32)(uint8_t)GF_POST_FC_OUTPUT_ZERO_POINT << 16U));
    for (class_index = 0U; class_index < GF_POST_FC_OUTPUTS; ++class_index) {
        Xil_Out32(GF_BASE + GF_BIDX, class_index);
        Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_post_fc_folded_bias[class_index]);
        Xil_Out32(GF_BASE + GF_RQIDX, class_index);
        Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_post_fc_requant_multiplier[class_index]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_post_fc_requant_right_shift[class_index]);
        for (group = 0U; group < GF_POST_GAP_CHANNELS / 4U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                packed |= (u32)(uint8_t)gf_post_fc_weights[class_index * GF_POST_GAP_CHANNELS + group * 4U + lane] << (lane * 8U);
            }
            Xil_Out32(GF_BASE + GF_WCTRL, class_index | (group << 9U));
            Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

static u32 run_gap_fc(uint32_t source)
{
    Xil_Out32(GF_BASE + GF_LAYER_MODE, 4U);
    Xil_Out32(GF_BASE + GF_DMA_SOURCE, source);
    Xil_Out32(GF_BASE + GF_DMA_BYTES, GF_HEAD1X1_BYTES);
    Xil_Out32(GF_BASE + GF_DMA_PIXELS, GF_POST_GAP_ELEMENTS);
    Xil_Out32(GF_BASE + GF_STORE_CONTROL, 0U);
    Xil_Out32(GF_BASE + GF_CONTROL, 2U);
    wait_layer_done();
    return Xil_In32(GF_BASE + GF_POST_CYCLES_REG);
}

/* Run one 16-output tile and check its DDR-side FNV against the tile golden.
 * The exporter's per-layer FNV is over the full NHWC tensor, so we accumulate
 * the per-tile FNV in software against the full tensor header. */
static int verify_full_tensor(const int8_t *buf, uint32_t bytes, uint32_t expected_fnv)
{
#if GF_FAST_RELEASE
    (void)buf; (void)bytes; (void)expected_fnv;
    return 1;
#else
    return fnv1a_bytes(buf, bytes) == expected_fnv;
#endif
}

int main(void)
{
    u32 index, status, dma_status, store_status, hash;
    u32 cycles0, pool_cycles, gap_fc_cycles;
    u32 conv2_cycles[2] = {0U}, conv3_cycles[2] = {0U};
    u32 pool2_cycles[2] = {0U};
    u32 conv4_cycles[3] = {0U}, conv5_cycles[3] = {0U};
    u32 pool3_cycles[3] = {0U};
    u32 head1x1_cycles[4] = {0U};
    u32 gap_fnv, fc_fnv, post_class, post_progress;
    u32 pl_cycles_total;
    XTime frame_start, frame_end;
    u32 frame_ticks, weight_ticks32;

    Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY); Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_rgb, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_activation_1, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_pool1, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_conv2, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_conv3, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_pool2, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_conv4, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_conv5, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_pool3, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)gf_head1x1, DEVICE_MEMORY);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort, 0);
    Xil_ExceptionEnable();
    for (index = 0U; index < 136U; ++index) store_probe(index, 0U);
    store_probe(0U, 0x47464E50U);
    stage = 0x10U;
    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) terminal_failure(0x4101U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00040004U) terminal_failure(0x4102U, Xil_In32(GF_BASE + GF_VERSION));
    XTime_GetTime(&frame_start);

    for (index = 0U; index < GF_RGB_BYTES; ++index) gf_rgb[index] = gf_full_camera_rgb[index];
    Xil_DCacheFlushRange((UINTPTR)gf_rgb, GF_RGB_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool1, GF_POOL1_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv2, GF_CONV2_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv3, GF_CONV3_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool2, GF_POOL2_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv4, GF_CONV4_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_conv5, GF_CONV5_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_pool3, GF_POOL3_BYTES);
    Xil_DCacheFlushRange((UINTPTR)gf_head1x1, GF_HEAD1X1_BYTES);

    /* conv0: 3->16 (weights -> bank 0; preload conv1 -> bank 1) */
    stage = 0x20U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    set_weight_write_bank(0U); config_first_layer();
    weight_dma_load(gf_full_weights_dma, 16U * 16U * 1U, 16U, 1U, 16U);
    set_weight_write_bank(1U);
    set_weight_read_bank(0U);
    launch_layer(0U, (u32)(UINTPTR)gf_rgb, GF_RGB_BYTES, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, 1U, 96U, 96U, 16U, 16U);
    wait_input_loaded();
    preload_conv_tile(gf_body2_weights_dma, 0U, 4U, 16U);
    wait_layer_done();
    cycles0 = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_RGB_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_ACTIVATION_BYTES ||
        hash != GF_FULL_OUTPUT_FNV1A || !verify_full_tensor(gf_activation_1, GF_ACTIVATION_BYTES, GF_FULL_OUTPUT_FNV1A))
        terminal_failure(0x4103U, hash);

    /* conv1 (body): 16->16 fused with pool1 (bank 1; preload conv2 -> bank 0) */
    stage = 0x40U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(1U, 0U, 0xffffU, gf_body2_folded_bias, gf_body2_requant_multiplier, gf_body2_requant_right_shift, 16U, 16U);
    set_weight_write_bank(0U);
    set_weight_read_bank(1U);
    launch_layer(1U, (u32)(UINTPTR)gf_activation_1, GF_ACTIVATION_BYTES, (u32)(UINTPTR)gf_pool1, GF_POOL1_BYTES, 3U, 96U, 96U, 16U, 16U);
    wait_input_loaded();
    preload_conv_tile(gf_conv2a_weights_dma, 0U, 4U, 32U);
    wait_layer_done();
    pool_cycles = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    hash = Xil_In32(GF_BASE + GF_OUTPUT_FNV1A);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_ACTIVATION_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL1_BYTES ||
        hash != GF_BODY2_OUTPUT_FNV1A || !verify_full_tensor(gf_pool1, GF_POOL1_BYTES, GF_POOL_OUTPUT_FNV1A))
        terminal_failure(0x4105U, hash);

    /* conv2: 16->32 (bank 0; preload conv3 -> bank 1) */
    stage = 0x50U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(1U, 0U, 0xffffffffU, gf_conv2a_folded_bias, gf_conv2a_requant_multiplier, gf_conv2a_requant_right_shift, GF_CONV2A_OUTPUT_LANES, 32U);
    set_weight_write_bank(1U);
    set_weight_read_bank(0U);
    launch_layer(1U, (u32)(UINTPTR)gf_pool1, GF_POOL1_BYTES, (u32)(UINTPTR)gf_conv2, GF_CONV2_BYTES, 1U, 48U, 48U, 32U, 32U);
    wait_input_loaded();
    preload_conv_tile(gf_conv2b_weights_dma, 0U, 8U, 32U);
    wait_layer_done();
    conv2_cycles[0] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_POOL1_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_CONV2_BYTES) terminal_failure(0x4107U, store_status);
    if (!verify_full_tensor(gf_conv2, GF_CONV2_BYTES, GF_CONV2A_OUTPUT_FNV1A)) terminal_failure(0x410AU, fnv1a_bytes(gf_conv2, GF_CONV2_BYTES));

    /* conv3: 32->32 fused with pool2 (bank 1; preload conv4t0 -> bank 0) */
    stage = 0x70U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(2U, 0U, 0xffffffffU, gf_conv2b_folded_bias, gf_conv2b_requant_multiplier, gf_conv2b_requant_right_shift, GF_CONV2B_OUTPUT_LANES, 32U);
    set_weight_write_bank(0U);
    set_weight_read_bank(1U);
    launch_layer(2U, (u32)(UINTPTR)gf_conv2, GF_CONV2_BYTES, (u32)(UINTPTR)gf_pool2, GF_POOL2_BYTES, 3U, 48U, 48U, 32U, 32U);
    wait_input_loaded();
    preload_conv_tile(gf_conv3a_weights_dma, 0U, 8U, 32U);
    wait_layer_done();
    pool2_cycles[0] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_CONV2_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL2_BYTES) terminal_failure(0x4111U, store_status);
    if (!verify_full_tensor(gf_pool2, GF_POOL2_BYTES, GF_POOL2_OUTPUT_FNV1A)) terminal_failure(0x4114U, fnv1a_bytes(gf_pool2, GF_POOL2_BYTES));

    /* conv4: 32->48 (tile0 bank0; tile1 bank1; preload conv5t0 -> bank0) */
    stage = 0x80U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(2U, 0U, 0xffffffffU, gf_conv3a_folded_bias, gf_conv3a_requant_multiplier, gf_conv3a_requant_right_shift, GF_CONV3A_OUTPUT_LANES, 32U);
    set_weight_write_bank(1U);
    set_weight_read_bank(0U);
    launch_layer(2U, (u32)(UINTPTR)gf_pool2, GF_POOL2_BYTES, (u32)(UINTPTR)gf_conv4, GF_CONV4_TILE32_BYTES, 1U, 24U, 24U, 48U, 32U);
    wait_input_loaded();
    preload_conv_tile(gf_conv3a_weights_dma, 32U, 8U, 16U);
    wait_layer_done();
    conv4_cycles[0] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_POOL2_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_CONV4_TILE32_BYTES) terminal_failure(0x4116U, store_status);

    stage = 0x81U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(2U, 32U, 0xffffU, gf_conv3a_folded_bias, gf_conv3a_requant_multiplier, gf_conv3a_requant_right_shift, GF_CONV3A_OUTPUT_LANES, 16U);
    set_weight_write_bank(0U);
    set_weight_read_bank(1U);
    launch_layer(2U, (u32)(UINTPTR)gf_pool2, GF_POOL2_BYTES, (u32)(UINTPTR)gf_conv4 + 32U, GF_CONV4_TILE_BYTES, 1U, 24U, 24U, 48U, 16U);
    wait_input_loaded();
    preload_conv_tile(gf_conv3b_weights_dma, 0U, 12U, 32U);
    wait_layer_done();
    conv4_cycles[1] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_POOL2_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_CONV4_TILE_BYTES) terminal_failure(0x4117U, store_status);
    if (!verify_full_tensor(gf_conv4, GF_CONV4_BYTES, GF_CONV3A_OUTPUT_FNV1A)) terminal_failure(0x411BU, fnv1a_bytes(gf_conv4, GF_CONV4_BYTES));

    /* conv5: 48->48 fused with pool3 (tile0 bank0; tile1 bank1; preload head0 -> bank0) */
    stage = 0x90U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(3U, 0U, 0xffffffffU, gf_conv3b_folded_bias, gf_conv3b_requant_multiplier, gf_conv3b_requant_right_shift, GF_CONV3B_OUTPUT_LANES, 32U);
    set_weight_write_bank(1U);
    set_weight_read_bank(0U);
    launch_layer(3U, (u32)(UINTPTR)gf_conv4, GF_CONV4_BYTES, (u32)(UINTPTR)gf_pool3, GF_POOL3_TILE32_BYTES, 3U, 24U, 24U, 48U, 32U);
    wait_input_loaded();
    preload_conv_tile(gf_conv3b_weights_dma, 32U, 12U, 16U);
    wait_layer_done();
    pool3_cycles[0] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_CONV4_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL3_TILE32_BYTES) terminal_failure(0x411DU, store_status);

    stage = 0x91U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_conv_tile(3U, 32U, 0xffffU, gf_conv3b_folded_bias, gf_conv3b_requant_multiplier, gf_conv3b_requant_right_shift, GF_CONV3B_OUTPUT_LANES, 16U);
    set_weight_write_bank(0U);
    set_weight_read_bank(1U);
    launch_layer(3U, (u32)(UINTPTR)gf_conv4, GF_CONV4_BYTES, (u32)(UINTPTR)gf_pool3 + 32U, GF_POOL3_TILE_BYTES, 3U, 24U, 24U, 48U, 16U);
    wait_input_loaded();
    preload_head1x1_tile(0U);
    wait_layer_done();
    pool3_cycles[1] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_CONV4_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_POOL3_TILE_BYTES) terminal_failure(0x411EU, store_status);
    if (!verify_full_tensor(gf_pool3, GF_POOL3_BYTES, GF_POOL3_OUTPUT_FNV1A)) terminal_failure(0x4129U, fnv1a_bytes(gf_pool3, GF_POOL3_BYTES));

    /* head 1x1: 48->64 (tile0 bank0; tile1 bank1) */
    stage = 0xB0U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_head1x1_tile(0U);
    set_weight_write_bank(1U);
    set_weight_read_bank(0U);
    launch_layer(5U, (u32)(UINTPTR)gf_pool3, GF_POOL3_BYTES, (u32)(UINTPTR)gf_head1x1, GF_HEAD1X1_TILE32_BYTES, 1U, 12U, 12U, 64U, 32U);
    wait_input_loaded();
    preload_head1x1_tile(32U);
    wait_layer_done();
    head1x1_cycles[0] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_POOL3_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_HEAD1X1_TILE32_BYTES) terminal_failure(0x412BU, store_status);

    stage = 0xB1U; Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    config_head1x1_tile(32U);
    set_weight_read_bank(1U);
    launch_layer(5U, (u32)(UINTPTR)gf_pool3, GF_POOL3_BYTES, (u32)(UINTPTR)gf_head1x1 + 32U, GF_HEAD1X1_TILE32_BYTES, 1U, 12U, 12U, 64U, 32U);
    wait_layer_done();
    head1x1_cycles[1] = Xil_In32(GF_BASE + GF_CYCLES);
    status = Xil_In32(GF_BASE + GF_STATUS); dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS); store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_POOL3_BYTES || (store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != GF_HEAD1X1_TILE32_BYTES) terminal_failure(0x412CU, store_status);
    if (!verify_full_tensor(gf_head1x1, GF_HEAD1X1_BYTES, GF_HEAD1X1_OUTPUT_FNV1A)) terminal_failure(0x4132U, fnv1a_bytes(gf_head1x1, GF_HEAD1X1_BYTES));

    /* GAP(64) + FC(18) */
    stage = 0xC0U;
    Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    load_gap_fc_descriptor();
    gap_fc_cycles = run_gap_fc((u32)(UINTPTR)gf_head1x1);
    status = Xil_In32(GF_BASE + GF_STATUS);
    dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
    gap_fnv = Xil_In32(GF_BASE + GF_POST_GAP_FNV1A_REG);
    fc_fnv = Xil_In32(GF_BASE + GF_POST_FC_FNV1A_REG);
    post_class = Xil_In32(GF_BASE + GF_POST_CLASS_REG);
    post_progress = Xil_In32(GF_BASE + GF_POST_PROGRESS_REG);
    if ((status & (GF_FAULT_BIT|GF_LAYER_FAULT_BIT)) || (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_HEAD1X1_BYTES || gap_fnv != GF_POST_GAP_EXPECTED_FNV1A ||
        fc_fnv != GF_POST_FC_EXPECTED_FNV1A || (post_class & 31U) != GF_POST_EXPECTED_CLASS)
        terminal_failure(0x4133U, fc_fnv);

    XTime_GetTime(&frame_end);
    frame_ticks = (u32)(frame_end - frame_start);
    weight_ticks32 = (u32)g_weight_dma_ticks;
    store_probe(132U, (u32)g_weight_dma_ticks);
    pl_cycles_total = cycles0 + pool_cycles + gap_fc_cycles;
    for (index = 0U; index < 2U; ++index) pl_cycles_total += conv2_cycles[index] + pool2_cycles[index];
    for (index = 0U; index < 3U; ++index) pl_cycles_total += conv4_cycles[index] + pool3_cycles[index];
    for (index = 0U; index < 4U; ++index) pl_cycles_total += head1x1_cycles[index];
    store_probe(130U, frame_ticks); store_probe(131U, weight_ticks32); store_probe(133U, pl_cycles_total);
    store_probe(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_HAGRID18_BOARD_PASS frame_ticks=%lu weight_ticks=%lu pl_cycles=%lu gap=%08lx fc=%08lx class=%lu\r\n",
               (unsigned long)frame_ticks, (unsigned long)weight_ticks32, (unsigned long)pl_cycles_total,
               (unsigned long)gap_fnv, (unsigned long)fc_fnv, (unsigned long)(post_class & 31U));
    while (1) { usleep(100000U); }
}
