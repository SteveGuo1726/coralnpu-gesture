/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * GestureFlow HaGRID-18 DMP NPU -- Linux userspace driver (ZCU104).
 *
 * Port of board_7020/software/gestureflow_hagrid18_dmp_main.c to Linux
 * userspace.  The register protocol, weight staging and tile schedule are
 * carried over unchanged -- only the memory acquisition (mmap instead of static
 * arrays in DDR) and the timing source differ.
 *
 * Deliberately NOT carried over: the baremetal driver's dead helpers
 * (load_first_layer, load_head1x1_tile, config_first_params, config_head_params,
 * run_layer, wait_input_loaded, verify_full_tensor).  Verified unused by call
 * counting: each had exactly one occurrence in the file, its own definition.
 *
 * Memory:
 *   registers  0xA0000000..0xA00FFFFF  via /dev/mem  (non-cached)
 *   scratch    0x70000000..0x70FFFFFF  via /dev/mem  (non-cached, reserved-memory
 *                                      with no-map, so outside System RAM)
 * Because both sides of the HP0 link see plain non-cached memory, there is no
 * cache flush or invalidate anywhere in this file.  If a future change makes the
 * scratch buffer cacheable, that invariant breaks and cache maintenance must be
 * reintroduced.
 */
#include "gf_npu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <stdint.h>
#include <sys/mman.h>

/* ------------------------------------------------------------------------- *
 * Weight / parameter data.
 *
 * The include list and order must match the baremetal driver exactly: some
 * macros (notably GF_FULL_OUTPUT_FNV1A) are defined in more than one generated
 * header, and the last include wins.  Reordering would silently change the
 * expected checksums.
 * ------------------------------------------------------------------------- */
#include "gestureflow_real_conv4x4_full_layer.h"
#include "gestureflow_dmp_full_layer.h"
#include "gestureflow_chain_body_data.h"
#include "gestureflow_dmp_body2_layer.h"
#include "gestureflow_real_maxpool2d.h"
#include "gestureflow_real_conv4x4_conv2a_layer.h"
#include "gestureflow_dmp_conv2a_layer.h"
#include "gestureflow_real_conv4x4_conv2b_layer.h"
#include "gestureflow_dmp_conv2b_layer.h"
#include "gestureflow_real_maxpool2d_pool2.h"
#include "gestureflow_real_conv4x4_conv3a_layer.h"
#include "gestureflow_dmp_conv3a_layer.h"
#include "gestureflow_real_conv4x4_conv3b_layer.h"
#include "gestureflow_dmp_conv3b_layer.h"
#include "gestureflow_real_maxpool2d_pool3.h"
#include "gestureflow_real_conv4x4_head1x1_layer.h"
#include "gestureflow_dmp_head1x1_layer.h"
#include "gestureflow_real_gap_fc.h"

/* ----------------------------------------------------------------- sizes -- */
#define GF_ACTIVATION_BYTES   (96U * 96U * 16U)     /* 147456 */
#define GF_POOL1_BYTES        GF_POOL_OUTPUT_BYTES  /*  36864 */
#define GF_CONV2_BYTES        (48U * 48U * 32U)     /*  73728 */
#define GF_CONV2_TILE_BYTES   (48U * 48U * 16U)     /*  36864 */
#define GF_CONV3_BYTES        (48U * 48U * 32U)     /*  73728 */
#define GF_POOL2_TILE_BYTES   (24U * 24U * 16U)     /*   9216 */
#define GF_POOL2_BYTES        GF_POOL2_OUTPUT_BYTES /*  18432 */
#define GF_CONV4_BYTES        (24U * 24U * 48U)     /*  27648 */
#define GF_CONV4_TILE_BYTES   (24U * 24U * 16U)     /*   9216 */
#define GF_CONV5_BYTES        (24U * 24U * 48U)     /*  27648 */
#define GF_POOL3_TILE_BYTES   (12U * 12U * 16U)     /*   2304 */
#define GF_POOL3_BYTES        GF_POOL3_OUTPUT_BYTES /*   6912 */
#define GF_HEAD1X1_BYTES      (12U * 12U * 64U)     /*   9216 */
#define GF_HEAD1X1_TILE_BYTES (12U * 12U * 16U)     /*   2304 */

#define GF_POLL_LIMIT         12000000U

/* --------------------------------------------------------------- state ---- */
static volatile uint32_t *g_regs = NULL;
static uint8_t           *g_bufs = NULL;
static int                g_devmem_fd = -1;

static uint8_t *g_arena_cur = NULL;
static uint8_t *g_arena_end = NULL;

/* Scratch buffers (all inside g_bufs, so their physical addresses are derivable
 * from the pointer). */
static uint8_t  *g_in_rgb   = NULL;
static int8_t   *g_act1     = NULL;
static int8_t   *g_pool1    = NULL;
static int8_t   *g_conv2    = NULL;
static int8_t   *g_conv3    = NULL;
static int8_t   *g_pool2    = NULL;
static int8_t   *g_conv4    = NULL;
static int8_t   *g_conv5    = NULL;
static int8_t   *g_pool3    = NULL;
static int8_t   *g_head1x1  = NULL;

/* Weight images, copied into the scratch region at load time because the NPU
 * DMAs them by physical address. */
static uint32_t *g_w_full      = NULL;
static uint32_t *g_w_body2     = NULL;
static uint32_t *g_w_conv2a    = NULL;
static uint32_t *g_w_conv2b    = NULL;
static uint32_t *g_w_conv3a    = NULL;
static uint32_t *g_w_conv3b    = NULL;
static uint32_t *g_w_head1x1   = NULL;

/* Failure reporting: helpers record the first failure and later steps bail out,
 * which mirrors the baremetal terminal_failure() control flow without longjmp. */
static int    g_fail = 0;
static char   g_fail_msg[256];

static void gf_fail(uint32_t code, uint32_t observed)
{
    if (g_fail) return;
    g_fail = 1;
    snprintf(g_fail_msg, sizeof g_fail_msg,
             "stage 0x%04X observed 0x%08X (see GF_STATUS/DMA_STATUS/STORE_STATUS above)",
             (unsigned)code, (unsigned)observed);
    fprintf(stderr, "gf_npu: FAIL %s\n", g_fail_msg);
}

/* --------------------------------------------------------------- helpers -- */
#define REG(off)  (g_regs[(uint32_t)(off) >> 2])

