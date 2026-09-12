/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * GestureFlow HaGRID-18 DMP NPU -- Linux userspace driver interface (ZCU104).
 *
 * This is the Linux counterpart of the baremetal driver in
 * board_7020/software/gestureflow_hagrid18_dmp_main.c.  The register protocol,
 * the weight staging and the tile schedule are deliberately kept identical to
 * that proven implementation; the differences are only in how memory is
 * obtained (mmap instead of static arrays) and how time is measured.
 *
 * ---------------------------------------------------------------------------
 * Platform facts (all read back from the built artifacts; see
 * docs/ZCU104_Linux侧NPU与摄像头_设计与实施_2026-09-12.md):
 *
 *   PL register block (AXI-Lite)   0xA0000000, 1 MB
 *     - the DT node gestureflow_layer_chain_dmp_hp0_axil@a0000000 has no Linux
 *       driver, so userspace maps it directly.
 *   Scratch DDR (reserved-memory)  0x70000000, 16 MB
 *   NPU master address space        0x0 - 0x80000000  (S_AXI_HP0_FPD)
 *
 * HOW THE SCRATCH REGION GETS A USABLE MAPPING -- this is subtle and getting it
 * wrong costs a hard SIGBUS with no kernel log, so it is spelled out here with
 * the kernel code it depends on.
 *
 * Both regions are reached with mmap() on /dev/mem opened O_RDWR|O_SYNC.  On
 * arm64 the mapping attributes come from
 *     arch/arm64/mm/mmu.c::phys_mem_access_prot()
 *         if (!pfn_is_map_memory(pfn))   -> pgprot_noncached()     = MT_DEVICE_nGnRnE
 *         else if (file->f_flags & O_SYNC) -> pgprot_writecombine() = MT_NORMAL_NC
 *         else                             -> vma_prot             = Normal, CACHED
 * and pfn_is_map_memory() is memblock_is_map_memory(), which is false for any
 * range carrying MEMBLOCK_NOMAP or absent from the memory node.
 *
 * Consequences, in order of how badly they bite:
 *
 *   1. `no-map` in the reserved-memory node -- or cutting the range out of the
 *      memory node -- makes pfn_is_map_memory() false, so /dev/mem hands out
 *      **Device-nGnRnE**.  That works for the single 32-bit reads `devmem`
 *      does, but the Arm architecture only defines <=64-bit accesses to Device
 *      memory, so this driver's memset()/memcpy() over the region (DC ZVA and
 *      128-bit STP) faults immediately.  Hence system-user.dtsi deliberately
 *      does NOT use no-map.
 *   2. Without O_SYNC the region would stay Normal **Cached**, which is wrong
 *      for a non-coherent HP0 master.  Hence the O_SYNC in gf_npu_open().
 *   3. MT_NORMAL_NC is non-cacheable (no maintenance needed -- the HP0 view and
 *      the CPU view both come from DDR) but it is WEAKLY ORDERED.  Stores into
 *      it can be buffered and reordered past the subsequent MMIO doorbell, so
 *      every place that rings the doorbell, and every place that reads a
 *      result back, needs an explicit barrier.  See GF_MB() in gf_npu.c.
 *
 * The baremetal driver got away without (3) because Xil_SetTlbAttributes() put
 * its buffers in Device memory, where the ordering rules are stronger.  That
 * does not carry over to this mapping.
 * ---------------------------------------------------------------------------
 */
#ifndef GF_NPU_H
#define GF_NPU_H

#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ bases -- */
#define GF_REG_PHYS_BASE   0xA0000000UL
#define GF_REG_SIZE        0x00100000UL

/* Must match the reserved-memory node in system-user.dtsi. */
#define GF_BUF_PHYS_BASE   0x70000000UL
#define GF_BUF_SIZE        0x01000000UL

/* Expected ID registers (same as the baremetal driver). */
#define GF_MAGIC_VALUE     0x47464E50U     /* "GFNP" */
#define GF_VERSION_VALUE   0x00050001U

