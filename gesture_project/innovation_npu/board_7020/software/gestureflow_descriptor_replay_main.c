/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/*
 * Descriptor ABI board test for the project-local GestureFlow 7020 IP.
 *
 * This is intentionally a bounded bridge test, not a full-network claim:
 * weights/bias/requant are loaded once through the compatibility registers,
 * then real conv1_a -> conv1_b -> pool1 jobs are submitted with one
 * descriptor doorbell. The PS then loads three output-channel tiles for each
 * 40-channel body layer and submits one descriptor per tile. It never
 * computes a convolution or copies an activation tensor; it only changes
 * layer metadata and resident weights at layer/tile boundaries.
 */
#include <stdint.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "gestureflow_real_conv4x4_full_layer.h"
#include "gestureflow_chain_body_data.h"
#include "gestureflow_real_maxpool2d.h"
#include "gestureflow_real_conv4x4_conv2a_layer.h"
#include "gestureflow_real_conv4x4_conv2b_layer.h"
#include "gestureflow_real_maxpool2d_pool2.h"
#include "gestureflow_real_conv4x4_conv3a_layer.h"
#include "gestureflow_real_conv4x4_conv3b_layer.h"

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
#define GF_OUTPUT_FNV1A 0x040U
#define GF_DESC_SELECT 0x100U
#define GF_DESC_MODE 0x104U
#define GF_DESC_JOB_SHAPE 0x108U
#define GF_DESC_DMA_SOURCE 0x10CU
#define GF_DESC_DMA_BYTES 0x110U
#define GF_DESC_DMA_PIXELS 0x114U
#define GF_DESC_STORE_DESTINATION 0x118U
#define GF_DESC_STORE_BYTES 0x11CU
#define GF_DESC_STORE_CONTROL 0x120U
#define GF_DESC_STORE_STRIDE 0x124U
#define GF_DESC_STORE_VALID_BYTES 0x128U
#define GF_DESC_QCFG 0x12CU
#define GF_DESC_LANE_MASK 0x130U
#define GF_DESC_COUNT 0x134U
#define GF_DESC_CONTROL 0x138U
#define GF_DESC_STATUS 0x13CU
#define GF_DESC_ISSUED 0x140U
#define GF_DESC_COMPLETED 0x144U
#define GF_DESC_WEIGHT_BANK 0x148U
#define GF_DESC_PARAM_BANK 0x14CU
#define GF_DESC_TASK_CYCLES 0x154U
#define GF_WEIGHT_BANK_SELECT 0x0FCU
#define GF_PARAM_BANK_SELECT 0x150U

#define GF_STATUS_DONE (1U << 1)
#define GF_STATUS_FAULT (1U << 2)
#define GF_DMA_STATUS 0x050U
#define GF_STORE_STATUS 0x060U
#define GF_DMA_DONE (1U << 1)
#define GF_DMA_FAULT (1U << 2)
#define GF_STORE_DONE (1U << 1)
#define GF_STORE_FAULT (1U << 2)
#define GF_RESULT_PASS 0x600D600DU
#define GF_RESULT_FAIL 0xBAD0BAD0U
#define GF_RGB_BYTES (96U * 96U * 3U)
#define GF_OUTPUT_BYTES (96U * 96U * 16U)
#define GF_POOL1_BYTES (48U * 48U * 16U)
#define GF_CONV2A_BYTES (48U * 48U * 40U)
#define GF_CONV2A_TILE_BYTES (48U * 48U * 16U)
#define GF_CONV2B_BYTES (48U * 48U * 40U)
#define GF_CONV2B_TILE_BYTES (48U * 48U * 16U)
#define GF_POOL2_BYTES (24U * 24U * 40U)
#define GF_POOL2_TILE_BYTES (24U * 24U * 16U)
#define GF_CONV3A_BYTES (24U * 24U * 80U)
#define GF_CONV3A_TILE_BYTES (24U * 24U * 16U)

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static uint8_t input_rgb[GF_RGB_BYTES] __attribute__((aligned(64)));
static int8_t output_a[GF_OUTPUT_BYTES] __attribute__((aligned(64)));
static int8_t output_pool1[GF_POOL1_BYTES] __attribute__((aligned(64)));
static int8_t output_conv2a[GF_CONV2A_BYTES] __attribute__((aligned(64)));
static int8_t output_conv2b[GF_CONV2B_BYTES] __attribute__((aligned(64)));
static int8_t output_pool2[GF_POOL2_BYTES] __attribute__((aligned(64)));
static int8_t output_conv3a[GF_CONV3A_BYTES] __attribute__((aligned(64)));

