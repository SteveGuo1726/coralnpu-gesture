#include "sleep.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xil_printf.h"
#include "xil_types.h"

#include "static_cnn_fc_real_sample_int8.h"
#include "static_cnn_fc_real_batch6_int8.h"
#include "static_cnn_convhead_gap_fc_real_batch6_int8.h"

/*
 * PROJECT_LOCAL_MOD:
 * PS-side bare-metal driver for the accelerator-only RVV lane1 wrapper on
 * Zynq-7020. It does two things on real hardware:
 * 1. Replays the already proven on-board vector smoke path.
 * 2. Runs a small gesture-model postprocess subchain:
 *    INT32 accumulator + bias + output_offset -> corrected class score.
 *
 * This is intentionally a real executable board test, not just a host-side
 * register poke script.
 */

#define PROBE_RESULT_BASE 0xFFFF0000U
#define WRAPPER_BASE      0x43C00000U

#define REG_MAGIC         0x000U
#define REG_VERSION       0x004U
#define REG_CONTROL       0x008U
#define REG_STATUS        0x00CU
#define REG_INST_PC       0x014U
#define REG_INST_ENC      0x018U
#define REG_RS0           0x01CU
#define REG_RS1           0x020U
#define REG_FRS0          0x024U
#define REG_ASYNC_RD      0x044U
#define REG_CONFIG0       0x04CU
#define REG_ROB_VALID     0x060U
#define REG_ROB_DATA0     0x064U
#define REG_ROB_DATA1     0x068U
#define REG_ROB_META0     0x074U
#define REG_LSU_EVT0      0x084U
#define REG_LSU_EVT1      0x088U
#define REG_LSU_EVT2      0x08CU
#define REG_LSU_EVT3      0x090U
#define REG_LSU_EVT4      0x094U
#define REG_LSU_EVT5      0x098U
#define REG_LSU_EVT6      0x09CU
#define REG_DEBUG0        0x080U

#define RESULT_SIGNATURE       0x47535450U
#define RESULT_PASS            0x600D600DU
#define RESULT_FAIL            0xBAD0BAD0U
#define RESULT_DATA_ABORT      0xDA7AAB01U
#define RESULT_PREFETCH_ABORT  0xDA7AAB02U

#define FAIL_VECTOR_CFG        0x00010001U
#define FAIL_VECTOR_A2         0x00010002U
#define FAIL_VECTOR_A3_16      0x00010003U
#define FAIL_VECTOR_A3_17      0x00010004U
#define FAIL_VECTOR_A4         0x00010005U
#define FAIL_POST_CFG          0x00020001U
#define FAIL_POST_SCORE        0x00020002U
#define FAIL_CONTROL_STUCK     0x00030001U
#define FAIL_MUL_SMOKE         0x00040001U
#define FAIL_FC_SCORE0         0x00040002U
#define FAIL_FC_SCORE1         0x00040003U
#define FAIL_DDR_CFG           0x00050001U
#define FAIL_DDR_LOAD          0x00050002U
#define FAIL_DDR_STORE         0x00050003U
#define FAIL_DDR_SCORE0        0x00050004U
#define FAIL_DDR_SCORE1        0x00050005U
#define FAIL_REAL_Q29_0        0x00050010U
#define FAIL_REAL_Q29_1        0x00050011U
#define FAIL_REAL_Q29_2        0x00050012U
#define FAIL_REAL_Q29_3        0x00050013U
#define FAIL_REAL_Q29_4        0x00050014U
#define FAIL_REAL_Q29_5        0x00050015U
#define FAIL_REAL_CONV_CFG     0x00060001U
#define FAIL_REAL_CONV_LOAD    0x00060002U
#define FAIL_REAL_CONV_MAC     0x00060003U
#define FAIL_REAL_GAP          0x00060004U
#define FAIL_REAL_FC_RAW       0x00060005U
#define FAIL_REAL_FC_Q29       0x00060006U
#define FAIL_REAL_PRED         0x00060007U
#define FAIL_REAL_CONV_STORE   0x00060008U

#define CTRL_CLEAR_STICKY      0x00000002U
#define CTRL_ISSUE             0x00000003U

#define CONFIG0_E8_M1_VL16     0x00018008U
#define CONFIG0_E32_M1_VL1     0x01918001U

#define INST_VSETIVLI_E8       0x06604382U
#define INST_VMV_VI15_V1       0x02F03D86U
#define INST_VMV_X_S_A2_V1     0x02108132U
#define INST_VADD_VI1_V2       0x0010858AU
#define INST_VMV_X_S_A3_V2     0x02110136U
#define INST_VADD_VX_A0_V2     0x00102A0AU
#define INST_VMV_VI2_V2        0x02F0098AU
#define INST_VADD_VV_V3        0x0010880EU
#define INST_VMV_X_S_A4_V3     0x0211813AU

#define INST_VSETIVLI_E32      0x06680782U
#define INST_VSETIVLI_E32_VL2  0x06680B82U
#define INST_VMV_S_X_V8_A0     0x02102B22U
#define INST_VMV_S_X_V9_A0     0x02102B26U
#define INST_VLE32_V8_A0       0x00102B20U
#define INST_VLE32_V9_A0       0x00102B24U
#define INST_VSE32_V8_A0       0x00102B21U
#define INST_VADD_VV_V8_V9     0x00142422U
#define INST_VADD_VX_V8_A0     0x00142A22U
#define INST_VMV_X_S_A2_V8     0x02140132U
#define INST_VMUL_VX_V8_V9_A0  0x04B4AB22U
#define INST_VMACC_VX_V8_A0_V9 0x05B4AB22U

