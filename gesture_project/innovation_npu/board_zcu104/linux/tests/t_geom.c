/*
 * Host-side test for the parts of gf_camera.c that are pure geometry.
 *
 * It pulls the real translation unit in (with main renamed out of the way) so
 * the thing under test is the shipped code, not a paraphrase of it.  The
 * rotation index math is exactly the kind of thing that looks obviously right
 * and is 90 degrees off, and finding that out on the board costs a session.
 */
#define main gf_camera_main_unused
#include "gf_camera.c"
#undef main

#include <stdio.h>
#include <string.h>

static int fails;
#define CHK(cond, ...) do { if (!(cond)) { ++fails; \
    printf("  FAIL  "); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* Expected output of a 192x192 -> 96x96 box average (a clean 2:1 decimation)
 * when the source encodes its own coordinates: cell (ox,oy) averages
 * x in [2ox, 2ox+1] and y in [2oy, 2oy+1], so R = 2*ox+1 and G = 2*oy+1.
 *
 * The rotation expectations below are written out independently of rot_cell(),
 * straight from the definition "rotate the image D degrees clockwise":
 *   input (x,y) -> output (h-1-y, x)
 * so output (ox,oy) must show what unrotated output showed at:
 *   90  -> (oy, 95-ox)
 *   180 -> (95-ox, 95-oy)
 *   270 -> (95-oy, ox)
 */
static void expect(int rot, int ox, int oy, int *er, int *eg)
{
    int cx = ox, cy = oy;
    switch (rot) {
    case 90:  cx = oy;     cy = 95 - ox; break;
    case 180: cx = 95 - ox; cy = 95 - oy; break;
    case 270: cx = 95 - oy; cy = ox;     break;
    default: break;
    }
    *er = 2 * cx + 1;
    *eg = 2 * cy + 1;
}