/* Memory barrier for the CPU <-> PL handshake.
 *
 * The scratch region is mapped Normal-Non-Cacheable (see the long note in
 * gf_npu.h), which means it needs no cache maintenance but IS weakly ordered:
 * a store into it may still be sitting in a write buffer when the following
 * MMIO doorbell write becomes visible to the PL.  The PL would then DMA a
 * half-written buffer, giving results that are wrong in a way that looks like
 * a model bug.
 *
 * Two barriers per handshake are needed, and they are not symmetric:
 *   - before ringing the doorbell: all buffer stores must be *complete* before
 *     the control write is observed.  Full DSB, not DMB: the PL is not an
 *     observer in the CPU's shareability domain, so we need the accesses to
 *     have reached DDR, not merely to be ordered.
 *   - after the PL reports done, before reading the buffer back: the CPU must
 *     not have consumed the buffer speculatively.
 *
 * This is the standard store-then-doorbell / done-then-load pair that the Arm
 * architecture requires for a non-coherent DMA-style handshake.  It is also
 * what the baremetal driver did NOT need, because Xil_SetTlbAttributes() put
 * its buffers in Device memory.  Cost is a few hundred nanoseconds per layer,
 * which is ~1 us per frame against a 27 ms frame -- not measurable here.
 */
#if defined(__aarch64__) || defined(__arm__)
#  define GF_MB()  __asm__ __volatile__("dsb sy" ::: "memory")
#else
#  define GF_MB()  __sync_synchronize()
#endif

/* ---------------------------------------------------- scratch region I/O -- *
 * Bulk accessors for the scratch region.
 *
 * These look gratuitous -- why not just memcpy/memset/memcmp? -- but the
 * region's CPU mapping is not one fixed thing, and the *other* possibility is
 * more restrictive than the one in the current device tree:
 *
 *   reserved-memory without no-map + O_SYNC   -> MT_NORMAL_NC  (any width fine)
 *   range cut out of the memory node          -> MT_DEVICE_nGnRnE, where the
 *                                                architecture only defines
 *                                                accesses of 64 bits or less
 *
 * glibc happily uses DC ZVA and 128-bit STP/LDP for a large memset/memcpy/memcmp,
 * which on Device memory raises a synchronous abort -> a bare SIGBUS with no
 * kernel log and no other clue.  Doing the copies 32 bits at a time costs a few
 * microseconds per frame and makes this driver correct under *either* mapping,
 * which is worth far more than the cycles: it means the driver no longer
 * depends on getting the device tree exactly right.
 *
 * 32-bit accesses are always legal on Device-nGnRnE.  Aligned ones are required,
 * so the helpers check the alignment and fall back to bytes if it is ever off.
 * Everything is accessed through `volatile` so the compiler cannot widen a loop
 * back into a vector load/store behind our backs.
 */
static void gf_copy(uint8_t *dst, const uint8_t *src, size_t bytes)
{
    size_t i = 0U;
    if (((uintptr_t)dst & 3U) == 0U) {
        for (; i + 4U <= bytes; i += 4U) {
            uint32_t w;
            memcpy(&w, src + i, 4U);        /* src is ordinary memory */
            *(volatile uint32_t *)(void *)(dst + i) = w;
        }
    }
    for (; i < bytes; ++i) *(volatile uint8_t *)(void *)(dst + i) = src[i];
}

static void gf_zero(uint8_t *dst, size_t bytes)
{
    size_t i = 0U;
    if (((uintptr_t)dst & 3U) == 0U) {
        for (; i + 4U <= bytes; i += 4U) *(volatile uint32_t *)(void *)(dst + i) = 0U;
    }
    for (; i < bytes; ++i) *(volatile uint8_t *)(void *)(dst + i) = 0U;
}

/* Byte-wise compare; returns 0 when equal (memcmp convention).  Byte accesses
 * are legal on Device memory, so no alignment constraint applies. */
static int gf_diff(const volatile uint8_t *a, const uint8_t *b, size_t bytes, size_t *first)
{
    size_t i;
    for (i = 0U; i < bytes; ++i) {
        if ((uint8_t)a[i] != b[i]) { if (first) *first = i; return -1; }
    }
    return 0;
}

static void *buf_alloc(size_t bytes, size_t align)
{
    uintptr_t p = ((uintptr_t)g_arena_cur + (align - 1U)) & ~(uintptr_t)(align - 1U);
    if (p + bytes > (uintptr_t)g_arena_end) return NULL;
    g_arena_cur = (uint8_t *)(p + bytes);
    return (void *)p;
}

static uint32_t buf_phys(const void *p)
{
    return (uint32_t)(GF_BUF_PHYS_BASE + (uintptr_t)((const uint8_t *)p - g_bufs));
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

static uint32_t fnv1a(const void *data, size_t count)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t value = 0x811C9DC5U;
    size_t i;
    for (i = 0U; i < count; ++i) {
        value = (value ^ (uint32_t)p[i]) * 0x01000193U;
    }
    return value;
}

/* ---------------------------------------------------- content verification -- *
 * Every stage's stored tensor is compared byte-for-byte against the golden
 * array the exporter emitted next to that layer's weights.  This is stronger
 * than what the baremetal driver did -- it only checked DMA byte counts for
 * these six stages, and checked FNV registers for two of them.
 *
 * Which golden array belongs to which stage was established empirically by
 * computing FNV1A over each exported array and matching the header macros:
 *
 *   stage   stored tensor bytes   golden array                 golden FNV1A
 *   conv0   96x96x16   = 147456   gf_body2_layer_input         05307466  = GF_FULL_OUTPUT_FNV1A
 *   pool1   48x48x16   =  36864   gf_pool_output               33B1A130  = GF_POOL_OUTPUT_FNV1A
 *   conv2   48x48x32   =  73728   gf_conv2b_layer_input        90D6DF2F  = GF_CONV2A_OUTPUT_FNV1A
 *   pool2   24x24x32   =  18432   gf_pool2_output              8439E9C9  = GF_POOL2_OUTPUT_FNV1A
 *   conv4   24x24x48   =  27648   gf_conv3b_layer_input        591D321E  = GF_CONV3A_OUTPUT_FNV1A
 *   pool3   12x12x16   =   6912   gf_pool3_output              D10D7766  = GF_POOL3_OUTPUT_FNV1A
 *
 * Worth knowing, because it is easy to misread: the hardware GF_OUTPUT_FNV1A
 * register does NOT report the stored pooled tensor for a fused conv+pool
 * layer.  After conv1 it reads GF_BODY2_OUTPUT_FNV1A = GF_POOL_INPUT_FNV1A =
 * 0x7E276C7B, which is the FNV of the *pre-pool* conv output, not of
 * gf_pool_output (0x33B1A130).  The baremetal driver's check is therefore on the
 * MAC output stream, and the models tile's pooled result is verified here
 * instead.
 * --------------------------------------------------------------------------- */

const char *const gf_npu_check_name[GF_CHK_COUNT] = {
    "conv0", "pool1", "conv2", "pool2", "conv4", "pool3"
};