#define DDR_FEATURE_BASE       0x01000000U
#define DDR_SCORE_BASE         0x01000200U
#define DDR_CONV_BIAS_BASE     0x01010000U
#define DDR_CONV_WEIGHT_BASE   0x01011000U

static volatile u32 *const probe = (volatile u32 *)PROBE_RESULT_BASE;
static volatile u32 g_stage = 0U;

static const s32 kGestureAccum[6] = {
    0x00001234, -0x00000020, 0x00000180,
    0x00000700, -0x00000100, 0x00000044,
};

static const s32 kGestureBias[6] = {
    0x00000010, 0x00000005, -0x00000010,
    0x00000022, 0x00000008, -0x00000004,
};

static const s32 kGestureOutputOffset = 5;

static const s32 kGestureFcFeatures[4] = {12, -3, 5, 2};
static const s32 kGestureFcBias[2] = {9, -4};
static const s32 kGestureFcWeights[2][4] = {
    {4, 7, -6, 1},
    {-1, 3, 2, 5},
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

static inline void set_failure(u32 code)
{
    probe_store(0U, RESULT_FAIL);
    probe_store(2U, code);
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
    for (i = 0U; i < 64U; ++i) {
        probe_store(i, 0U);
    }
    probe_store(0U, RESULT_SIGNATURE);
}

static inline void clear_sticky(void)
{
    Xil_Out32(WRAPPER_BASE + REG_CONTROL, CTRL_CLEAR_STICKY);
}

static inline void issue_inst(u32 pc, u32 inst_enc, u32 rs0, u32 rs1, u32 frs0)
{
    Xil_Out32(WRAPPER_BASE + REG_INST_PC, pc);
    Xil_Out32(WRAPPER_BASE + REG_INST_ENC, inst_enc);
    Xil_Out32(WRAPPER_BASE + REG_RS0, rs0);
    Xil_Out32(WRAPPER_BASE + REG_RS1, rs1);
    Xil_Out32(WRAPPER_BASE + REG_FRS0, frs0);
    Xil_Out32(WRAPPER_BASE + REG_CONTROL, CTRL_ISSUE);
}

static int wait_control_idle(u32 *polls_out)
{
    u32 polls = 0U;
    while (polls < 1000000U) {
        if ((Xil_In32(WRAPPER_BASE + REG_CONTROL) & 0x1U) == 0U) {
            if (polls_out != 0) {
                *polls_out = polls;
            }
            return 0;
        }
        ++polls;
    }
    if (polls_out != 0) {
        *polls_out = polls;
    }
    return -1;
}

static int wait_config0(u32 expected, u32 *last_value)
{
    u32 polls = 0U;
    u32 value = 0U;
    while (polls < 1000000U) {
        value = Xil_In32(WRAPPER_BASE + REG_CONFIG0);
        if (value == expected) {
            if (last_value != 0) {
                *last_value = value;
            }
            return 0;
        }
        ++polls;
    }
    if (last_value != 0) {
        *last_value = value;
    }
    return -1;
}

/*
 * PROJECT_LOCAL: configLmul is an internal, derived representation and can
 * vary with VL even when the encoded LMUL is still m1.  Verify the stable
 * architectural fields instead of comparing the debug packing verbatim.
 */
static int wait_config_e32_m1(u32 expected_vl, u32 *last_value)
{
    u32 polls = 0U;
    u32 value = 0U;

    while (polls < 1000000U) {
        value = Xil_In32(WRAPPER_BASE + REG_CONFIG0);
        if (((value & 0x10000000U) == 0U) &&
            ((value & 0x0E000000U) == 0U) &&
            (((value >> 19) & 0x7U) == 2U) &&
            ((value & 0xFFU) == expected_vl)) {
            if (last_value != 0) {
                *last_value = value;
            }
            return 0;
        }
        ++polls;
    }

    if (last_value != 0) {
        *last_value = value;
    }
    return -1;
}

static int wait_async_rd(u32 expected, u32 *last_value)
{
    u32 polls = 0U;
    u32 value = 0U;
    while (polls < 1000000U) {
        value = Xil_In32(WRAPPER_BASE + REG_ASYNC_RD);
        if (value == expected) {
            if (last_value != 0) {
                *last_value = value;
            }
            return 0;
        }
        ++polls;
    }
    if (last_value != 0) {
        *last_value = value;
    }
    return -1;
}

static inline u32 expected_async_rd(u32 xreg, u32 value)
{
    return 0x80000000U | ((xreg & 0x1FU) << 24) | (value & 0x00FFFFFFU);
}

/*
 * PROJECT_LOCAL_MOD: the bridge can be idle while a newly accepted command is
 * still travelling through the front-end/dispatch queue. A quiet bridge is
 * therefore not a completion indication. Wait for the cleared-and-then-set
 * functional retirement counter instead. Do not decode REG_ROB_VALID here:
 * it is a packed debug snapshot whose declared fields exceed the 32-bit CSR
 * read width, so an assumed fixed bit position is not a stable board ABI.
 */
static int wait_lsu_retired(u32 *debug0_out)
{
    u32 polls = 0U;
    u32 debug0 = 0U;

    while (polls < 1000000U) {
        u32 lsu_fault;
        u32 retire_count;

        debug0 = Xil_In32(WRAPPER_BASE + REG_DEBUG0);
        lsu_fault = (debug0 >> 9) & 0x1U;
        retire_count = Xil_In32(WRAPPER_BASE + REG_LSU_EVT4);

        if (lsu_fault != 0U) {
            if (debug0_out != 0) {
                *debug0_out = debug0;
            }
            return 2;
        }
        if ((retire_count & 0x0000FFFFU) != 0U) {
            if (debug0_out != 0) {
                *debug0_out = debug0;
            }
            return 0;
        }
        ++polls;
    }

    if (debug0_out != 0) {
        *debug0_out = debug0;
    }
    return 1;
}

/* PROJECT_LOCAL_MOD: preserve one command's handshake evidence in the board
 * probe area whenever a real-model LSU command fails. EVT0={issue,req},
 * EVT1={AR,R}, EVT2={AW,W}, EVT3={B,response}, EVT4={0,ROB}; EVT5 is the
 * sticky internal map/response/remap/ROB progression bitmap. */
static void probe_lsu_events(void)
{
    probe_store(48U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT0));
    probe_store(49U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT1));
    probe_store(50U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT2));
    probe_store(51U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT3));
    probe_store(52U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT4));
    probe_store(53U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT5));
    probe_store(63U, Xil_In32(WRAPPER_BASE + REG_LSU_EVT6));
}