int main(int argc, char **argv)
{
    enum { SW = 192, SH = 192 };
    static uint8_t src[SW * SH * 3];
    static uint8_t rot0[OUT_RGB_BYTES];
    static uint8_t dst[OUT_RGB_BYTES];
    static const int rots[4] = { 0, 90, 180, 270 };
    int x, y, i, ox, oy;

    (void)argc; (void)argv;

    for (y = 0; y < SH; ++y)
        for (x = 0; x < SW; ++x) {
            src[(y * SW + x) * 3 + 0] = (uint8_t)x;
            src[(y * SW + x) * 3 + 1] = (uint8_t)y;
            src[(y * SW + x) * 3 + 2] = 0;
        }

    printf("== resize_rgb96 geometry ==\n");

    /* ---- rotation 0: the baseline ---------------------------------------- */
    resize_rgb96(src, SW, rot0, 0, 0, 0, SW, SH);
    for (oy = 0; oy < OUT_H; oy += 7)
        for (ox = 0; ox < OUT_W; ox += 11) {
            int er, eg;
            expect(0, ox, oy, &er, &eg);
            CHK(rot0[(oy * OUT_W + ox) * 3 + 0] == er &&
                rot0[(oy * OUT_W + ox) * 3 + 1] == eg,
                "rot0(%d,%d) = (%u,%u) want (%d,%d)", ox, oy,
                rot0[(oy * OUT_W + ox) * 3 + 0], rot0[(oy * OUT_W + ox) * 3 + 1], er, eg);
        }
    printf("  rot0    baseline sampled\n");

    /* ---- every rotation, every pixel ------------------------------------- */
    for (i = 1; i < 4; ++i) {
        int bad = 0;
        resize_rgb96(src, SW, dst, rots[i], 0, 0, SW, SH);
        for (oy = 0; oy < OUT_H; ++oy)
            for (ox = 0; ox < OUT_W; ++ox) {
                int er, eg;
                expect(rots[i], ox, oy, &er, &eg);
                if (dst[(oy * OUT_W + ox) * 3 + 0] != er ||
                    dst[(oy * OUT_W + ox) * 3 + 1] != eg) {
                    if (bad < 3)
                        printf("  FAIL  rot%d(%d,%d) = (%u,%u) want (%d,%d)\n", rots[i], ox, oy,
                               dst[(oy * OUT_W + ox) * 3 + 0], dst[(oy * OUT_W + ox) * 3 + 1],
                               er, eg);
                    ++bad; ++fails;
                }
            }
        if (!bad) printf("  rot%-4d all %d pixels correct\n", rots[i], OUT_W * OUT_H);
    }

    /* ---- 180 must be exactly "read the unrotated image backwards" -------- */
    resize_rgb96(src, SW, dst, 180, 0, 0, SW, SH);
    {
        int n = 0;
        for (y = 0; y < OUT_H; ++y)
            for (x = 0; x < OUT_W; ++x) {
                const uint8_t *a = &dst[(y * OUT_W + x) * 3];
                const uint8_t *b = &rot0[((OUT_H - 1 - y) * OUT_W + (OUT_W - 1 - x)) * 3];
                if (memcmp(a, b, 3) != 0) ++n;
            }
        CHK(n == 0, "rot180 is not a pure reversal (%d pixels differ)", n);
        if (!n) printf("  rot180  equals the unrotated image read backwards\n");
    }

    /* ---- 90 then 270 must undo each other through the sampling loop ------ */
    {
        static uint8_t t1[OUT_RGB_BYTES];
        int n;
        resize_rgb96(src, SW, t1, 90, 0, 0, SW, SH);
        /* Feed the rotated result back in at 96x96 with rot 270: since it is
         * already 96x96 the box average is a 1:1 copy, so this composes the
         * two rotations exactly. */
        resize_rgb96(t1, OUT_W, dst, 270, 0, 0, OUT_W, OUT_H);
        n = memcmp(dst, rot0, OUT_RGB_BYTES) ? 1 : 0;
        CHK(n == 0, "rot90 then rot270 is not the identity");
        if (!n) printf("  rot90+rot270 composes back to the original\n");
    }

    /* ---- the --crop window ------------------------------------------------
     * The source encodes its own coordinates, so a window is easy to verify:
     * with a 2x crop of a 192x192 frame the window is the central 96x96 at
     * (48,48), the box average becomes 1:1, and the output must read out as
     * R = 48+ox, G = 48+oy.  Getting the window offset wrong (e.g. cropping
     * from the origin instead of the centre) is exactly the bug this catches. */
    {
        int bad = 0;
        resize_rgb96(src, SW, dst, 0, 48, 48, 96, 96);
        for (oy = 0; oy < OUT_H; ++oy)
            for (ox = 0; ox < OUT_W; ++ox) {
                int er = 48 + ox, eg = 48 + oy;
                if (dst[(oy * OUT_W + ox) * 3 + 0] != er ||
                    dst[(oy * OUT_W + ox) * 3 + 1] != eg) {
                    if (bad < 3)
                        printf("  FAIL  crop2x(%d,%d) = (%u,%u) want (%d,%d)\n", ox, oy,
                               dst[(oy * OUT_W + ox) * 3 + 0],
                               dst[(oy * OUT_W + ox) * 3 + 1], er, eg);
                    ++bad;
                }
            }
        fails += bad;
        if (!bad) printf("  crop    centred 2x window reads the middle of the frame\n");
    }

    /* crop_window() itself: the common cases, including the clamps. */
    {
        int x0, y0, w, h;
        crop_window(640, 480, 1.0,  &x0, &y0, &w, &h);
        CHK(x0 == 0 && y0 == 0 && w == 640 && h == 480, "crop 1.0 is not the whole frame (%d,%d %dx%d)", x0, y0, w, h);
        crop_window(640, 480, 2.0, &x0, &y0, &w, &h);
        CHK(x0 == 160 && y0 == 120 && w == 320 && h == 240, "crop 2.0 is not the centre (%d,%d %dx%d)", x0, y0, w, h);
        crop_window(640, 480, 4.0, &x0, &y0, &w, &h);
        CHK(x0 == 240 && y0 == 180 && w == 160 && h == 120, "crop 4.0 is not the centre (%d,%d %dx%d)", x0, y0, w, h);
        /* Clamp: a crop so aggressive that the window would fall below the model
         * input must stop at the input size, not produce a 1-pixel window. */
        crop_window(640, 480, 32.0, &x0, &y0, &w, &h);
        CHK(w >= OUT_W && h >= OUT_H && x0 >= 0 && y0 >= 0 &&
            x0 + w <= 640 && y0 + h <= 480,
            "crop 32.0 escapes the frame or collapses (%d,%d %dx%d)", x0, y0, w, h);
        /* Degenerate source (smaller than the model input): must still be inside. */
        crop_window(64, 64, 4.0, &x0, &y0, &w, &h);
        CHK(x0 == 0 && y0 == 0 && w == 64 && h == 64,
            "crop of a 64x64 source should clamp to the source (%d,%d %dx%d)", x0, y0, w, h);
        printf("  crop_window clamps and centre offsets correct\n");
    }

    /* ---- odd geometry: the box bounds must not read out of range --------- */
    {
        /* 640x480 is the real camera; just make sure it runs and stays inside
         * the source (ASAN would catch an overrun; here we only leak-check the
         * corner values). */
        static uint8_t big[640 * 480 * 3];
        memset(big, 0x5A, sizeof big);
        resize_rgb96(big, 640, dst, 180, 0, 0, 640, 480);
        CHK(dst[0] == 0x5A && dst[OUT_RGB_BYTES - 1] == 0x5A,
            "640x480 rot180 produced unexpected corner values");
        printf("  640x480 rot180 handled\n");
    }

    /* The BMP encoder is static in gf_view.c, so it is not reachable from here;
     * t_view.c covers it end to end over HTTP instead (and checks every pixel
     * against the pattern, which is a stronger test than a header check). */

    printf("\n%s (%d failure%s)\n", fails ? "FAIL" : "PASS", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