/* ------------------------------------------------------------- registers -- */
#define GF_MAGIC                 0x000U
#define GF_VERSION               0x004U
#define GF_CONTROL               0x008U
#define GF_STATUS                0x00CU
#define GF_QCFG                  0x010U
#define GF_WCTRL                 0x014U
#define GF_WDATA                 0x018U
#define GF_BIDX                  0x01CU
#define GF_BDATA                 0x020U
#define GF_RQIDX                 0x024U
#define GF_RQMULT                0x028U
#define GF_RQSHIFT               0x02CU
#define GF_CYCLES                0x034U
#define GF_INPUT_PIXELS          0x038U
#define GF_OUTPUT_VECTORS        0x03CU
#define GF_OUTPUT_FNV1A          0x040U
#define GF_DMA_SOURCE            0x044U
#define GF_DMA_BYTES             0x048U
#define GF_DMA_PIXELS            0x04CU
#define GF_DMA_STATUS            0x050U
#define GF_STORE_DESTINATION     0x054U
#define GF_STORE_BYTES           0x058U
#define GF_STORE_CONTROL         0x05CU
#define GF_STORE_STATUS          0x060U
#define GF_LAYER_MODE            0x064U
#define GF_JOB_WIDTH             0x068U
#define GF_JOB_HEIGHT            0x06CU
#define GF_OUTPUT_LANE_MASK      0x070U
#define GF_STORE_STRIDE          0x074U
#define GF_STORE_VALID_BYTES     0x078U
#define GF_POST_GAP_MULT         0x080U
#define GF_POST_GAP_SHIFT        0x084U
#define GF_POST_QCFG             0x088U
#define GF_POST_GAP_FNV1A_REG    0x08CU
#define GF_POST_FC_FNV1A_REG     0x090U
#define GF_POST_CLASS_REG        0x094U
#define GF_POST_CYCLES_REG       0x098U
#define GF_POST_PROGRESS_REG     0x09CU
#define GF_WEIGHT_KEY            0x0C0U
#define GF_WEIGHT_RESIDENT_KEY   0x0C4U
#define GF_WEIGHT_WRITE_COUNT    0x0C8U
#define GF_WEIGHT_HIT_COUNT      0x0CCU
#define GF_WEIGHT_BYTES          0x0D0U
#define GF_WEIGHT_STATUS         0x0D4U
#define GF_WEIGHT_COMMIT         0x0D8U
#define GF_WEIGHT_MISS_COUNT     0x0DCU
#define GF_WEIGHT_DMA_SOURCE     0x0E0U
#define GF_WEIGHT_DMA_BYTES      0x0E4U
#define GF_WEIGHT_DMA_CFG        0x0E8U
#define GF_WEIGHT_DMA_CONTROL    0x0ECU
#define GF_WEIGHT_DMA_STATUS     0x0F0U
#define GF_WEIGHT_DMA_BYTES_READ 0x0F4U
#define GF_WEIGHT_DMA_WRITE_COUNT 0x0F8U
#define GF_WEIGHT_BANK_SELECT    0x0FCU
#define GF_PARAM_BANK_SELECT     0x150U
#define GF_WEIGHT_READ_BANK_SELECT 0x15CU

/* ------------------------------------------------------------ bit fields -- */
#define GF_DONE_BIT              (1U << 1)
#define GF_FAULT_BIT             (1U << 2)
#define GF_LAYER_FAULT_BIT       (1U << 6)
#define GF_RUNNING_BIT           (1U << 0)

#define GF_DMA_BUSY_BIT          (1U << 0)
#define GF_DMA_DONE_BIT          (1U << 1)
#define GF_DMA_FAULT_BIT         (1U << 2)

#define GF_STORE_DONE_BIT        (1U << 1)
#define GF_STORE_FAULT_BIT       (1U << 2)