static int issue_only(u32 stage, u32 pc, u32 inst_enc, u32 rs0)
{
    u32 polls = 0U;
    set_stage(stage);
    clear_sticky();
    issue_inst(pc, inst_enc, rs0, 0U, 0U);
    if (wait_control_idle(&polls) != 0) {
        probe_store(48U, polls);
        return -1;
    }
    return 0;
}

static int issue_lsu_only(u32 stage, u32 pc, u32 inst_enc, u32 rs0, u32 *debug0_out)
{
    int rc;

    set_stage(stage);
    clear_sticky();
    issue_inst(pc, inst_enc, rs0, 0U, 0U);
    rc = wait_lsu_retired(debug0_out);
    return rc;
}

static int issue_expect_async(u32 stage, u32 pc, u32 inst_enc, u32 rs0, u32 expected, u32 probe_index)
{
    u32 value = 0U;
    set_stage(stage);
    clear_sticky();
    issue_inst(pc, inst_enc, rs0, 0U, 0U);
    if (wait_async_rd(expected, &value) != 0) {
        probe_store(probe_index, value);
        return -1;
    }
    probe_store(probe_index, value);
    return 0;
}

static int run_vector_smoke(void)
{
    u32 value = 0U;

    set_stage(0x10U);
    probe_store(8U, Xil_In32(WRAPPER_BASE + REG_MAGIC));
    probe_store(9U, Xil_In32(WRAPPER_BASE + REG_VERSION));

    set_stage(0x11U);
    clear_sticky();
    issue_inst(0x10000000U, INST_VSETIVLI_E8, 0U, 0U, 0U);
    if (wait_config0(CONFIG0_E8_M1_VL16, &value) != 0) {
        probe_store(10U, value);
        return FAIL_VECTOR_CFG;
    }
    probe_store(10U, value);

    if (issue_only(0x12U, 0x10000004U, INST_VMV_VI15_V1, 0U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_expect_async(0x13U, 0x10000008U, INST_VMV_X_S_A2_V1, 0U,
                           expected_async_rd(12U, 0x0000000FU), 11U) != 0) {
        return FAIL_VECTOR_A2;
    }

    if (issue_only(0x14U, 0x1000000CU, INST_VADD_VI1_V2, 0U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_expect_async(0x15U, 0x10000010U, INST_VMV_X_S_A3_V2, 0U,
                           expected_async_rd(13U, 0x00000010U), 12U) != 0) {
        return FAIL_VECTOR_A3_16;
    }

    if (issue_only(0x16U, 0x10000014U, INST_VADD_VX_A0_V2, 0x00000011U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_expect_async(0x17U, 0x10000018U, INST_VMV_X_S_A3_V2, 0U,
                           expected_async_rd(13U, 0x00000011U), 13U) != 0) {
        return FAIL_VECTOR_A3_17;
    }

    if (issue_only(0x18U, 0x1000001CU, INST_VMV_VI2_V2, 0U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_only(0x19U, 0x10000020U, INST_VADD_VV_V3, 0U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_expect_async(0x1AU, 0x10000024U, INST_VMV_X_S_A4_V3, 0U,
                           expected_async_rd(14U, 0x00000011U), 14U) != 0) {
        return FAIL_VECTOR_A4;
    }

    return 0;
}

static int run_gesture_postprocess_subgraph(void)
{
    u32 value = 0U;
    s32 corrected[6];
    int best_index = 0;
    s32 best_score = -2147483647 - 1;
    u32 i;

    set_stage(0x20U);
    clear_sticky();
    issue_inst(0x10000100U, INST_VSETIVLI_E32, 0U, 0U, 0U);
    if (wait_config_e32_m1(1U, &value) != 0) {
        probe_store(20U, value);
        return FAIL_POST_CFG;
    }
    probe_store(20U, value);

    for (i = 0U; i < 6U; ++i) {
        corrected[i] = kGestureAccum[i] + kGestureBias[i] + kGestureOutputOffset;

        if (issue_only(0x30U + i, 0x10000104U, INST_VMV_S_X_V8_A0,
                       (u32)kGestureAccum[i]) != 0) {
            return FAIL_CONTROL_STUCK;
        }
        if (issue_only(0x40U + i, 0x10000108U, INST_VMV_S_X_V9_A0,
                       (u32)kGestureBias[i]) != 0) {
            return FAIL_CONTROL_STUCK;
        }
        if (issue_only(0x50U + i, 0x1000010CU, INST_VADD_VV_V8_V9, 0U) != 0) {
            return FAIL_CONTROL_STUCK;
        }
        if (issue_only(0x60U + i, 0x10000110U, INST_VADD_VX_V8_A0,
                       (u32)kGestureOutputOffset) != 0) {
            return FAIL_CONTROL_STUCK;
        }
        if (issue_expect_async(0x70U + i, 0x10000114U, INST_VMV_X_S_A2_V8, 0U,
                               expected_async_rd(12U, (u32)corrected[i]), 24U + i) != 0) {
            probe_store(40U, (u32)corrected[i]);
            probe_store(41U, (u32)i);
            return FAIL_POST_SCORE;
        }

        probe_store(32U + i, (u32)corrected[i]);
        if (corrected[i] > best_score) {
            best_score = corrected[i];
            best_index = (int)i;
        }
    }

    probe_store(42U, (u32)best_index);
    probe_store(43U, (u32)best_score);
    return 0;
}

static int run_mulmac_fc_subgraph(void)
{
    u32 value = 0U;
    s32 scores[2];
    int best_index = 0;
    s32 best_score = -2147483647 - 1;
    u32 cls;
    u32 j;

    set_stage(0x80U);
    clear_sticky();
    issue_inst(0x10000200U, INST_VSETIVLI_E32, 0U, 0U, 0U);
    if (wait_config_e32_m1(1U, &value) != 0) {
        probe_store(44U, value);
        return FAIL_POST_CFG;
    }
    probe_store(44U, value);

    if (issue_only(0x81U, 0x10000204U, INST_VMV_S_X_V9_A0, 7U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_only(0x82U, 0x10000208U, INST_VMUL_VX_V8_V9_A0, 9U) != 0) {
        return FAIL_CONTROL_STUCK;
    }
    if (issue_expect_async(0x83U, 0x1000020CU, INST_VMV_X_S_A2_V8, 0U,
                           expected_async_rd(12U, 63U), 45U) != 0) {
        return FAIL_MUL_SMOKE;
    }

    for (cls = 0U; cls < 2U; ++cls) {
        scores[cls] = kGestureFcBias[cls];

        if (issue_only(0x90U + cls, 0x10000210U, INST_VMV_S_X_V8_A0,
                       (u32)kGestureFcBias[cls]) != 0) {
            return FAIL_CONTROL_STUCK;
        }

        for (j = 0U; j < 4U; ++j) {
            scores[cls] += kGestureFcFeatures[j] * kGestureFcWeights[cls][j];

            if (issue_only(0xA0U + (cls * 8U) + j, 0x10000214U,
                           INST_VMV_S_X_V9_A0, (u32)kGestureFcFeatures[j]) != 0) {
                return FAIL_CONTROL_STUCK;
            }

            if (issue_only(0xB0U + (cls * 8U) + j, 0x10000218U,
                           INST_VMACC_VX_V8_A0_V9, (u32)kGestureFcWeights[cls][j]) != 0) {
                return FAIL_CONTROL_STUCK;
            }
        }

        if (issue_expect_async(0xC0U + cls, 0x1000021CU, INST_VMV_X_S_A2_V8, 0U,
                               expected_async_rd(12U, (u32)scores[cls]), 48U + cls) != 0) {
            probe_store(56U + cls, (u32)scores[cls]);
            return (cls == 0U) ? FAIL_FC_SCORE0 : FAIL_FC_SCORE1;
        }

        probe_store(50U + cls, (u32)scores[cls]);
        if (scores[cls] > best_score) {
            best_score = scores[cls];
            best_index = (int)cls;
        }
    }

    probe_store(52U, (u32)best_index);
    probe_store(53U, (u32)best_score);
    return 0;
}

static int run_ddr_fc_lsu_subgraph(void)
{
    volatile s32 *const ddr_features = (volatile s32 *)DDR_FEATURE_BASE;
    volatile s32 *const ddr_scores = (volatile s32 *)DDR_SCORE_BASE;
    s32 scores[REAL_FC_NUM_CLASSES];
    s32 quant_scores[REAL_FC_NUM_CLASSES];
    s32 sample_best_raw[REAL_BATCH_NUM_SAMPLES];
    s32 sample_best_quant[REAL_BATCH_NUM_SAMPLES];
    int best_index = 0;
    s32 best_score = -2147483647 - 1;
    s32 best_quant_score = -2147483647 - 1;
    u32 value = 0U;
    u32 debug0 = 0U;
    u32 sample_idx;
    u32 cls;
    u32 j;

    set_stage(0xD0U);
    clear_sticky();
    issue_inst(0x10000300U, INST_VSETIVLI_E32, 0U, 0U, 0U);
    if (wait_config_e32_m1(1U, &value) != 0) {
        probe_store(54U, value);
        return FAIL_DDR_CFG;
    }
    probe_store(54U, value);

    for (sample_idx = 0U; sample_idx < REAL_BATCH_NUM_SAMPLES; ++sample_idx) {
        for (j = 0U; j < REAL_FC_FEATURE_LEN; ++j) {
            ddr_features[j] = kRealBatchFeature[sample_idx][j];
        }
        for (cls = 0U; cls < REAL_FC_NUM_CLASSES; ++cls) {
            ddr_scores[cls] = 0;
            quant_scores[cls] = 0;
        }
        __asm__ volatile ("dsb sy" : : : "memory");

        best_index = 0;
        best_score = -2147483647 - 1;
        best_quant_score = -2147483647 - 1;

        for (cls = 0U; cls < REAL_FC_NUM_CLASSES; ++cls) {
            u32 score_addr = DDR_SCORE_BASE + (cls * 4U);
            float requant_multiplier;
            float quant_float;
            long quant_long;

            scores[cls] = kRealFcBiasAdjusted[cls];
            if (issue_only(0xD1U + cls, 0x10000304U, INST_VMV_S_X_V8_A0,
                           (u32)kRealFcBiasAdjusted[cls]) != 0) {
                return FAIL_CONTROL_STUCK;
            }

            for (j = 0U; j < REAL_FC_FEATURE_LEN; ++j) {
                u32 feature_addr = DDR_FEATURE_BASE + (j * 4U);
                s32 weight = kRealFcWeights[cls][j];
                int lsu_rc;

                lsu_rc = issue_lsu_only(0xD8U + (cls * 8U) + j, 0x10000308U,
                                        INST_VLE32_V9_A0, feature_addr, &debug0);
                if (lsu_rc != 0) {
                    probe_store(54U, sample_idx);
                    probe_store(55U, cls);
                    probe_store(56U, feature_addr);
                    probe_store(57U, (u32)lsu_rc);
                    return FAIL_DDR_LOAD;
                }

                scores[cls] += kRealBatchFeature[sample_idx][j] * weight;
                if (issue_only(0xE0U + (cls * 8U) + j, 0x1000030CU,
                               INST_VMACC_VX_V8_A0_V9, (u32)weight) != 0) {
                    return FAIL_CONTROL_STUCK;
                }
            }

            if (issue_expect_async(0xF0U + cls, 0x10000310U, INST_VMV_X_S_A2_V8, 0U,
                                   expected_async_rd(12U, (u32)scores[cls]), 58U + cls) != 0) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)scores[cls]);
                probe_store(57U, (u32)kRealBatchExpectedRaw[sample_idx][cls]);
                return FAIL_DDR_SCORE0 + cls;
            }

            if (issue_lsu_only(0xF4U + cls, 0x10000314U, INST_VSE32_V8_A0,
                               score_addr, &debug0) != 0) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, score_addr);
                probe_store(57U, debug0);
                return FAIL_DDR_STORE;
            }
            __asm__ volatile ("dsb sy" : : : "memory");

            if (ddr_scores[cls] != scores[cls]) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)ddr_scores[cls]);
                probe_store(57U, (u32)scores[cls]);
                return FAIL_DDR_SCORE0 + cls;
            }

            if (scores[cls] != kRealBatchExpectedRaw[sample_idx][cls]) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)scores[cls]);
                probe_store(57U, (u32)kRealBatchExpectedRaw[sample_idx][cls]);
                return FAIL_DDR_SCORE0 + cls;
            }

            requant_multiplier =
                (REAL_FC_FEATURE_SCALE * kRealFcWeightScale[cls]) / REAL_FC_OUT29_SCALE;
            quant_float = ((float)scores[cls] * requant_multiplier);
            if (quant_float >= 0.0f) {
                quant_long = (long)(quant_float + 0.5f);
            } else {
                quant_long = (long)(quant_float - 0.5f);
            }
            quant_long += REAL_FC_OUT29_ZP;
            if (quant_long > 127L) {
                quant_long = 127L;
            } else if (quant_long < -128L) {
                quant_long = -128L;
            }
            quant_scores[cls] = (s32)quant_long;
            if (quant_scores[cls] != kRealBatchExpectedQuant[sample_idx][cls]) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)quant_scores[cls]);
                probe_store(57U, (u32)kRealBatchExpectedQuant[sample_idx][cls]);
                return FAIL_REAL_Q29_0 + cls;
            }

            if (scores[cls] > best_score) {
                best_score = scores[cls];
            }
            if (quant_scores[cls] > best_quant_score) {
                best_quant_score = quant_scores[cls];
                best_index = (int)cls;
            }
        }

        if ((s32)best_index != kRealBatchExpectedPred[sample_idx]) {
            probe_store(54U, sample_idx);
            probe_store(55U, (u32)best_index);
            probe_store(56U, (u32)kRealBatchExpectedPred[sample_idx]);
            probe_store(57U, (u32)best_score);
            return FAIL_POST_SCORE;
        }

        sample_best_raw[sample_idx] = best_score;
        sample_best_quant[sample_idx] = best_quant_score;
        probe_store(54U + sample_idx, (u32)best_index);
    }

    probe_store(60U, REAL_BATCH_NUM_SAMPLES);
    probe_store(61U, (u32)sample_best_quant[0]);
    probe_store(62U, (u32)sample_best_quant[2]);
    probe_store(63U, (u32)sample_best_quant[5]);
    return 0;
}

