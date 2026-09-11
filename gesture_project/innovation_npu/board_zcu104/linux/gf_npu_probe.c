/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * CLI probe around the GestureFlow NPU userspace driver.
 *
 * This is the port-validation tool: it runs the deterministic reference image
 * through the NPU and checks every value the baremetal driver checked.  Run it
 * BEFORE trusting anything the camera reports.
 *
 *   gf_npu_probe                 reference image: verify + print stats
 *   gf_npu_probe --bench 200     time 200 reference passes
 *   gf_npu_probe --ppm out.ppm   also dump the reference input the model sees
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "gf_npu.h"

static void print_stats(const gf_npu_stats *s, int print_layers)
{
    int i;
    if (print_layers) {
        printf("  per-tile PL cycles:\n");
        printf("    conv0            %10u\n", s->conv0);
        printf("    conv1+pool1      %10u\n", s->conv1_pool1);
        for (i = 0; i < 2; ++i) printf("    conv2a[%d]        %10u\n", i, s->conv2a[i]);
        for (i = 0; i < 2; ++i) printf("    conv2b+pool2[%d]  %10u\n", i, s->conv2b_pool2[i]);
        for (i = 0; i < 3; ++i) printf("    conv3a[%d]        %10u\n", i, s->conv3a[i]);
        for (i = 0; i < 3; ++i) printf("    conv3b+pool3[%d]  %10u\n", i, s->conv3b_pool3[i]);
        for (i = 0; i < 4; ++i) printf("    head1x1[%d]       %10u\n", i, s->head1x1[i]);
        printf("    gap+fc           %10u\n", s->gap_fc);
        printf("    ------------------------------\n");
        printf("    PL total         %10u cycles  (%.2f ms @100 MHz)\n",
               s->pl_cycles_total, s->pl_cycles_total / 100000.0);

        printf("  --- golden content checks (bit-exact memcmp) ---\n");
        for (i = 0; i < GF_CHK_COUNT; ++i) {
            printf("    %-6s %s\n", gf_npu_check_name[i],
                   s->content_rc[i] == 0 ? "MATCH" : "*** MISMATCH ***");
        }
        printf("    %d/%d matched\n", s->content_checked - s->content_failed,
               s->content_checked);

        printf("  --- hardware FNV registers ---\n");
        printf("    hw FNV conv0   %10u  (expect %08X)\n",
               s->hw_fnv_conv0, (unsigned)gf_npu_expected_fnv_conv0());
        printf("    hw FNV pool1   %10u  (expect %08X = pre-pool conv1 output)\n",
               s->hw_fnv_pool1, (unsigned)gf_npu_expected_fnv_pool1());

        printf("  --- software FNV1A of what the PL wrote (baseline) ---\n");
        printf("    conv0 %10u   pool1 %10u   conv2 %10u\n",
               s->sw_fnv_conv0, s->sw_fnv_pool1, s->sw_fnv_conv2);
        printf("    pool2 %10u   conv4 %10u   pool3 %10u\n",
               s->sw_fnv_pool2, s->sw_fnv_conv4, s->sw_fnv_pool3);
        printf("    head  %10u   (no golden exists for this one)\n",
               s->sw_fnv_head1x1);

        printf("  --- GAP/FC ---\n");
        printf("    gap FNV        %10u  (expect %08X)\n",
               s->gap_fnv, (unsigned)gf_npu_expected_fnv_gap());
        printf("    fc  FNV        %10u  (expect %08X)\n",
               s->fc_fnv, (unsigned)gf_npu_expected_fnv_fc());
        printf("    progress       %10u\n", s->gap_progress);
    }
    printf("  ------------------------------------------------\n");
    printf("  PL compute         %10.2f ms\n", s->pl_cycles_total / 100000.0);
    printf("  CPU total (wall)   %10.2f ms\n", s->cpu_total_ms);
    printf("    of which checks  %10.2f ms   (memcmp+FNV1A; not part of P4's budget)\n",
           s->cpu_checks_ms);
    printf("    of which weights %10.2f ms\n", s->weight_load_ms);
    printf("  CPU overhead       %10.2f ms   <- compare against the baremetal 10.04 ms\n",
           s->cpu_total_ms - s->cpu_checks_ms - s->pl_cycles_total / 100000.0);
    printf("  ------------------------------------------------\n");
}

static void write_ppm(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path); return; }
    fprintf(f, "P6\n%d %d\n255\n", GF_FULL_W, GF_FULL_H);
    fwrite(gf_npu_reference_input(), 1, GF_RGB_BYTES, f);
    fclose(f);
    printf("wrote reference input to %s (96x96 RGB, raw uint8 as the PL gets it)\n", path);
}

int main(int argc, char **argv)
{
    int bench = 0;
    const char *ppm = NULL;
    int i;
    gf_npu_stats st;
    uint32_t cls = 0U;
    const uint8_t *ref;

    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--bench") && i + 1 < argc) bench = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ppm") && i + 1 < argc) ppm = argv[++i];
        else {
            printf("usage: %s [--bench N] [--ppm out.ppm]\n", argv[0]);
            return 2;
        }
    }

    memset(&st, 0, sizeof st);
    ref = gf_npu_reference_input();

    if (gf_npu_open() != 0) return 1;
    if (gf_npu_load_weights() != 0) { gf_npu_close(); return 1; }

    if (ppm) write_ppm(ppm);

    printf("\n=== reference-image pass ===\n");
    if (gf_npu_run_frame(ref, &cls, &st) != 0) {
        printf("RESULT: FAIL (see messages above)\n");
        gf_npu_close();
        return 1;
    }
    printf("class = %u (%s), expected %u\n",
           (unsigned)cls, gf_npu_class_name(cls), (unsigned)gf_npu_expected_class());
    print_stats(&st, 1);

    if (cls != gf_npu_expected_class()) {
        printf("RESULT: FAIL (class mismatch)\n");
        gf_npu_close();
        return 1;
    }

    if (bench > 1) {
        int k;
        double t0, t1, best = 1e9, sum = 0.0;
        struct timespec ts;
        printf("\n=== benchmark: %d passes ===\n", bench);
        for (k = 0; k < bench; ++k) {
            double d;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            t0 = (double)ts.tv_sec + ts.tv_nsec / 1e9;
            if (gf_npu_run_frame(ref, &cls, NULL) != 0) {
                printf("iteration %d failed\n", k);
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &ts);
            t1 = (double)ts.tv_sec + ts.tv_nsec / 1e9;
            d = (t1 - t0) * 1000.0;
            sum += d;
            if (d < best) best = d;
        }
        printf("  mean %8.2f ms  (%6.2f fps)\n", sum / bench, 1000.0 * bench / sum);
        printf("  best %8.2f ms  (%6.2f fps)\n", best, 1000.0 / best);
    }

    printf("\nRESULT: PASS\n");
    gf_npu_close();
    return 0;
}