/* Returns 0 on bit-exact match, -1 otherwise.  `stats` may be NULL, in which
 * case the check is skipped entirely -- that is the fast path used by the live
 * camera loop, where a full-tensor memcmp on uncached memory every frame would
 * dominate the CPU-side budget being measured. */
static int verify_tensor(gf_npu_stats *stats, int chk, const int8_t *buf,
                         size_t bytes, const int8_t *golden, const char *golden_name,
                         uint32_t *out_fnv, double *checks_ms)
{
    double t0, t1;
    size_t i;
    int rc = 0;
    uint32_t got;

    if (g_fail || !stats) return 0;

    t0 = now_ms();
    got = fnv1a(buf, bytes);
    /* gf_diff, not memcmp: `buf` lives in the scratch region, and memcmp would
     * use 128-bit loads that are illegal if that region is Device-mapped. */
    if (gf_diff((const volatile uint8_t *)buf, (const uint8_t *)golden,
                bytes, &i) != 0) {
        fprintf(stderr,
                "gf_npu: CONTENT MISMATCH  %-6s vs %s\n"
                "        first difference at byte %zu of %zu: got %d, golden %d\n"
                "        FNV1A got %08X, golden %08X\n",
                (chk >= 0 && chk < GF_CHK_COUNT) ? gf_npu_check_name[chk] : "?",
                golden_name, i, bytes, (int)buf[i], (int)golden[i],
                (unsigned)got, (unsigned)fnv1a(golden, bytes));
        rc = -1;
    }
    t1 = now_ms();
    if (checks_ms) *checks_ms += (t1 - t0);

    if (chk >= 0 && chk < GF_CHK_COUNT) stats->content_rc[chk] = (int8_t)rc;
    stats->content_checked++;
    if (rc != 0) stats->content_failed++;
    if (out_fnv) *out_fnv = got;
    return rc;
}

/* ------------------------------------------------------------- tile core -- */
static void wait_layer_done(void)
{
    uint32_t poll, status = 0U, first_bad = 0U;
    if (g_fail) return;
    for (poll = 0U; poll < GF_POLL_LIMIT; ++poll) {
        status = REG(GF_STATUS);
        if (status & (GF_FAULT_BIT | GF_LAYER_FAULT_BIT)) {
            if (first_bad == 0U) first_bad = status;
            gf_fail(0x4001U, first_bad);
            return;
        }
        if ((status & GF_DONE_BIT) && !(status & GF_RUNNING_BIT)) {
            /* The PL has finished writing the destination tensor.  Order the
             * subsequent reads of that tensor after the observation of DONE so
             * the CPU cannot consume a partially written buffer. */
            GF_MB();
            return;
        }
    }
    gf_fail(0x4002U, status);
}

static void weight_dma_load(const uint32_t *src, uint32_t words, uint32_t taps,
                            uint32_t groups, uint32_t output_lanes, double *acc_ms)
{
    uint32_t status;
    uint32_t bytes = words * 4U;
    double t0, t1;

    if (g_fail) return;

    /* src already lives in the non-cached scratch region, so no cache flush is
     * needed -- but the stores that put it there must have reached DDR before
     * the PL is told to DMA from it. */
    REG(GF_WEIGHT_DMA_SOURCE)  = buf_phys(src);
    REG(GF_WEIGHT_DMA_BYTES)   = bytes;
    REG(GF_WEIGHT_DMA_CFG)     = taps | (groups << 8U) | (output_lanes << 16U);
    GF_MB();
    REG(GF_WEIGHT_DMA_CONTROL) = 2U;

    t0 = now_ms();
    do {
        status = REG(GF_WEIGHT_DMA_STATUS);
    } while (status & GF_WEIGHT_DMA_BUSY_BIT);
    t1 = now_ms();
    if (acc_ms) *acc_ms += (t1 - t0);

    if (!(status & GF_WEIGHT_DMA_DONE_BIT) || (status & GF_WEIGHT_DMA_FAULT_BIT)) {
        gf_fail(0x4D01U, status);
    }
}

static void set_weight_write_bank(uint32_t bank) { REG(GF_WEIGHT_BANK_SELECT) = bank & 1U; }
static void set_weight_read_bank(uint32_t bank)  { REG(GF_WEIGHT_READ_BANK_SELECT) = bank & 1U; }
static void set_param_bank(uint32_t bank)        { REG(GF_PARAM_BANK_SELECT) = bank & 1U; }

static void config_tile_control(uint32_t mode, uint32_t lane_mask)
{
    REG(GF_LAYER_MODE)        = mode;
    REG(GF_QCFG)              = GF_QCFG_VALUE;
    REG(GF_OUTPUT_LANE_MASK)  = lane_mask;
}

static void config_tile_params(uint32_t first_oc, const int32_t *folded_bias,
                               const int32_t *multiplier, const uint8_t *right_shift,
                               uint32_t output_lanes, uint32_t tile_lanes)
{
    uint32_t physical_oc, model_oc;
    for (physical_oc = 0U; physical_oc < 32U; ++physical_oc) {
        model_oc = first_oc + physical_oc;
        if (physical_oc >= tile_lanes || model_oc >= output_lanes) {
            REG(GF_BIDX) = physical_oc;   REG(GF_BDATA) = 0U;
            REG(GF_RQIDX) = physical_oc;  REG(GF_RQMULT) = 0U;  REG(GF_RQSHIFT) = 0U;
            continue;
        }
        REG(GF_BIDX) = physical_oc;   REG(GF_BDATA) = (uint32_t)folded_bias[model_oc];
        REG(GF_RQIDX) = physical_oc;  REG(GF_RQMULT) = (uint32_t)multiplier[model_oc];
        REG(GF_RQSHIFT) = (uint32_t)right_shift[model_oc];
    }
}

/* DMP weight images are pair-major: (pair, tap, group, 6 words). */
static void preload_conv_tile(const uint32_t *dma_weights, uint32_t first_oc,
                              uint32_t groups, uint32_t tile_lanes, double *acc_ms)
{
    uint32_t first_pair = first_oc >> 1U;
    uint32_t pairs = tile_lanes >> 1U;
    weight_dma_load(dma_weights + first_pair * 16U * groups * 6U,
                    pairs * 16U * groups * 6U, 16U, groups, tile_lanes, acc_ms);
}

static void preload_head1x1_tile(uint32_t first_oc, double *acc_ms)
{
    uint32_t first_pair = first_oc >> 1U;
    weight_dma_load(g_w_head1x1 + first_pair * 6U * 6U,
                    8U * 6U * 6U, 1U, 6U, 16U, acc_ms);
}