static s32 quantize_conv_head_output(s32 raw_acc, u32 out_ch)
{
    double scaled =
        ((double)raw_acc * (double)REAL_POOL3_SCALE * (double)kRealConvHeadWeightScale[out_ch]) /
        (double)REAL_CONV_OUT_SCALE;
    long q_zero_based;
    long q;

    if (scaled <= 0.0) {
        return REAL_CONV_OUT_ZP;
    }

    q_zero_based = (long)(scaled + 0.5);
    q = q_zero_based + (long)REAL_CONV_OUT_ZP;
    if (q > 127L) {
        q = 127L;
    } else if (q < -128L) {
        q = -128L;
    }
    return (s32)q;
}

static s32 quantize_gap_output(s32 sum_zero_based)
{
    double scaled =
        ((double)sum_zero_based * (double)REAL_CONV_OUT_SCALE) /
        ((double)(REAL_POOL3_H * REAL_POOL3_W) * (double)REAL_GAP_OUT_SCALE);
    long q_zero_based;
    long q;

    if (scaled <= 0.0) {
        return REAL_GAP_OUT_ZP;
    }

    q_zero_based = (long)(scaled + 0.5);
    q = q_zero_based + (long)REAL_GAP_OUT_ZP;
    if (q > 127L) {
        q = 127L;
    } else if (q < -128L) {
        q = -128L;
    }
    return (s32)q;
}