#define GF_WEIGHT_DMA_BUSY_BIT   (1U << 0)
#define GF_WEIGHT_DMA_DONE_BIT   (1U << 1)
#define GF_WEIGHT_DMA_FAULT_BIT  (1U << 2)

#define GF_DMA_BYTES_READ(v)        ((v) >> 3)
#define GF_STORE_BYTES_WRITTEN(v)   ((v) >> 3)

/* QCFG value used by every tile in the verified driver:
 *   [7:0]   input  zero point 0x80 -> -128 (also the conv padding value)
 *   [15:8]  output zero point 0x80 -> -128
 *   [16]    requant_enable      = 1
 *   [17]    requant_relu_enable = 1
 */
#define GF_QCFG_VALUE            0x00038080U

/* ----------------------------------------------------------------- sizes -- */
#define GF_FULL_W               96U
#define GF_FULL_H               96U
#define GF_RGB_BYTES            (GF_FULL_W * GF_FULL_H * 3U)      /* 27648 */

/* ------------------------------------------------------------ stats/API -- */
/* Per-tile cycle counts, in the order the network runs them. */
typedef struct {
    uint32_t conv0;              /* 3 -> 16,  96x96 */
    uint32_t conv1_pool1;        /* 16 -> 16, 96x96, fused pool */
    uint32_t conv2a[2];          /* 16 -> 32, 48x48 */
    uint32_t conv2b_pool2[2];    /* 32 -> 32, 48x48, fused pool */
    uint32_t conv3a[3];          /* 32 -> 48, 24x24 */
    uint32_t conv3b_pool3[3];    /* 48 -> 48, 24x24, fused pool */
    uint32_t head1x1[4];         /* 48 -> 64, 12x12 */
    uint32_t gap_fc;             /* GAP(64) + FC(18) */

    uint32_t pl_cycles_total;    /* sum of the tile cycles above */

    /* Hardware GF_OUTPUT_FNV1A read after the two layers the baremetal driver
     * also checked.  For conv0 it is the FNV of the stored 96x96x16 tensor; for
     * conv1 it is the FNV of the *pre-pool* conv output
     * (= GF_POOL_INPUT_FNV1A = GF_BODY2_OUTPUT_FNV1A), not of the stored pooled
     * tensor -- established by computing FNV1A over the exported golden arrays. */
    uint32_t hw_fnv_conv0;
    uint32_t hw_fnv_pool1;

    uint32_t gap_fnv;            /* GF_POST_GAP_FNV1A_REG */
    uint32_t fc_fnv;             /* GF_POST_FC_FNV1A_REG */
    uint32_t gap_progress;       /* GF_POST_PROGRESS_REG */

    /* Bit-exact content checks: each stored tensor is memcmp'd against the
     * corresponding golden array exported alongside the weights.  This is the
     * strong form of verification -- the baremetal driver only checked byte
     * counts for these stages.  See gf_npu_check_name[] for the labels. */
    int      content_checked;    /* number of golden comparisons performed */
    int      content_failed;     /* number that mismatched (0 = all good) */
    /* Per-comparison result, indexed by the GF_CHK_* enum when >= 0. */
    int8_t   content_rc[12];

    uint32_t sw_fnv_conv0;       /* FNV1A of the tensor as actually computed */
    uint32_t sw_fnv_pool1;
    uint32_t sw_fnv_conv2;
    uint32_t sw_fnv_pool2;
    uint32_t sw_fnv_conv4;
    uint32_t sw_fnv_pool3;
    uint32_t sw_fnv_head1x1;

    double   cpu_total_ms;       /* wall time of the whole gf_npu_run_frame */
    double   weight_load_ms;     /* wall time spent inside the weight DMA waits */
    /* Time spent inside the content checks above.  These are only performed when
     * `stats` is non-NULL (so never in the live camera loop), but they must be
     * subtracted when comparing CPU overhead against the baremetal numbers:
     * memcmp+FNV1A over ~0.6 MB of *uncached* memory is not free. */
    double   cpu_checks_ms;
} gf_npu_stats;