static void launch_layer(uint32_t mode, uint32_t source, uint32_t bytes,
                         uint32_t destination, uint32_t store_bytes,
                         uint32_t store_control, uint32_t width, uint32_t height,
                         uint32_t stride_bytes, uint32_t valid_bytes)
{
    REG(GF_LAYER_MODE)        = mode;
    REG(GF_DMA_SOURCE)        = source;
    REG(GF_DMA_BYTES)         = bytes;
    REG(GF_DMA_PIXELS)        = width * height;
    REG(GF_JOB_WIDTH)         = width;
    REG(GF_JOB_HEIGHT)        = height;
    REG(GF_STORE_DESTINATION) = destination;
    REG(GF_STORE_BYTES)       = store_bytes;
    REG(GF_STORE_STRIDE)      = stride_bytes;
    REG(GF_STORE_VALID_BYTES) = valid_bytes;
    REG(GF_STORE_CONTROL)     = store_control;
    /* Doorbell: the PL's input loader will DMA from `source` as soon as it
     * sees this.  Everything written to the scratch region for this layer --
     * in particular the per-frame copy of the input image -- must already be
     * in DDR. */
    GF_MB();
    REG(GF_CONTROL)           = 2U;
}

static void check_store_bytes(uint32_t expected, uint32_t code)
{
    uint32_t store_status = REG(GF_STORE_STATUS);
    if ((store_status & GF_STORE_FAULT_BIT) || !(store_status & GF_STORE_DONE_BIT) ||
        GF_STORE_BYTES_WRITTEN(store_status) != expected) {
        gf_fail(code, store_status);
    }
}

static void check_input_bytes(uint32_t expected, uint32_t code)
{
    uint32_t dma_status = REG(GF_DMA_STATUS);
    if ((dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != expected) {
        gf_fail(code, dma_status);
    }
}

/* Load and run one 16-output DMP tile; returns the tile's PL cycle count. */
static uint32_t exec_conv_tile(uint32_t mode, uint32_t source, uint32_t source_bytes,
                               uint32_t destination, uint32_t store_bytes,
                               uint32_t store_control, uint32_t width, uint32_t height,
                               uint32_t stride_bytes, uint32_t first_oc,
                               const uint32_t *dma_weights, const int32_t *folded_bias,
                               const int32_t *multiplier, const uint8_t *right_shift,
                               uint32_t output_lanes, uint32_t groups, uint32_t tile_lanes,
                               double *acc_ms)
{
    uint32_t bank = first_oc & 1U;

    if (g_fail) return 0U;

    REG(GF_CONTROL) = 1U;
    set_param_bank(bank);
    config_tile_control(mode, 0xffffU);
    set_weight_write_bank(bank);
    set_weight_read_bank(bank);
    if (mode == 5U) preload_head1x1_tile(first_oc, acc_ms);
    else            preload_conv_tile(dma_weights, first_oc, groups, tile_lanes, acc_ms);
    config_tile_params(first_oc, folded_bias, multiplier, right_shift, output_lanes, tile_lanes);
    launch_layer(mode, source, source_bytes, destination + first_oc, store_bytes,
                 store_control, width, height, stride_bytes, 16U);
    wait_layer_done();
    return REG(GF_CYCLES);
}

static void load_gap_fc_descriptor(void)
{
    uint32_t class_index, group, lane, packed;
    REG(GF_LAYER_MODE)   = 4U;
    REG(GF_POST_GAP_MULT) = (uint32_t)GF_POST_GAP_MULTIPLIER;
    REG(GF_POST_GAP_SHIFT) = GF_POST_GAP_RIGHT_SHIFT;
    REG(GF_POST_QCFG) = ((uint32_t)(uint8_t)GF_POST_GAP_INPUT_ZERO_POINT) |
                        ((uint32_t)(uint8_t)GF_POST_GAP_OUTPUT_ZERO_POINT << 8U) |
                        ((uint32_t)(uint8_t)GF_POST_FC_OUTPUT_ZERO_POINT << 16U);
    for (class_index = 0U; class_index < GF_POST_FC_OUTPUTS; ++class_index) {
        REG(GF_BIDX) = class_index;
        REG(GF_BDATA) = (uint32_t)gf_post_fc_folded_bias[class_index];
        REG(GF_RQIDX) = class_index;
        REG(GF_RQMULT) = (uint32_t)gf_post_fc_requant_multiplier[class_index];
        REG(GF_RQSHIFT) = (uint32_t)gf_post_fc_requant_right_shift[class_index];
        for (group = 0U; group < GF_POST_GAP_CHANNELS / 4U; ++group) {
            packed = 0U;
            for (lane = 0U; lane < 4U; ++lane) {
                packed |= (uint32_t)(uint8_t)gf_post_fc_weights[
                              class_index * GF_POST_GAP_CHANNELS + group * 4U + lane] << (lane * 8U);
            }
            REG(GF_WCTRL) = class_index | (group << 9U);
            REG(GF_WDATA) = packed;
        }
    }
}

static uint32_t run_gap_fc(uint32_t source)
{
    REG(GF_LAYER_MODE)    = 4U;
    REG(GF_DMA_SOURCE)    = source;
    REG(GF_DMA_BYTES)     = GF_HEAD1X1_BYTES;
    REG(GF_DMA_PIXELS)    = GF_POST_GAP_ELEMENTS;
    REG(GF_STORE_CONTROL) = 0U;
    GF_MB();                      /* head1x1 tensor must be in DDR first */
    REG(GF_CONTROL)       = 2U;
    wait_layer_done();
    return REG(GF_POST_CYCLES_REG);
}

/* ------------------------------------------------------------- open/close -- */
static void *map_phys(uint32_t phys, size_t size, const char *what)
{
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, g_devmem_fd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "gf_npu: mmap %s at 0x%08X (%zu bytes) failed: %s\n",
                what, (unsigned)phys, size, strerror(errno));
        return NULL;
    }
    return p;
}

int gf_npu_open(void)
{
    if (g_regs) return 0;
    g_fail = 0;
    g_fail_msg[0] = '\0';

    g_devmem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_devmem_fd < 0) {
        fprintf(stderr, "gf_npu: open /dev/mem failed: %s\n", strerror(errno));
        fprintf(stderr, "        (needs root; CONFIG_DEVMEM=y)\n");
        return -1;
    }

    /* Progress markers on stderr (unbuffered, so they survive a hard fault).
     * A SIGBUS in here is otherwise completely silent: the first printf only
     * happens at the very end.  Keep these until the port is proven. */