static void probe_write(u32 index, u32 value)
{
    probe[index] = value;
    __asm__ volatile ("dsb sy" : : : "memory");
}

static uint32_t fnv1a(const int8_t *data, uint32_t count)
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

static void fail(u32 code, u32 observed)
{
    probe_write(0U, GF_RESULT_FAIL);
    probe_write(1U, code);
    probe_write(2U, observed);
    xil_printf("GESTUREFLOW_DESCRIPTOR_REPLAY_FAIL code=%08lx observed=%08lx\r\n",
               (unsigned long)code, (unsigned long)observed);
    while (1) { }
}

static void write_layer_context(u32 bank, const int8_t *weights, u32 weight_stride,
                                u32 input_channels,
                                const int32_t *bias, const int32_t *multiplier,
                                const uint8_t *right_shift, u32 model_outputs)
{
    u32 oc, tap, group, lane, wi, packed;
    Xil_Out32(GF_BASE + GF_WEIGHT_BANK_SELECT, bank);
    Xil_Out32(GF_BASE + GF_PARAM_BANK_SELECT, bank);
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc);
        Xil_Out32(GF_BASE + GF_BDATA, oc < model_outputs ? (u32)bias[oc] : 0U);
        Xil_Out32(GF_BASE + GF_RQIDX, oc);
        Xil_Out32(GF_BASE + GF_RQMULT, oc < model_outputs ? (u32)multiplier[oc] : 0U);
        Xil_Out32(GF_BASE + GF_RQSHIFT, oc < model_outputs ? (u32)right_shift[oc] : 0U);
        for (tap = 0U; tap < 16U; ++tap) {
            for (group = 0U; group < (input_channels + 3U) / 4U; ++group) {
                wi = oc * weight_stride + tap * input_channels + group * 4U;
                packed = 0U;
                for (lane = 0U; lane < 4U; ++lane)
                    if (oc < model_outputs && group * 4U + lane < input_channels)
                        packed |= (uint32_t)(uint8_t)weights[wi + lane] << (lane * 8U);
                Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4U) | (group << 8U));
                Xil_Out32(GF_BASE + GF_WDATA, packed);
            }
        }
    }
}

static void stage_descriptor(u32 slot, u32 mode, u32 width, u32 height,
                             u32 source, u32 source_bytes, u32 source_pixels,
                             u32 destination, u32 store_bytes, u32 store_control,
                             u32 store_stride, u32 valid_bytes, u32 lane_mask,
                             u32 weight_bank)
{
    Xil_Out32(GF_BASE + GF_DESC_SELECT, slot);
    Xil_Out32(GF_BASE + GF_DESC_MODE, mode);
    Xil_Out32(GF_BASE + GF_DESC_JOB_SHAPE, (height << 16U) | width);
    Xil_Out32(GF_BASE + GF_DESC_DMA_SOURCE, source);
    Xil_Out32(GF_BASE + GF_DESC_DMA_BYTES, source_bytes);
    Xil_Out32(GF_BASE + GF_DESC_DMA_PIXELS, source_pixels);
    Xil_Out32(GF_BASE + GF_DESC_STORE_DESTINATION, destination);
    Xil_Out32(GF_BASE + GF_DESC_STORE_BYTES, store_bytes);
    Xil_Out32(GF_BASE + GF_DESC_STORE_CONTROL, store_control);
    Xil_Out32(GF_BASE + GF_DESC_STORE_STRIDE, store_stride);
    Xil_Out32(GF_BASE + GF_DESC_STORE_VALID_BYTES, valid_bytes);
    Xil_Out32(GF_BASE + GF_DESC_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_DESC_LANE_MASK, lane_mask);
    Xil_Out32(GF_BASE + GF_DESC_WEIGHT_BANK, weight_bank);
    Xil_Out32(GF_BASE + GF_DESC_PARAM_BANK, weight_bank);
}

static u32 wait_done(void)
{
    u32 poll, status = 0U;
    for (poll = 0U; poll < 12000000U; ++poll) {
        status = Xil_In32(GF_BASE + GF_STATUS);
        if (status & GF_STATUS_FAULT) fail(0x5201U, status);
        if (status & GF_STATUS_DONE) return status;
    }
    fail(0x5202U, status);
    return status;
}