static s32 quantize_fc_output(s32 raw_acc, u32 cls)
{
    double scaled =
        ((double)raw_acc * (double)REAL_GAP_OUT_SCALE * (double)kRealChainFcWeightScale[cls]) /
        (double)REAL_FC_OUT_SCALE;
    long q;

    if (scaled >= 0.0) {
        q = (long)(scaled + 0.5);
    } else {
        q = (long)(scaled - 0.5);
    }
    q += (long)REAL_FC_OUT_ZP;

    if (q > 127L) {
        q = 127L;
    } else if (q < -128L) {
        q = -128L;
    }
    return (s32)q;
}

static void stage_conv_head_pair_parameters(void)
{
    volatile s32 *const ddr_bias = (volatile s32 *)DDR_CONV_BIAS_BASE;
    volatile s32 *const ddr_weights = (volatile s32 *)DDR_CONV_WEIGHT_BASE;
    u32 out_ch;
    u32 in_ch;

    /* Two adjacent output channels share each issued scalar activation. */
    for (out_ch = 0U; out_ch < REAL_CONV_OUT_C; out_ch += 2U) {
        u32 pair = out_ch / 2U;
        ddr_bias[pair * 2U] = kRealConvHeadBiasAdjusted[out_ch];
        ddr_bias[(pair * 2U) + 1U] = kRealConvHeadBiasAdjusted[out_ch + 1U];
        for (in_ch = 0U; in_ch < REAL_POOL3_C; ++in_ch) {
            u32 offset = ((pair * REAL_POOL3_C) + in_ch) * 2U;
            ddr_weights[offset] = kRealConvHeadWeights[out_ch][in_ch];
            ddr_weights[offset + 1U] = kRealConvHeadWeights[out_ch + 1U][in_ch];
        }
    }
    __asm__ volatile ("dsb sy" : : : "memory");
}