#define GF_DBG(tag, ...) do { fprintf(stderr, "gf_npu[DBG] " tag "\n", ##__VA_ARGS__); } while (0)

    g_regs = (volatile uint32_t *)map_phys(GF_REG_PHYS_BASE, GF_REG_SIZE, "registers");
    if (!g_regs) return -1;
    GF_DBG("[1] regs mapped  %p", (void *)g_regs);
    g_bufs = (uint8_t *)map_phys(GF_BUF_PHYS_BASE, GF_BUF_SIZE, "scratch buffers");
    if (!g_bufs) return -1;
    GF_DBG("[2] bufs mapped  %p", (void *)g_bufs);

    GF_DBG("[3] read GF_MAGIC   = 0x%08X", (unsigned)REG(GF_MAGIC));
    if (REG(GF_MAGIC) != GF_MAGIC_VALUE) {
        fprintf(stderr, "gf_npu: GF_MAGIC = 0x%08X, expected 0x%08X.\n"
                        "        The PL is not configured, or its clock is gated.\n",
                (unsigned)REG(GF_MAGIC), (unsigned)GF_MAGIC_VALUE);
        return -1;
    }
    GF_DBG("[4] read GF_VERSION = 0x%08X", (unsigned)REG(GF_VERSION));
    if (REG(GF_VERSION) != GF_VERSION_VALUE) {
        fprintf(stderr, "gf_npu: GF_VERSION = 0x%08X, expected 0x%08X (bitstream/driver mismatch).\n",
                (unsigned)REG(GF_VERSION), (unsigned)GF_VERSION_VALUE);
        return -1;
    }

    /* Sanity: the scratch region must be readable and writable as plain memory.
     * A stuck pattern here would mean the mapping is not what we expect. */
    {
        volatile uint32_t *probe = (volatile uint32_t *)g_bufs;
        GF_DBG("[5] scratch read ...");
        uint32_t saved = probe[0];
        GF_DBG("[6] scratch read ok (0x%08X), write 0xA5A5A5A5 ...", (unsigned)saved);
        probe[0] = 0xA5A5A5A5U;
        if (probe[0] != 0xA5A5A5A5U) {
            fprintf(stderr, "gf_npu: scratch region at 0x%08X is not writable.\n",
                    (unsigned)GF_BUF_PHYS_BASE);
            return -1;
        }
        GF_DBG("[7] scratch write/readback ok");
        probe[0] = saved;
    }

    GF_DBG("[8] clearing scratch: gf_zero(%u bytes) ...", (unsigned)GF_BUF_SIZE);
    gf_zero(g_bufs, GF_BUF_SIZE);
    GF_DBG("[9] scratch cleared");
    printf("gf_npu: PL id ok (MAGIC 0x%08X, VERSION 0x%08X); scratch 0x%08X + %u MiB\n",
           (unsigned)GF_MAGIC_VALUE, (unsigned)GF_VERSION_VALUE,
           (unsigned)GF_BUF_PHYS_BASE, (unsigned)(GF_BUF_SIZE >> 20));
    return 0;
}

void gf_npu_close(void)
{
    if (g_bufs)  { munmap((void *)g_bufs, GF_BUF_SIZE); g_bufs = NULL; }
    if (g_regs)  { munmap((void *)g_regs, GF_REG_SIZE); g_regs = NULL; }
    if (g_devmem_fd >= 0) { close(g_devmem_fd); g_devmem_fd = -1; }
    g_arena_cur = g_arena_end = NULL;
}

/* --------------------------------------------------------- weight staging -- */
static int copy_weights(void)
{
    struct { void **dst; const void *src; size_t bytes; const char *name; } tbl[] = {
        { (void **)&g_w_full,    gf_dmp_full_weights_dma,    sizeof gf_dmp_full_weights_dma,    "conv0"   },
        { (void **)&g_w_body2,   gf_dmp_body2_weights_dma,   sizeof gf_dmp_body2_weights_dma,   "conv1"   },
        { (void **)&g_w_conv2a,  gf_dmp_conv2a_weights_dma,  sizeof gf_dmp_conv2a_weights_dma,  "conv2a"  },
        { (void **)&g_w_conv2b,  gf_dmp_conv2b_weights_dma,  sizeof gf_dmp_conv2b_weights_dma,  "conv2b"  },
        { (void **)&g_w_conv3a,  gf_dmp_conv3a_weights_dma,  sizeof gf_dmp_conv3a_weights_dma,  "conv3a"  },
        { (void **)&g_w_conv3b,  gf_dmp_conv3b_weights_dma,  sizeof gf_dmp_conv3b_weights_dma,  "conv3b"  },
        { (void **)&g_w_head1x1, gf_dmp_head1x1_weights_dma, sizeof gf_dmp_head1x1_weights_dma, "head1x1" },
    };
    size_t i;

    for (i = 0U; i < sizeof tbl / sizeof tbl[0]; ++i) {
        void *p = buf_alloc(tbl[i].bytes, 64U);
        if (!p) {
            fprintf(stderr, "gf_npu: scratch region too small for weight image '%s'\n", tbl[i].name);
            return -1;
        }
        gf_copy((uint8_t *)p, (const uint8_t *)tbl[i].src, tbl[i].bytes);
        *tbl[i].dst = p;
    }
    return 0;
}