int main(void)
{
    u32 status, dma_status, store_status, issued, completed, descriptor_status;
    u32 hash_a, hash_pool1, hash_conv2a, hash_conv2b, hash_pool2, hash_conv3a;
    u32 cycles_a, cycles_pool1;
    u32 cycles_conv2a[3], cycles_conv2b[3], cycles_pool2[3], cycles_conv3a[5];
    u32 tile_first_oc[3] = {0U, 16U, 32U};
    u32 tile_valid_bytes[3] = {16U, 16U, 8U};
    u32 index;

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)input_rgb, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_a, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_pool1, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_conv2a, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_conv2b, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_pool2, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_conv3a, DEVICE_MEMORY);
    for (index = 0U; index < 8U; ++index) probe_write(index, 0U);

    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) fail(0x5101U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00040004U) fail(0x5102U, Xil_In32(GF_BASE + GF_VERSION));
    Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    write_layer_context(0U, gf_full_weights, 48U, 3U, gf_full_folded_bias,
                        gf_full_requant_multiplier, gf_full_requant_right_shift, 16U);
    write_layer_context(1U, gf_chain_body_weights, 256U, 16U, gf_chain_body_bias,
                        gf_chain_body_multiplier, gf_chain_body_right_shift, 16U);
    for (index = 0U; index < GF_RGB_BYTES; ++index) input_rgb[index] = gf_full_camera_rgb[index];
    Xil_DCacheFlushRange((UINTPTR)input_rgb, GF_RGB_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_a, GF_OUTPUT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_pool1, GF_POOL1_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_conv2a, GF_CONV2A_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_conv2b, GF_CONV2B_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_pool2, GF_POOL2_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_conv3a, GF_CONV3A_BYTES);

    stage_descriptor(0U, 0U, 96U, 96U, (u32)(UINTPTR)input_rgb, GF_RGB_BYTES,
                     96U * 96U, (u32)(UINTPTR)output_a, GF_OUTPUT_BYTES, 1U,
                     16U, 16U, 0xFFFFU, 0U);
    stage_descriptor(1U, 1U, 96U, 96U, (u32)(UINTPTR)output_a, GF_OUTPUT_BYTES,
                     96U * 96U, (u32)(UINTPTR)output_pool1, GF_POOL1_BYTES, 3U,
                     16U, 16U, 0xFFFFU, 1U);
    Xil_Out32(GF_BASE + GF_DESC_COUNT, 2U);
    Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
    status = wait_done();
    dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
    store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
    completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
    descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
    hash_a = fnv1a(output_a, GF_OUTPUT_BYTES);
    hash_pool1 = fnv1a(output_pool1, GF_POOL1_BYTES);
    Xil_Out32(GF_BASE + GF_DESC_SELECT, 0U);
    cycles_a = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
    Xil_Out32(GF_BASE + GF_DESC_SELECT, 1U);
    cycles_pool1 = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
    probe_write(1U, issued);
    probe_write(2U, completed);
    probe_write(3U, hash_a);
    probe_write(4U, hash_pool1);
    probe_write(5U, cycles_a);
    probe_write(10U, cycles_pool1);
    probe_write(6U, dma_status);
    probe_write(7U, store_status);
    probe_write(8U, descriptor_status);
    probe_write(9U, status);

    if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
        !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
        issued != 2U || completed != 2U || hash_a != GF_FULL_OUTPUT_FNV1A ||
        hash_pool1 != GF_POOL_OUTPUT_FNV1A ||
        !bytes_equal(output_pool1, gf_conv2a_layer_input, GF_POOL1_BYTES)) {
        fail(0x5203U, descriptor_status);
    }
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = tile_first_oc[index];
        u32 valid_bytes = tile_valid_bytes[index];
        u32 lane_mask = index == 2U ? 0x00FFU : 0xFFFFU;
        u32 destination = (u32)(UINTPTR)output_conv2a + first_oc;
        write_layer_context(0U, &gf_conv2a_weights[first_oc * 256U], 256U, 16U,
                            &gf_conv2a_folded_bias[first_oc],
                            &gf_conv2a_requant_multiplier[first_oc],
                            &gf_conv2a_requant_right_shift[first_oc],
                            valid_bytes == 16U ? 16U : 8U);
        stage_descriptor(0U, 1U, 48U, 48U, (u32)(UINTPTR)output_pool1,
                         GF_POOL1_BYTES, 48U * 48U, destination,
                         48U * 48U * valid_bytes, 1U, 40U, valid_bytes,
                         lane_mask, 0U);
        Xil_Out32(GF_BASE + GF_DESC_COUNT, 1U);
        Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
        status = wait_done();
        dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
        store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
        completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
        descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
        Xil_Out32(GF_BASE + GF_DESC_SELECT, 0U);
        cycles_conv2a[index] = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
        if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
            !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
            issued != 1U || completed != 1U) fail(0x5210U + index, descriptor_status);
        probe_write(11U + index * 3U, cycles_conv2a[index]);
        probe_write(12U + index * 3U, fnv1a(output_conv2a + first_oc, GF_CONV2A_TILE_BYTES));
        probe_write(13U + index * 3U, store_status);
    }
    hash_conv2a = fnv1a(output_conv2a, GF_CONV2A_BYTES);
    probe_write(20U, hash_conv2a);
    if (hash_conv2a != GF_CONV2A_OUTPUT_FNV1A ||
        !bytes_equal(output_conv2a, gf_conv2b_layer_input, GF_CONV2A_BYTES))
        fail(0x5220U, hash_conv2a);
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = tile_first_oc[index];
        u32 valid_bytes = tile_valid_bytes[index];
        u32 lane_mask = index == 2U ? 0x00FFU : 0xFFFFU;
        u32 destination = (u32)(UINTPTR)output_conv2b + first_oc;
        write_layer_context(0U, &gf_conv2b_weights[first_oc * 640U], 640U, 40U,
                            &gf_conv2b_folded_bias[first_oc],
                            &gf_conv2b_requant_multiplier[first_oc],
                            &gf_conv2b_requant_right_shift[first_oc],
                            valid_bytes == 16U ? 16U : 8U);
        stage_descriptor(0U, 2U, 48U, 48U, (u32)(UINTPTR)output_conv2a,
                         GF_CONV2A_BYTES, 48U * 48U, destination,
                         48U * 48U * valid_bytes, 1U, 40U, valid_bytes,
                         lane_mask, 0U);
        Xil_Out32(GF_BASE + GF_DESC_COUNT, 1U);
        Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
        status = wait_done();
        dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
        store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
        completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
        descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
        Xil_Out32(GF_BASE + GF_DESC_SELECT, 0U);
        cycles_conv2b[index] = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
        if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
            !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
            issued != 1U || completed != 1U) fail(0x5230U + index, descriptor_status);
        probe_write(21U + index * 3U, cycles_conv2b[index]);
        probe_write(22U + index * 3U, fnv1a(output_conv2b + first_oc, GF_CONV2B_TILE_BYTES));
        probe_write(23U + index * 3U, store_status);
    }
    hash_conv2b = fnv1a(output_conv2b, GF_CONV2B_BYTES);
    probe_write(30U, hash_conv2b);
    if (hash_conv2b != GF_CONV2B_OUTPUT_FNV1A ||
        !bytes_equal(output_conv2b, gf_pool2_input, GF_POOL2_INPUT_BYTES))
        fail(0x5240U, hash_conv2b);

    /*
     * Real pool2 handoff. The PL writer consumes the 48x48x40 conv2_b
     * vectors already in DDR and performs 2x2 max pooling while writing a
     * 24x24x40 tensor. ARM only stages one descriptor per output tile.
     */
    for (index = 0U; index < 3U; ++index) {
        u32 first_oc = tile_first_oc[index];
        u32 valid_bytes = tile_valid_bytes[index];
        u32 lane_mask = index == 2U ? 0x00FFU : 0xFFFFU;
        u32 destination = (u32)(UINTPTR)output_pool2 + first_oc;
        write_layer_context(0U, &gf_conv2b_weights[first_oc * 640U], 640U, 40U,
                            &gf_conv2b_folded_bias[first_oc],
                            &gf_conv2b_requant_multiplier[first_oc],
                            &gf_conv2b_requant_right_shift[first_oc],
                            valid_bytes == 16U ? 16U : 8U);
        stage_descriptor(0U, 2U, 48U, 48U, (u32)(UINTPTR)output_conv2a,
                         GF_CONV2A_BYTES, 48U * 48U, destination,
                         24U * 24U * valid_bytes, 3U, 40U, valid_bytes,
                         lane_mask, 0U);
        Xil_Out32(GF_BASE + GF_DESC_COUNT, 1U);
        Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
        status = wait_done();
        dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
        store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
        completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
        descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
        Xil_Out32(GF_BASE + GF_DESC_SELECT, 0U);
        cycles_pool2[index] = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
        if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
            !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
            issued != 1U || completed != 1U ||
            (store_status >> 3U) != (24U * 24U * valid_bytes))
            fail(0x5250U + index, descriptor_status);
        probe_write(31U + index * 3U, cycles_pool2[index]);
        probe_write(32U + index * 3U, fnv1a(output_pool2 + first_oc, GF_POOL2_TILE_BYTES));
        probe_write(33U + index * 3U, store_status);
    }
    hash_pool2 = fnv1a(output_pool2, GF_POOL2_BYTES);
    probe_write(40U, hash_pool2);
    if (hash_pool2 != GF_POOL2_OUTPUT_FNV1A ||
        !bytes_equal(output_pool2, gf_conv3a_layer_input, GF_POOL2_BYTES))
        fail(0x5260U, hash_pool2);

    /* Real next convolution: 40 input channels -> 80 output channels. */
    for (index = 0U; index < 5U; ++index) {
        u32 first_oc = index * 16U;
        u32 destination = (u32)(UINTPTR)output_conv3a + first_oc;
        write_layer_context(0U, &gf_conv3a_weights[first_oc * 640U], 640U, 40U,
                            &gf_conv3a_folded_bias[first_oc],
                            &gf_conv3a_requant_multiplier[first_oc],
                            &gf_conv3a_requant_right_shift[first_oc], 16U);
        stage_descriptor(0U, 2U, 24U, 24U, (u32)(UINTPTR)output_pool2,
                         GF_POOL2_BYTES, 24U * 24U, destination,
                         GF_CONV3A_TILE_BYTES, 1U, 80U, 16U,
                         0xFFFFU, 0U);
        Xil_Out32(GF_BASE + GF_DESC_COUNT, 1U);
        Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
        status = wait_done();
        dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
        store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
        issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
        completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
        descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
        Xil_Out32(GF_BASE + GF_DESC_SELECT, 0U);
        cycles_conv3a[index] = Xil_In32(GF_BASE + GF_DESC_TASK_CYCLES);
        if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
            !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
            issued != 1U || completed != 1U ||
            (store_status >> 3U) != GF_CONV3A_TILE_BYTES)
            fail(0x5270U + index, descriptor_status);
        probe_write(41U + index * 3U, cycles_conv3a[index]);
        probe_write(42U + index * 3U, fnv1a(output_conv3a + first_oc, GF_CONV3A_TILE_BYTES));
        probe_write(43U + index * 3U, store_status);
    }
    hash_conv3a = fnv1a(output_conv3a, GF_CONV3A_BYTES);
    probe_write(56U, hash_conv3a);
    if (hash_conv3a != GF_CONV3A_OUTPUT_FNV1A ||
        !bytes_equal(output_conv3a, gf_conv3b_layer_input, GF_CONV3A_BYTES))
        fail(0x5280U, hash_conv3a);
    probe_write(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_DESCRIPTOR_CONV3A_CHAIN_BOARD_PASS conv1a=%08lx pool1=%08lx conv2a=%08lx conv2b=%08lx pool2=%08lx conv3a=%08lx cycles_a=%lu cycles_pool1=%lu conv2a_tiles=%lu,%lu,%lu conv2b_tiles=%lu,%lu,%lu pool2_tiles=%lu,%lu,%lu conv3a_tiles=%lu,%lu,%lu,%lu,%lu\r\n",
               (unsigned long)hash_a, (unsigned long)hash_pool1,
               (unsigned long)hash_conv2a, (unsigned long)hash_conv2b,
               (unsigned long)hash_pool2, (unsigned long)hash_conv3a,
               (unsigned long)cycles_a,
               (unsigned long)cycles_pool1, (unsigned long)cycles_conv2a[0],
               (unsigned long)cycles_conv2a[1], (unsigned long)cycles_conv2a[2],
               (unsigned long)cycles_conv2b[0], (unsigned long)cycles_conv2b[1],
               (unsigned long)cycles_conv2b[2], (unsigned long)cycles_pool2[0],
               (unsigned long)cycles_pool2[1], (unsigned long)cycles_pool2[2],
               (unsigned long)cycles_conv3a[0], (unsigned long)cycles_conv3a[1],
               (unsigned long)cycles_conv3a[2], (unsigned long)cycles_conv3a[3],
               (unsigned long)cycles_conv3a[4]);
    while (1) { }
    return 0;
}