static int run_real_convhead_gap_fc_batch6(void)
{
    volatile s32 *const ddr_features = (volatile s32 *)DDR_FEATURE_BASE;
    volatile s32 *const ddr_scores = (volatile s32 *)DDR_SCORE_BASE;
    s32 gap_sum_zero_based[REAL_CONV_OUT_C];
    s32 gap_feature[REAL_GAP_FEATURE_LEN];
    s32 fc_raw[REAL_NUM_CLASSES];
    s32 fc_q29[REAL_NUM_CLASSES];
    u32 value = 0U;
    u32 debug0 = 0U;
    u32 sample_idx;
    u32 y;
    u32 x;
    u32 in_ch;
    u32 out_ch;
    u32 cls;

    stage_conv_head_pair_parameters();

    for (sample_idx = 0U; sample_idx < REAL_BATCH6_NUM_SAMPLES; ++sample_idx) {
        s32 best_score = -2147483647 - 1;
        int best_index = 0;

        /* The preceding sample finishes its classifier with e32/VL=1.
         * Restore the two-lane convolution configuration at every sample
         * boundary so the next conv_head pair cannot inherit VL=1. */
        set_stage(0x200U);
        clear_sticky();
        issue_inst(0x10000400U, INST_VSETIVLI_E32_VL2, 0U, 0U, 0U);
        if (wait_config_e32_m1(2U, &value) != 0) {
            probe_store(20U, value);
            return FAIL_REAL_CONV_CFG;
        }
        probe_store(20U, value);

        for (out_ch = 0U; out_ch < REAL_CONV_OUT_C; ++out_ch) {
            gap_sum_zero_based[out_ch] = 0;
        }

        probe_store(8U, sample_idx);
        for (y = 0U; y < REAL_POOL3_H; ++y) {
            probe_store(9U, y);
            for (x = 0U; x < REAL_POOL3_W; ++x) {
                probe_store(10U, x);
                for (in_ch = 0U; in_ch < REAL_POOL3_C; ++in_ch) {
                    ddr_features[in_ch] = kRealBatch6Pool3Input[sample_idx][y][x][in_ch];
                }
                __asm__ volatile ("dsb sy" : : : "memory");

                for (out_ch = 0U; out_ch < REAL_CONV_OUT_C; out_ch += 2U) {
                    s64 raw_acc0 = (s64)kRealConvHeadBiasAdjusted[out_ch];
                    s64 raw_acc1 = (s64)kRealConvHeadBiasAdjusted[out_ch + 1U];
                    u32 pair = out_ch / 2U;
                    u32 bias_addr = DDR_CONV_BIAS_BASE + (pair * 8U);
                    int lsu_rc;

                    if ((out_ch & 0x0FU) == 0U) {
                        probe_store(11U, (y << 16) | (x << 8) | out_ch);
                    }

                    lsu_rc = issue_lsu_only(0x300U + pair, 0x10000404U,
                                            INST_VLE32_V8_A0, bias_addr, &debug0);
                    if (lsu_rc != 0) {
                        probe_lsu_events();
                        probe_store(54U, sample_idx);
                        probe_store(55U, y);
                        probe_store(56U, x);
                        probe_store(57U, out_ch);
                        probe_store(58U, bias_addr);
                        probe_store(59U, (u32)lsu_rc);
                        return FAIL_REAL_CONV_LOAD;
                    }

                    /* PROJECT_LOCAL diagnostic: prove both loaded bias lanes
                     * before the first multiply-accumulate of the known
                     * failing real-model position. */
                    if ((sample_idx == 1U) && (y == 0U) && (x == 0U) &&
                        (out_ch == 0U)) {
                        /* PROJECT_LOCAL diagnostic: sample the core's
                         * retirement packet before another instruction can
                         * replace it.  For VLEN=64, two active e32 elements
                         * require ROB_META0[15:0] == 16'hFFFF. */
                        u32 rob_data1 = Xil_In32(WRAPPER_BASE + REG_ROB_DATA1);
                        u32 rob_meta0 = Xil_In32(WRAPPER_BASE + REG_ROB_META0);
                        lsu_rc = issue_lsu_only(0x390U, 0x10000406U,
                                                INST_VSE32_V8_A0,
                                                DDR_SCORE_BASE, &debug0);
                        if ((lsu_rc != 0) ||
                            (ddr_scores[0] != kRealConvHeadBiasAdjusted[0]) ||
                            (ddr_scores[1] != kRealConvHeadBiasAdjusted[1])) {
                            probe_store(54U, sample_idx);
                            probe_store(55U, y);
                            probe_store(56U, x);
                            probe_store(57U, out_ch);
                            probe_store(58U, (u32)ddr_scores[0]);
                            probe_store(59U, (u32)ddr_scores[1]);
                            probe_store(60U,
                                        (u32)kRealConvHeadBiasAdjusted[0]);
                            probe_store(61U,
                                        (u32)kRealConvHeadBiasAdjusted[1]);
                            probe_store(62U, rob_meta0);
                            probe_store(63U, rob_data1);
                            probe_lsu_events();
                            return FAIL_REAL_CONV_LOAD;
                        }
                    }

                    for (in_ch = 0U; in_ch < REAL_POOL3_C; ++in_ch) {
                        u32 weight_addr = DDR_CONV_WEIGHT_BASE +
                            (((pair * REAL_POOL3_C) + in_ch) * 8U);
                        s32 feature = kRealBatch6Pool3Input[sample_idx][y][x][in_ch];

                        raw_acc0 += (s64)feature * (s64)kRealConvHeadWeights[out_ch][in_ch];
                        raw_acc1 += (s64)feature * (s64)kRealConvHeadWeights[out_ch + 1U][in_ch];
                        lsu_rc = issue_lsu_only(0x400U + in_ch, 0x10000408U,
                                                INST_VLE32_V9_A0, weight_addr, &debug0);
                        if (lsu_rc != 0) {
                            probe_lsu_events();
                            probe_store(54U, sample_idx);
                            probe_store(55U, y);
                            probe_store(56U, x);
                            probe_store(57U, out_ch);
                            probe_store(58U, weight_addr);
                            probe_store(59U, (u32)lsu_rc);
                            return FAIL_REAL_CONV_LOAD;
                        }
                        if (issue_only(0x500U + in_ch, 0x1000040CU,
                                       INST_VMACC_VX_V8_A0_V9, (u32)feature) != 0) {
                            return FAIL_CONTROL_STUCK;
                        }

                        /* PROJECT_LOCAL diagnostic: locate the first bad
                         * e32 lane in the real sample that exposed VL=2. */
                        if ((sample_idx == 1U) && (y == 0U) && (x == 0U) &&
                            (out_ch == 0U)) {
                            lsu_rc = issue_lsu_only(0x580U + in_ch, 0x1000040EU,
                                                    INST_VSE32_V8_A0,
                                                    DDR_SCORE_BASE, &debug0);
                            if ((lsu_rc != 0) ||
                                (ddr_scores[0] != (s32)raw_acc0) ||
                                (ddr_scores[1] != (s32)raw_acc1)) {
                                probe_store(54U, sample_idx);
                                probe_store(55U, y);
                                probe_store(56U, x);
                                probe_store(57U, in_ch);
                                probe_store(58U, (u32)ddr_scores[0]);
                                probe_store(59U, (u32)ddr_scores[1]);
                                probe_store(60U, (u32)raw_acc0);
                                probe_store(61U, (u32)raw_acc1);
                                probe_store(62U, (u32)feature);
                                probe_store(63U,
                                            (u32)kRealConvHeadWeights[out_ch + 1U][in_ch]);
                                return FAIL_REAL_CONV_MAC;
                            }
                        }
                    }

                    lsu_rc = issue_lsu_only(0x600U + pair, 0x10000410U,
                                            INST_VSE32_V8_A0, DDR_SCORE_BASE, &debug0);
                    if (lsu_rc != 0) {
                        probe_lsu_events();
                        probe_store(54U, sample_idx);
                        probe_store(55U, y);
                        probe_store(56U, x);
                        probe_store(57U, out_ch);
                        probe_store(58U, debug0);
                        return FAIL_REAL_CONV_STORE;
                    }
                    __asm__ volatile ("dsb sy" : : : "memory");

                    if ((ddr_scores[0] != (s32)raw_acc0) ||
                        (ddr_scores[1] != (s32)raw_acc1)) {
                        probe_store(54U, sample_idx);
                        probe_store(55U, y);
                        probe_store(56U, x);
                        probe_store(57U, out_ch);
                        probe_store(58U, (u32)ddr_scores[0]);
                        probe_store(59U, (u32)ddr_scores[1]);
                        probe_store(60U, (u32)raw_acc0);
                        probe_store(61U, (u32)raw_acc1);
                        probe_store(62U, debug0);
                        return FAIL_REAL_CONV_MAC;
                    }

                    gap_sum_zero_based[out_ch] +=
                        quantize_conv_head_output((s32)raw_acc0, out_ch) - REAL_CONV_OUT_ZP;
                    gap_sum_zero_based[out_ch + 1U] +=
                        quantize_conv_head_output((s32)raw_acc1, out_ch + 1U) - REAL_CONV_OUT_ZP;
                }
            }
        }

        for (out_ch = 0U; out_ch < REAL_GAP_FEATURE_LEN; ++out_ch) {
            gap_feature[out_ch] = quantize_gap_output(gap_sum_zero_based[out_ch]);
            if (gap_feature[out_ch] != kRealBatch6GapExpectedBoard[sample_idx][out_ch]) {
                probe_store(54U, sample_idx);
                probe_store(55U, out_ch);
                probe_store(56U, (u32)gap_feature[out_ch]);
                probe_store(57U, (u32)kRealBatch6GapExpectedBoard[sample_idx][out_ch]);
                probe_store(58U, (u32)kRealBatch6GapExpectedTflite[sample_idx][out_ch]);
                return FAIL_REAL_GAP;
            }
            ddr_features[out_ch] = gap_feature[out_ch];
        }
        __asm__ volatile ("dsb sy" : : : "memory");

        /* The final classifier remains on the already proven scalar path. */
        set_stage(0x700U);
        clear_sticky();
        issue_inst(0x10000414U, INST_VSETIVLI_E32, 0U, 0U, 0U);
        if (wait_config_e32_m1(1U, &value) != 0) {
            probe_store(20U, value);
            return FAIL_REAL_CONV_CFG;
        }

        for (cls = 0U; cls < REAL_NUM_CLASSES; ++cls) {
            s64 raw_acc = (s64)kRealChainFcBiasAdjusted[cls];

            if (issue_only(0x780U + cls, 0x10000418U, INST_VMV_S_X_V8_A0,
                           (u32)kRealChainFcBiasAdjusted[cls]) != 0) {
                return FAIL_CONTROL_STUCK;
            }
            for (out_ch = 0U; out_ch < REAL_GAP_FEATURE_LEN; ++out_ch) {
                u32 feature_addr = DDR_FEATURE_BASE + (out_ch * 4U);
                s32 weight = kRealChainFcWeights[cls][out_ch];
                int lsu_rc;

                raw_acc += (s64)gap_feature[out_ch] * (s64)weight;
                lsu_rc = issue_lsu_only(0x800U + out_ch, 0x1000041CU,
                                        INST_VLE32_V9_A0, feature_addr, &debug0);
                if (lsu_rc != 0) {
                    probe_lsu_events();
                    probe_store(54U, sample_idx);
                    probe_store(55U, cls);
                    probe_store(56U, out_ch);
                    probe_store(57U, feature_addr);
                    probe_store(58U, (u32)lsu_rc);
                    return FAIL_REAL_CONV_LOAD;
                }
                if (issue_only(0x880U + out_ch, 0x10000420U,
                               INST_VMACC_VX_V8_A0_V9, (u32)weight) != 0) {
                    return FAIL_CONTROL_STUCK;
                }
            }

            fc_raw[cls] = (s32)raw_acc;
            if (issue_expect_async(0x900U + cls, 0x10000424U, INST_VMV_X_S_A2_V8, 0U,
                                   expected_async_rd(12U, (u32)fc_raw[cls]), 24U + cls) != 0 ||
                fc_raw[cls] != kRealBatch6FcExpectedRawBoard[sample_idx][cls]) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)fc_raw[cls]);
                probe_store(57U, (u32)kRealBatch6FcExpectedRawBoard[sample_idx][cls]);
                return FAIL_REAL_FC_RAW;
            }

            fc_q29[cls] = quantize_fc_output(fc_raw[cls], cls);
            if (fc_q29[cls] != kRealBatch6FcExpectedQuant[sample_idx][cls]) {
                probe_store(54U, sample_idx);
                probe_store(55U, cls);
                probe_store(56U, (u32)fc_q29[cls]);
                probe_store(57U, (u32)kRealBatch6FcExpectedQuant[sample_idx][cls]);
                return FAIL_REAL_FC_Q29;
            }
            if (fc_q29[cls] > best_score) {
                best_score = fc_q29[cls];
                best_index = (int)cls;
            }
        }

        if (best_index != kRealBatch6ExpectedPred[sample_idx]) {
            probe_store(54U, sample_idx);
            probe_store(55U, (u32)best_index);
            probe_store(56U, (u32)kRealBatch6ExpectedPred[sample_idx]);
            probe_store(57U, (u32)best_score);
            return FAIL_REAL_PRED;
        }
        probe_store(54U + sample_idx, (u32)best_index);
        if (sample_idx == (REAL_BATCH6_NUM_SAMPLES - 1U)) {
            probe_store(60U, REAL_BATCH6_NUM_SAMPLES);
            probe_store(61U, (u32)kRealBatch6FcExpectedQuant[0][0]);
            probe_store(62U, (u32)kRealBatch6FcExpectedQuant[2][2]);
            probe_store(63U, (u32)best_score);
        }
    }
    return 0;
}

int main(void)
{
    int rc;

    Xil_DCacheDisable();
    Xil_ICacheDisable();

    init_probe_area();

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT, data_abort_handler, 0);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, prefetch_abort_handler, 0);
    Xil_ExceptionEnable();

    Xil_SetTlbAttributes(PROBE_RESULT_BASE, DEVICE_MEMORY);
    Xil_SetTlbAttributes(WRAPPER_BASE, DEVICE_MEMORY);

    xil_printf("RVV accel PS gesture postprocess start\r\n");

    rc = run_real_convhead_gap_fc_batch6();
    if (rc != 0) {
        set_failure((u32)rc);
        xil_printf("real convhead gap fc batch6 failed: 0x%08x\r\n", (unsigned)rc);
        while (1) {
            usleep(100000U);
        }
    }

    set_stage(0xF0U);
    probe_store(0U, RESULT_PASS);
    xil_printf("RVV accel PS gesture postprocess done\r\n");

    while (1) {
        usleep(100000U);
    }

    return 0;
}