int gf_npu_load_weights(void)
{
    /* Upper bound on what the arena must hold: every weight image plus every
     * tensor, with alignment slack.  Checked here so that a future tensor
     * outgrowing the device-tree reserved-memory size fails loudly instead of
     * silently walking off the mapping. */
    const size_t bytes_needed =
        sizeof gf_dmp_full_weights_dma + sizeof gf_dmp_body2_weights_dma +
        sizeof gf_dmp_conv2a_weights_dma + sizeof gf_dmp_conv2b_weights_dma +
        sizeof gf_dmp_conv3a_weights_dma + sizeof gf_dmp_conv3b_weights_dma +
        sizeof gf_dmp_head1x1_weights_dma +
        (10U * 4096U) +                       /* 10 tensors, 4 KiB alignment each */
        GF_RGB_BYTES + GF_ACTIVATION_BYTES + GF_POOL1_BYTES +
        GF_CONV2_BYTES + GF_CONV3_BYTES + GF_POOL2_BYTES +
        GF_CONV4_BYTES + GF_CONV5_BYTES + GF_POOL3_BYTES +
        GF_HEAD1X1_BYTES;

    if (!g_bufs) return -1;

    if (bytes_needed > (size_t)GF_BUF_SIZE) {
        fprintf(stderr,
                "gf_npu: device-tree scratch region too small: need %zu bytes, "
                "have %u.\n        Widen the reserved-memory node in system-user.dtsi.\n",
                bytes_needed, (unsigned)GF_BUF_SIZE);
        return -1;
    }

    g_arena_cur = g_bufs;
    g_arena_end = g_bufs + GF_BUF_SIZE;

    /* Weights first, then the activation pool. */
    if (copy_weights() != 0) return -1;

    g_in_rgb  = buf_alloc(GF_RGB_BYTES,        4096U);
    g_act1    = buf_alloc(GF_ACTIVATION_BYTES, 4096U);
    g_pool1   = buf_alloc(GF_POOL1_BYTES,      4096U);
    g_conv2   = buf_alloc(GF_CONV2_BYTES,      4096U);
    g_conv3   = buf_alloc(GF_CONV3_BYTES,      4096U);
    g_pool2   = buf_alloc(GF_POOL2_BYTES,      4096U);
    g_conv4   = buf_alloc(GF_CONV4_BYTES,      4096U);
    g_conv5   = buf_alloc(GF_CONV5_BYTES,      4096U);
    g_pool3   = buf_alloc(GF_POOL3_BYTES,      4096U);
    g_head1x1 = buf_alloc(GF_HEAD1X1_BYTES,    4096U);

    if (!g_head1x1 || !g_in_rgb || !g_act1 || !g_pool1 || !g_conv2 || !g_conv3 ||
        !g_pool2 || !g_conv4 || !g_conv5 || !g_pool3) {
        fprintf(stderr, "gf_npu: scratch region too small for the activation pool\n");
        return -1;
    }

    /* Zero the activation pool ONCE, here -- deliberately NOT per frame.
     *
     * The tiles cover their regions exactly (conv0 1x147456, conv1 1x36864,
     * conv2a 2x36864, conv2b 2x9216, conv3a 3x9216, conv3b 3x2304, head
     * 4x2304), and gf_npu_run_frame asserts the store byte counts, so
     * per-frame zeroing is not needed for correctness.  It would however cost
     * ~435 KB of *uncached* writes every frame -- precisely the class of
     * CPU-side overhead this port exists to measure -- and would corrupt the
     * V4 comparison against the baremetal 10.04 ms.  The baremetal driver did
     * not zero either.  (Zeroing must not touch the weight images, which sit
     * earlier in the same arena.)
     *
     * GF_CONV3 / GF_CONV5 are unused scratch in the current schedule; they are
     * zeroed for a deterministic initial state only. */
    gf_zero(g_in_rgb,  GF_RGB_BYTES);
    gf_zero((uint8_t *)g_act1,    GF_ACTIVATION_BYTES);
    gf_zero((uint8_t *)g_pool1,   GF_POOL1_BYTES);
    gf_zero((uint8_t *)g_conv2,   GF_CONV2_BYTES);
    gf_zero((uint8_t *)g_conv3,   GF_CONV3_BYTES);
    gf_zero((uint8_t *)g_pool2,   GF_POOL2_BYTES);
    gf_zero((uint8_t *)g_conv4,   GF_CONV4_BYTES);
    gf_zero((uint8_t *)g_conv5,   GF_CONV5_BYTES);
    gf_zero((uint8_t *)g_pool3,   GF_POOL3_BYTES);
    gf_zero((uint8_t *)g_head1x1, GF_HEAD1X1_BYTES);

    printf("gf_npu: staged weights + activations, %u bytes used of %u MiB\n",
           (unsigned)(g_arena_cur - g_bufs), (unsigned)(GF_BUF_SIZE >> 20));
    printf("gf_npu: buffer phys: rgb=0x%08X act1=0x%08X pool1=0x%08X conv2=0x%08X "
           "conv3=0x%08X pool2=0x%08X conv4=0x%08X conv5=0x%08X pool3=0x%08X head=0x%08X\n",
           (unsigned)buf_phys(g_in_rgb), (unsigned)buf_phys(g_act1), (unsigned)buf_phys(g_pool1),
           (unsigned)buf_phys(g_conv2), (unsigned)buf_phys(g_conv3), (unsigned)buf_phys(g_pool2),
           (unsigned)buf_phys(g_conv4), (unsigned)buf_phys(g_conv5), (unsigned)buf_phys(g_pool3),
           (unsigned)buf_phys(g_head1x1));
    return 0;
}