/* Indices into gf_npu_stats.content_rc / gf_npu_check_name. */
enum {
    GF_CHK_CONV0 = 0,
    GF_CHK_POOL1,
    GF_CHK_CONV2,
    GF_CHK_POOL2,
    GF_CHK_CONV4,
    GF_CHK_POOL3,
    GF_CHK_COUNT
};

/* Human-readable names for the content checks (index with the GF_CHK_* enum). */
extern const char *const gf_npu_check_name[GF_CHK_COUNT];

/* Open /dev/mem, map the register block and the scratch region, and check
 * GF_MAGIC / GF_VERSION.  Returns 0 on success, negative errno-ish on failure
 * (message on stderr). */
int  gf_npu_open(void);

/* Copy every layer's weight / bias / requant array into the scratch region so
 * the NPU can DMA them.  Call once, after gf_npu_open().  Returns 0 on success. */
int  gf_npu_load_weights(void);

/* Run one full network pass on a 96x96x3 RGB image.
 *
 * `rgb96` holds raw uint8 pixels in HWC order (pixel 0 R,G,B, pixel 1 R,G,B...).
 * IMPORTANT: do NOT pre-subtract 128 -- the PL's RGB loader recenters to
 * q = u - 128 itself (rtl/gestureflow_hp0_rgb_loader.sv).
 *
 * `stats` is the "verification pass" flag as well as an output:
 *   - stats != NULL  -> the input is the REFERENCE IMAGE, so every check tied
 *     to it runs: the golden FNV chain (conv0, conv1, GAP, FC), the expected
 *     class, and the byte-exact golden tensor comparisons.  Slower (memcmp over
 *     uncached memory), and it must be the reference image or it will fail.
 *   - stats == NULL  -> the live path (gf_camera's loop).  Only the
 *     input-independent checks run: fault bits, DMA/store byte counts, and the
 *     class being within 0..17.  No golden value is compared, because a camera
 *     frame legitimately produces different numbers.
 * Passing NULL for a reference-image call, or non-NULL for a live frame, is a
 * bug in the caller; `gf_npu_selftest()` supplies its own stats for this
 * reason.
 *
 * `out_class` receives the predicted class (0..17).  `stats` may be NULL.
 * Returns 0 on success, negative on any check failure. */
int  gf_npu_run_frame(const uint8_t *rgb96, uint32_t *out_class, gf_npu_stats *stats);

/* Run the built-in deterministic reference image and verify every check the
 * baremetal driver performs.  Use this to validate the port before trusting
 * live camera results.  Returns 0 on success. */
int  gf_npu_selftest(gf_npu_stats *stats);

void gf_npu_close(void);

/* Class index -> HaGRID-18 label, for display.  Returns "?" for out-of-range. */
const char *gf_npu_class_name(uint32_t class_index);

/* ------------------------------------------------------------------------- *
 * Accessors for values that come from the generated weight headers.
 *
 * The header tables are `static const` (they are pulled in with #include), so
 * other translation units cannot refer to them directly.  These accessors keep
 * every macro reference inside gf_npu.c, which is also the only file that must
 * preserve the baremetal driver's include order for the macros to resolve the
 * same way.  gf_npu_probe.c uses them to print and check expectations.
 * ------------------------------------------------------------------------- */
const uint8_t *gf_npu_reference_input(void);   /* 27648 bytes, raw uint8 HWC */
uint32_t       gf_npu_expected_fnv_conv0(void);
uint32_t       gf_npu_expected_fnv_pool1(void);
uint32_t       gf_npu_expected_class(void);
uint32_t       gf_npu_expected_fnv_gap(void);
uint32_t       gf_npu_expected_fnv_fc(void);

#endif /* GF_NPU_H */
