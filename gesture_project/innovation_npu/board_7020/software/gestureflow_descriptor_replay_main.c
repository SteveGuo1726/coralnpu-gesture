/* PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL */
/*
 * Descriptor ABI board test for the project-local GestureFlow 7020 IP.
 *
 * This is intentionally a bounded bridge test, not a full-network claim:
 * weights/bias/requant are loaded once through the compatibility registers,
 * then two identical real conv1 jobs are submitted with one descriptor
 * doorbell.  The PL must perform both DDR reads, MAC/requant and DDR writes;
 * the PS only polls completion and checks hashes.
 */
#include <stdint.h>
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"
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

static volatile u32 *const probe = (volatile u32 *)PROBE_BASE;
static uint8_t input_rgb[GF_RGB_BYTES] __attribute__((aligned(64)));
static int8_t output_a[GF_OUTPUT_BYTES] __attribute__((aligned(64)));
static int8_t output_b[GF_OUTPUT_BYTES] __attribute__((aligned(64)));

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

static void fail(u32 code, u32 observed)
{
    probe_write(0U, GF_RESULT_FAIL);
    probe_write(1U, code);
    probe_write(2U, observed);
    xil_printf("GESTUREFLOW_DESCRIPTOR_REPLAY_FAIL code=%08lx observed=%08lx\r\n",
               (unsigned long)code, (unsigned long)observed);
    while (1) { }
}

static void write_weights_once(void)
{
    u32 oc, tap, wi, packed;
    Xil_Out32(GF_BASE + GF_QCFG, 0x00038080U);
    for (oc = 0U; oc < 16U; ++oc) {
        Xil_Out32(GF_BASE + GF_BIDX, oc);
        Xil_Out32(GF_BASE + GF_BDATA, (u32)gf_full_folded_bias[oc]);
        Xil_Out32(GF_BASE + GF_RQIDX, oc);
        Xil_Out32(GF_BASE + GF_RQMULT, (u32)gf_full_requant_multiplier[oc]);
        Xil_Out32(GF_BASE + GF_RQSHIFT, (u32)gf_full_requant_right_shift[oc]);
        for (tap = 0U; tap < 16U; ++tap) {
            wi = oc * 48U + tap * 3U;
            packed = (uint32_t)(uint8_t)gf_full_weights[wi] |
                     ((uint32_t)(uint8_t)gf_full_weights[wi + 1U] << 8U) |
                     ((uint32_t)(uint8_t)gf_full_weights[wi + 2U] << 16U);
            Xil_Out32(GF_BASE + GF_WCTRL, oc | (tap << 4U));
            Xil_Out32(GF_BASE + GF_WDATA, packed);
        }
    }
}

static void stage_descriptor(u32 slot, u32 destination)
{
    Xil_Out32(GF_BASE + GF_DESC_SELECT, slot);
    Xil_Out32(GF_BASE + GF_DESC_MODE, 0U);
    Xil_Out32(GF_BASE + GF_DESC_JOB_SHAPE, (96U << 16U) | 96U);
    Xil_Out32(GF_BASE + GF_DESC_DMA_SOURCE, (u32)(UINTPTR)input_rgb);
    Xil_Out32(GF_BASE + GF_DESC_DMA_BYTES, GF_RGB_BYTES);
    Xil_Out32(GF_BASE + GF_DESC_DMA_PIXELS, 96U * 96U);
    Xil_Out32(GF_BASE + GF_DESC_STORE_DESTINATION, destination);
    Xil_Out32(GF_BASE + GF_DESC_STORE_BYTES, GF_OUTPUT_BYTES);
    Xil_Out32(GF_BASE + GF_DESC_STORE_CONTROL, 1U);
    Xil_Out32(GF_BASE + GF_DESC_STORE_STRIDE, 16U);
    Xil_Out32(GF_BASE + GF_DESC_STORE_VALID_BYTES, 16U);
    Xil_Out32(GF_BASE + GF_DESC_QCFG, 0x00038080U);
    Xil_Out32(GF_BASE + GF_DESC_LANE_MASK, 0x0000FFFFU);
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
    u32 hash_a, hash_b, ddr_hash_a, ddr_hash_b, cycles;
    u32 index;

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    Xil_SetTlbAttributes(GF_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(PROBE_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)input_rgb, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_a, DEVICE_MEMORY);
    Xil_SetTlbAttributes((UINTPTR)output_b, DEVICE_MEMORY);
    for (index = 0U; index < 8U; ++index) probe_write(index, 0U);

    if (Xil_In32(GF_BASE + GF_MAGIC) != 0x47464E50U) fail(0x5101U, Xil_In32(GF_BASE + GF_MAGIC));
    if (Xil_In32(GF_BASE + GF_VERSION) != 0x00040004U) fail(0x5102U, Xil_In32(GF_BASE + GF_VERSION));
    Xil_Out32(GF_BASE + GF_CONTROL, 1U);
    write_weights_once();
    for (index = 0U; index < GF_RGB_BYTES; ++index) input_rgb[index] = gf_full_camera_rgb[index];
    Xil_DCacheFlushRange((UINTPTR)input_rgb, GF_RGB_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_a, GF_OUTPUT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)output_b, GF_OUTPUT_BYTES);

    stage_descriptor(0U, (u32)(UINTPTR)output_a);
    stage_descriptor(1U, (u32)(UINTPTR)output_b);
    Xil_Out32(GF_BASE + GF_DESC_COUNT, 2U);
    Xil_Out32(GF_BASE + GF_DESC_CONTROL, 2U);
    status = wait_done();
    dma_status = Xil_In32(GF_BASE + GF_DMA_STATUS);
    store_status = Xil_In32(GF_BASE + GF_STORE_STATUS);
    issued = Xil_In32(GF_BASE + GF_DESC_ISSUED);
    completed = Xil_In32(GF_BASE + GF_DESC_COMPLETED);
    descriptor_status = Xil_In32(GF_BASE + GF_DESC_STATUS);
    hash_a = fnv1a(output_a, GF_OUTPUT_BYTES);
    hash_b = fnv1a(output_b, GF_OUTPUT_BYTES);
    ddr_hash_a = hash_a;
    ddr_hash_b = hash_b;
    cycles = Xil_In32(GF_BASE + GF_CYCLES);
    probe_write(1U, issued);
    probe_write(2U, completed);
    probe_write(3U, hash_a);
    probe_write(4U, hash_b);
    probe_write(5U, cycles);
    probe_write(6U, dma_status);
    probe_write(7U, store_status);
    probe_write(8U, descriptor_status);
    probe_write(9U, status);

    if (!(dma_status & GF_DMA_DONE) || (dma_status & GF_DMA_FAULT) ||
        !(store_status & GF_STORE_DONE) || (store_status & GF_STORE_FAULT) ||
        issued != 2U || completed != 2U || hash_a != GF_FULL_OUTPUT_FNV1A ||
        hash_b != GF_FULL_OUTPUT_FNV1A || ddr_hash_a != ddr_hash_b) {
        fail(0x5203U, descriptor_status);
    }
    probe_write(0U, GF_RESULT_PASS);
    xil_printf("GESTUREFLOW_DESCRIPTOR_REPLAY_BOARD_PASS issued=%lu completed=%lu hash_a=%08lx hash_b=%08lx cycles=%lu\r\n",
               (unsigned long)issued, (unsigned long)completed,
               (unsigned long)hash_a, (unsigned long)hash_b, (unsigned long)cycles);
    while (1) { }
    return 0;
}