/* ------------------------------------------------------------------- run -- */
int gf_npu_run_frame(const uint8_t *rgb96, uint32_t *out_class, gf_npu_stats *stats)
{
    uint32_t index, status, dma_status, hash;
    uint32_t cycles0, pool_cycles, gap_fc_cycles;
    uint32_t conv2_cycles[2] = {0U}, pool2_cycles[2] = {0U};
    uint32_t conv4_cycles[3] = {0U}, pool3_cycles[3] = {0U};
    uint32_t head1x1_cycles[4] = {0U};
    uint32_t gap_fnv, fc_fnv, post_class, post_progress;
    double t_start, t_end, weight_ms = 0.0, checks_ms = 0.0;

    if (!g_regs || !g_head1x1) return -1;
    if (!rgb96) { fprintf(stderr, "gf_npu: null input\n"); return -1; }

    g_fail = 0;
    g_fail_msg[0] = '\0';
    t_start = now_ms();

    /* Raw uint8 pixels.  The PL recenters to q = u - 128 itself (see the note
     * at the top of this file) -- do NOT subtract 128 here.
     *
     * Deliberately no per-frame zeroing of the intermediate tensors: it would be
     * ~435 KB of uncached writes and would show up as CPU overhead in the very
     * measurement V4 is about.  The tiles overwrite their regions completely
     * and that is asserted by the byte-count checks below. */
    gf_copy(g_in_rgb, rgb96, GF_RGB_BYTES);

    /* conv0: 3 -> 16 */
    cycles0 = exec_conv_tile(0U, buf_phys(g_in_rgb), GF_RGB_BYTES, buf_phys(g_act1),
                             GF_ACTIVATION_BYTES, 1U, 96U, 96U, 16U, 0U,
                             g_w_full, gf_dmp_full_folded_bias,
                             gf_full_requant_multiplier, gf_full_requant_right_shift,
                             16U, 1U, 16U, &weight_ms);
    check_input_bytes(GF_RGB_BYTES, 0x4103U);
    check_store_bytes(GF_ACTIVATION_BYTES, 0x4103U);
    hash = REG(GF_OUTPUT_FNV1A);
    /* GF_FULL_OUTPUT_FNV1A is the FNV the *reference image* happens to produce;
     * it is not a property of the network.  Comparing it for every input made
     * every camera frame "fail" conv0 -- the very first thing the live path hit
     * once there was a camera attached.  Gate it on `stats`, the same flag that
     * already means "this call is the verification pass" (gf_camera passes NULL
     * in the live loop).  The byte-count and fault checks above are properties
     * of the hardware and stay unconditional. */
    if (stats && !g_fail && hash != GF_FULL_OUTPUT_FNV1A) gf_fail(0x4103U, hash);
    if (stats) {
        stats->hw_fnv_conv0 = hash;
        stats->conv0 = cycles0;
        verify_tensor(stats, GF_CHK_CONV0, g_act1, GF_ACTIVATION_BYTES,
                      gf_body2_layer_input, "gf_body2_layer_input",
                      &stats->sw_fnv_conv0, &checks_ms);
    }

    /* conv1 (body2): 16 -> 16, fused pool1 */
    pool_cycles = exec_conv_tile(1U, buf_phys(g_act1), GF_ACTIVATION_BYTES, buf_phys(g_pool1),
                                 GF_POOL1_BYTES, 3U, 96U, 96U, 16U, 0U,
                                 g_w_body2, gf_dmp_body2_folded_bias,
                                 gf_body2_requant_multiplier, gf_body2_requant_right_shift,
                                 16U, 2U, 16U, &weight_ms);
    check_input_bytes(GF_ACTIVATION_BYTES, 0x4105U);
    check_store_bytes(GF_POOL1_BYTES, 0x4105U);
    hash = REG(GF_OUTPUT_FNV1A);
    /* Same reasoning as conv0 above: reference-image golden value, not a
     * property of the network. */
    if (stats && !g_fail && hash != GF_BODY2_OUTPUT_FNV1A) gf_fail(0x4105U, hash);
    if (stats) {
        /* Note: this register reads the PRE-pool conv output FNV
         * (GF_POOL_INPUT_FNV1A == GF_BODY2_OUTPUT_FNV1A), while the tensor
         * stored in DDR is the pooled one.  verify_tensor checks the stored
         * tensor against gf_pool_output, whose FNV is GF_POOL_OUTPUT_FNV1A. */
        stats->hw_fnv_pool1 = hash;
        stats->conv1_pool1 = pool_cycles;
        verify_tensor(stats, GF_CHK_POOL1, g_pool1, GF_POOL1_BYTES,
                      gf_pool_output, "gf_pool_output",
                      &stats->sw_fnv_pool1, &checks_ms);
    }

    /* conv2a: 16 -> 32, two 16-output tiles */
    for (index = 0U; index < 2U; ++index) {
        conv2_cycles[index] = exec_conv_tile(1U, buf_phys(g_pool1), GF_POOL1_BYTES,
                                             buf_phys(g_conv2), GF_CONV2_TILE_BYTES, 1U,
                                             48U, 48U, 32U, index * 16U,
                                             g_w_conv2a, gf_dmp_conv2a_folded_bias,
                                             gf_conv2a_requant_multiplier,
                                             gf_conv2a_requant_right_shift,
                                             GF_CONV2A_OUTPUT_LANES, 2U, 16U, &weight_ms);
        check_input_bytes(GF_POOL1_BYTES, 0x4107U);
        check_store_bytes(GF_CONV2_TILE_BYTES, 0x4107U);
    }
    if (stats) {
        stats->conv2a[0] = conv2_cycles[0];
        stats->conv2a[1] = conv2_cycles[1];
        verify_tensor(stats, GF_CHK_CONV2, g_conv2, GF_CONV2_BYTES,
                      gf_conv2b_layer_input, "gf_conv2b_layer_input",
                      &stats->sw_fnv_conv2, &checks_ms);
    }

    /* conv2b: 32 -> 32, fused pool2, two 16-output tiles */
    for (index = 0U; index < 2U; ++index) {
        pool2_cycles[index] = exec_conv_tile(2U, buf_phys(g_conv2), GF_CONV2_BYTES,
                                             buf_phys(g_pool2), GF_POOL2_TILE_BYTES, 3U,
                                             48U, 48U, 32U, index * 16U,
                                             g_w_conv2b, gf_dmp_conv2b_folded_bias,
                                             gf_conv2b_requant_multiplier,
                                             gf_conv2b_requant_right_shift,
                                             GF_CONV2B_OUTPUT_LANES, 4U, 16U, &weight_ms);
        check_input_bytes(GF_CONV2_BYTES, 0x4111U);
        check_store_bytes(GF_POOL2_TILE_BYTES, 0x4111U);
    }
    if (stats) {
        stats->conv2b_pool2[0] = pool2_cycles[0];
        stats->conv2b_pool2[1] = pool2_cycles[1];
        verify_tensor(stats, GF_CHK_POOL2, g_pool2, GF_POOL2_BYTES,
                      gf_pool2_output, "gf_pool2_output",
                      &stats->sw_fnv_pool2, &checks_ms);
    }

    /* conv3a: 32 -> 48, three 16-output tiles */
    for (index = 0U; index < 3U; ++index) {
        conv4_cycles[index] = exec_conv_tile(2U, buf_phys(g_pool2), GF_POOL2_BYTES,
                                             buf_phys(g_conv4), GF_CONV4_TILE_BYTES, 1U,
                                             24U, 24U, 48U, index * 16U,
                                             g_w_conv3a, gf_dmp_conv3a_folded_bias,
                                             gf_conv3a_requant_multiplier,
                                             gf_conv3a_requant_right_shift,
                                             GF_CONV3A_OUTPUT_LANES, 4U, 16U, &weight_ms);
        check_input_bytes(GF_POOL2_BYTES, 0x4116U);
        check_store_bytes(GF_CONV4_TILE_BYTES, 0x4116U);
    }
    if (stats) {
        stats->conv3a[0] = conv4_cycles[0];
        stats->conv3a[1] = conv4_cycles[1];
        stats->conv3a[2] = conv4_cycles[2];
        verify_tensor(stats, GF_CHK_CONV4, g_conv4, GF_CONV4_BYTES,
                      gf_conv3b_layer_input, "gf_conv3b_layer_input",
                      &stats->sw_fnv_conv4, &checks_ms);
    }

    /* conv3b: 48 -> 48, fused pool3, three 16-output tiles */
    for (index = 0U; index < 3U; ++index) {
        pool3_cycles[index] = exec_conv_tile(3U, buf_phys(g_conv4), GF_CONV4_BYTES,
                                             buf_phys(g_pool3), GF_POOL3_TILE_BYTES, 3U,
                                             24U, 24U, 48U, index * 16U,
                                             g_w_conv3b, gf_dmp_conv3b_folded_bias,
                                             gf_conv3b_requant_multiplier,
                                             gf_conv3b_requant_right_shift,
                                             GF_CONV3B_OUTPUT_LANES, 6U, 16U, &weight_ms);
        check_input_bytes(GF_CONV4_BYTES, 0x411DU);
        check_store_bytes(GF_POOL3_TILE_BYTES, 0x411DU);
    }
    if (stats) {
        stats->conv3b_pool3[0] = pool3_cycles[0];
        stats->conv3b_pool3[1] = pool3_cycles[1];
        stats->conv3b_pool3[2] = pool3_cycles[2];
        verify_tensor(stats, GF_CHK_POOL3, g_pool3, GF_POOL3_BYTES,
                      gf_pool3_output, "gf_pool3_output",
                      &stats->sw_fnv_pool3, &checks_ms);
    }

    /* head 1x1: 48 -> 64, four 16-output tiles */
    for (index = 0U; index < 4U; ++index) {
        head1x1_cycles[index] = exec_conv_tile(5U, buf_phys(g_pool3), GF_POOL3_BYTES,
                                               buf_phys(g_head1x1), GF_HEAD1X1_TILE_BYTES, 1U,
                                               12U, 12U, 64U, index * 16U,
                                               g_w_head1x1, gf_dmp_head1x1_folded_bias,
                                               gf_head1x1_requant_multiplier,
                                               gf_head1x1_requant_right_shift,
                                               64U, 6U, 16U, &weight_ms);
        check_input_bytes(GF_POOL3_BYTES, 0x412BU);
        check_store_bytes(GF_HEAD1X1_TILE_BYTES, 0x412BU);
    }
    if (stats) {
        stats->head1x1[0] = head1x1_cycles[0];
        stats->head1x1[1] = head1x1_cycles[1];
        stats->head1x1[2] = head1x1_cycles[2];
        stats->head1x1[3] = head1x1_cycles[3];
        /* No golden array was exported for the 12x12x64 head output, so this is
         * a baseline only -- recorded so a future change can be diffed against
         * it.  The GAP/FC stages after it ARE verified (below). */
        stats->sw_fnv_head1x1 = fnv1a(g_head1x1, GF_HEAD1X1_BYTES);
    }

    /* GAP(64) + FC(18) */
    REG(GF_CONTROL) = 1U;
    load_gap_fc_descriptor();
    gap_fc_cycles = run_gap_fc(buf_phys(g_head1x1));

    status       = REG(GF_STATUS);
    dma_status   = REG(GF_DMA_STATUS);
    gap_fnv      = REG(GF_POST_GAP_FNV1A_REG);
    fc_fnv       = REG(GF_POST_FC_FNV1A_REG);
    post_class   = REG(GF_POST_CLASS_REG);
    post_progress = REG(GF_POST_PROGRESS_REG);

    /* Split these by what they actually depend on:
     *   - the fault bits and the DMA byte count are properties of the hardware;
     *   - GF_POST_*_EXPECTED_* and the class are properties of the INPUT, so
     *     they only mean something for the reference image (stats != NULL).
     * The class must however be a real class for ANY input -- that one check is
     * input-independent and is what makes the live path still self-validating.
     */
    if ((status & (GF_FAULT_BIT | GF_LAYER_FAULT_BIT)) ||
        (dma_status & GF_DMA_FAULT_BIT) || !(dma_status & GF_DMA_DONE_BIT) ||
        GF_DMA_BYTES_READ(dma_status) != GF_HEAD1X1_BYTES ||
        (post_class & 31U) >= GF_POST_FC_OUTPUTS ||
        (stats && (gap_fnv != GF_POST_GAP_EXPECTED_FNV1A ||
                   fc_fnv  != GF_POST_FC_EXPECTED_FNV1A ||
                   (post_class & 31U) != GF_POST_EXPECTED_CLASS))) {
        gf_fail(0x4133U, fc_fnv);
    }

    t_end = now_ms();

    if (stats) {
        stats->gap_fc            = gap_fc_cycles;
        stats->gap_fnv           = gap_fnv;
        stats->fc_fnv            = fc_fnv;
        stats->gap_progress      = post_progress;
        stats->pl_cycles_total   = cycles0 + pool_cycles + gap_fc_cycles;
        for (index = 0U; index < 2U; ++index) stats->pl_cycles_total += conv2_cycles[index] + pool2_cycles[index];
        for (index = 0U; index < 3U; ++index) stats->pl_cycles_total += conv4_cycles[index] + pool3_cycles[index];
        for (index = 0U; index < 4U; ++index) stats->pl_cycles_total += head1x1_cycles[index];
        stats->cpu_total_ms   = t_end - t_start;
        stats->weight_load_ms = weight_ms;
        stats->cpu_checks_ms  = checks_ms;
    }

    if (out_class) *out_class = post_class & 31U;

    if (g_fail) {
        fprintf(stderr, "gf_npu: run failed: %s\n", g_fail_msg);
        return -1;
    }
    if (stats && stats->content_failed != 0) {
        fprintf(stderr, "gf_npu: %d of %d golden content checks failed\n",
                stats->content_failed, stats->content_checked);
        return -1;
    }
    return 0;
}

/* -------------------------------------------------------------- selftest -- */
int gf_npu_selftest(gf_npu_stats *stats)
{
    uint32_t cls = 0U;
    gf_npu_stats local;
    int rc;

    /* The reference-image checks (golden FNV chain, byte-exact tensors) are
     * gated on the stats pointer -- see the note in gf_npu_run_frame.  The
     * selftest runs the reference image by definition, so it must always supply
     * one; passing NULL through would silently stop verifying the FNV chain.
     * (gf_camera --selftest calls this with NULL.) */
    if (!stats) {
        memset(&local, 0, sizeof local);
        stats = &local;
    }

    printf("gf_npu: selftest with the built-in reference image\n");
    rc = gf_npu_run_frame(gf_full_camera_rgb, &cls, stats);
    if (rc != 0) return rc;

    printf("gf_npu: SELFTEST PASS  class=%u (%s)  expected=%u\n",
           (unsigned)cls, gf_npu_class_name(cls), (unsigned)GF_POST_EXPECTED_CLASS);
    return (cls == GF_POST_EXPECTED_CLASS) ? 0 : -1;
}

/* ----------------------------------------------------------- class names -- */
static const char *const GF_CLASS_NAMES[18] = {
    "call", "dislike", "fist", "four", "like", "mute", "ok", "one", "palm",
    "peace", "peace_inverted", "rock", "stop", "stop_inverted", "three",
    "three2", "two_up", "two_up_inverted"
};

const char *gf_npu_class_name(uint32_t class_index)
{
    if (class_index < 18U) return GF_CLASS_NAMES[class_index];
    return "?";
}

/* ------------------------------------------------------------- accessors -- */
const uint8_t *gf_npu_reference_input(void)
{
    return gf_full_camera_rgb;
}

uint32_t gf_npu_expected_fnv_conv0(void)
{
    return GF_FULL_OUTPUT_FNV1A;
}

uint32_t gf_npu_expected_fnv_pool1(void)
{
    return GF_BODY2_OUTPUT_FNV1A;
}

uint32_t gf_npu_expected_class(void)
{
    return GF_POST_EXPECTED_CLASS;
}

uint32_t gf_npu_expected_fnv_gap(void)
{
    return GF_POST_GAP_EXPECTED_FNV1A;
}

uint32_t gf_npu_expected_fnv_fc(void)
{
    return GF_POST_FC_EXPECTED_FNV1A;
}
