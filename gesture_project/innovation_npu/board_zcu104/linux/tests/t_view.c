/*
 * Host-side test for gf_view.c: the HTTP surface, the BMP encoding, and the
 * claim that publishing costs nothing when nobody is watching.
 *
 * The zero-cost claim is tested *deterministically* rather than by timing:
 * publish pattern 1, let the interest window expire, publish pattern 2, then
 * read the stream back -- it must still show pattern 1, because pattern 2's
 * publish had no reason to copy anything.  The timing numbers are printed as
 * supporting evidence only; a VM makes them too noisy to assert tightly.
 */
#include "gf_view.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* Stand-in for the driver's real function.  This test deliberately does not link
 * gf_npu.c -- that would drag in the generated weight headers for no reason,
 * since nothing here depends on the model.
 *
 * These must be distinct, stable pointers: the point of gf_npu_class_name() is
 * that it returns a pointer into a static table, and a stub that formats into
 * one shared buffer looks correct until two calls appear as arguments to the
 * same printf, at which point both arguments alias the same storage. */
const char *gf_npu_class_name(uint32_t i)
{
    static const char *const names[18] = {
        "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8",
        "c9", "c10", "c11", "c12", "c13", "c14", "c15", "c16", "c17"
    };
    static const char unknown[] = "c?";
    return i < 18u ? names[i] : unknown;
}

#define PW 96
#define PH 96
#define SW 640
#define SH 480

/* The scene stream is now the centred crop the model was fed, i.e. a *window*
 * of the decoded frame, so it is published with a row stride.  These exercise
 * exactly that: a 320x240 window at (160,120) inside a 640x480 frame. */
#define VX 160
#define VY 120
#define VW 320
#define VH 240

static int fails;
#define CHK(cond, ...) do { if (!(cond)) { ++fails; \
    printf("  FAIL  "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t g_prev[PW * PH * 3];
static uint8_t g_full[SW * SH * 3];       /* whole decoded frame */
static uint8_t g_scene[VW * VH * 3];      /* the window inside it, packed */
static uint8_t p1_prev[PW * PH * 3];      /* pattern 1, kept for comparison */
static uint8_t p1_scene[VW * VH * 3];

/* Pack the published window out of the full frame, which is what the browser
 * must end up seeing. */
static void pack_window(uint8_t *dst, const uint8_t *full)
{
    int y;
    for (y = 0; y < VH; ++y)
        memcpy(dst + (size_t)y * VW * 3,
               full + ((size_t)(y + VY) * SW + VX) * 3, (size_t)VW * 3);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

static void fill_pattern(uint8_t *dst, int n, int id)
{
    int k;
    for (k = 0; k < n; ++k) {
        dst[k * 3 + 0] = (uint8_t)(k * 3 + id);
        dst[k * 3 + 1] = (uint8_t)((k * 3 + 1) ^ (id * 37));
        dst[k * 3 + 2] = (uint8_t)(0x5A ^ id);
    }
}

/* One request, whole response (the server closes because we ask it to). */
static char *get(int port, const char *path, size_t *len_out)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa;
    char req[256];
    char *buf;
    const size_t cap = 4u << 20;
    size_t got = 0;
    int n;

    if (fd < 0) return NULL;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return NULL; }

    n = snprintf(req, sizeof req,
                 "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path);
    if (send(fd, req, (size_t)n, 0) != n) { close(fd); return NULL; }

    buf = (char *)malloc(cap);
    if (!buf) { close(fd); return NULL; }
    for (;;) {
        ssize_t r = recv(fd, buf + got, cap - 1 - got, 0);
        if (r == 0) break;
        if (r < 0) break;
        got += (size_t)r;
        if (got >= cap - 1) break;
    }
    close(fd);
    buf[got] = '\0';
    if (len_out) *len_out = got;
    return buf;
}

static const char *body_of(const char *resp)
{
    const char *p = strstr(resp, "\r\n\r\n");
    return p ? p + 4 : NULL;
}

/* Little-endian field readers.  The casts matter: plain `char` is signed on
 * x86, so 0x80 would come back as -128 and a 640-pixel width would look like a
 * broken header.  (That is exactly how this test first "failed".) */
static uint32_t rd32(const char *p)
{
    return (uint32_t)(unsigned char)p[0] |
           ((uint32_t)(unsigned char)p[1] << 8) |
           ((uint32_t)(unsigned char)p[2] << 16) |
           ((uint32_t)(unsigned char)p[3] << 24);
}

static uint32_t rd16(const char *p)
{
    return (uint32_t)(unsigned char)p[0] | ((uint32_t)(unsigned char)p[1] << 8);
}

/* Header sanity plus a pixel comparison against the pattern, honouring the
 * bottom-up row order the encoder writes.  sample_step > 1 checks every n-th
 * pixel (used for the 640x480 frame). */
static int check_bmp(const char *resp, const char *what,
                     const uint8_t *expect, int w, int h, int sample_step)
{
    const char *b;
    uint32_t stride = ((uint32_t)w * 3u + 3u) & ~3u;
    uint32_t pix = stride * (uint32_t)h;
    const char *cl;
    int bad = 0, row, checked = 0;

    if (!resp) { printf("  FAIL  %s: no response\n", what); ++fails; return 1; }
    if (strncmp(resp, "HTTP/1.1 200", 12) != 0) {
        printf("  FAIL  %s: status is '%.14s'\n", what, resp);
        ++fails; return 1;
    }
    b = body_of(resp);
    if (!b) { printf("  FAIL  %s: no body\n", what); ++fails; return 1; }

    if (b[0] != 'B' || b[1] != 'M') { printf("  FAIL  %s: no BMP magic\n", what); ++fails; return 1; }
    if (b[14] != 40) { printf("  FAIL  %s: DIB header size %d\n", what, (int)b[14]); ++fails; return 1; }
    {
        int bw = (int)rd32(b + 18);
        int bh = (int)rd32(b + 22);
        int bpp = (int)rd16(b + 28);
        if (bw != w || bh != h || bpp != 24) {
            int k;
            printf("  FAIL  %s: header says %dx%d %dbpp, want %dx%d 24bpp\n",
                   what, bw, bh, bpp, w, h);
            printf("        body[0..31]  =");
            for (k = 0; k < 32; ++k) printf(" %02X", (unsigned)(unsigned char)b[k]);
            printf("\n        first 80 bytes of the response: %.80s\n", resp);
            ++fails; return 1;
        }
    }
    cl = strstr(resp, "Content-Length: ");
    if (!cl || strtol(cl + 16, NULL, 10) != (long)(54u + pix)) {
        printf("  FAIL  %s: Content-Length is not %u\n", what, 54u + pix);
        ++fails; return 1;
    }

    for (row = h - 1; row >= 0; --row) {
        const uint8_t *src = expect + (size_t)row * (size_t)w * 3;
        const uint8_t *dst = (const uint8_t *)b + 54 + (size_t)(h - 1 - row) * stride;
        int x;
        for (x = 0; x < w; ++x) {
            const uint8_t *a = src + x * 3;
            const uint8_t *c = dst + x * 3;
            if (sample_step > 1 && ((row * w + x) % sample_step) != 0) continue;
            ++checked;
            if (a[0] != c[0] || a[1] != c[1] || a[2] != c[2]) {
                if (bad < 3)
                    printf("  FAIL  %s: pixel (%d,%d) = (%u,%u,%u) want (%u,%u,%u)\n",
                           what, x, row, c[0], c[1], c[2], a[0], a[1], a[2]);
                ++bad;
            }
        }
    }
    if (bad) { printf("  FAIL  %s: %d pixels wrong\n", what, bad); ++fails; return 1; }
    printf("  OK    %-24s %dx%d BMP, %u pixel bytes, %d sampled, all exact\n",
           what, w, h, pix, checked);
    return 0;
}

static void publish_frame(long frame, int cls)
{
    gf_view_frame f;
    memset(&f, 0, sizeof f);
    f.frame = frame;
    f.uptime_s = (double)frame / 15.0;
    f.fps = 14.8;
    f.cls = cls;
    f.ms_total = 27.3;
    f.ms_decode = 8.1;
    f.ms_resize = 1.2;
    f.ms_npu = 17.0;
    gf_view_publish(&f, g_prev,
                    g_full + ((size_t)VY * SW + VX) * 3, VW, VH, SW * 3);
}

static double time_publish(long n)
{
    double t0, t1;
    long i;
    for (i = 0; i < n; ++i)
        publish_frame(i, (int)(i % 18));
    t0 = 0; t1 = 0;
    /* The loop above is deliberately outside the timed region's bookkeeping:
     * re-run cleanly so the measurement is of publish only. */
    t0 = now_s();
    for (i = 0; i < n; ++i)
        publish_frame(i, (int)(i % 18));
    t1 = now_s();
    return (t1 - t0) / (double)n * 1.0e9;      /* ns per publish */
}

/* One plain memcpy of the preview's size, as the yardstick for the numbers
 * above: "publishing while watched costs about one memcpy" is the claim. */
static double time_memcpy(long n, void *dst, const void *src, size_t sz)
{
    double t0, t1;
    long i;
    for (i = 0; i <= n / 10; ++i) memcpy(dst, src, sz);
    t0 = now_s();
    for (i = 0; i < n; ++i) memcpy(dst, src, sz);
    t1 = now_s();
    return (t1 - t0) / (double)n * 1.0e9;
}

int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 18080;
    const char *page = argc > 2 ? argv[2] : NULL;
    char *resp;
    size_t len = 0;
    int i;

    if (gf_view_start(port, page) != 0) {
        printf("FAIL: gf_view_start(%d) failed\n", port);
        return 1;
    }
    gf_view_set_camera("MJPEG", VW, VH, 0, 400, 1.0);
    gf_view_count_error(GF_VIEW_ERR_JPEG);
    gf_view_count_error(GF_VIEW_ERR_JPEG);
    gf_view_count_error(GF_VIEW_ERR_NPU);

    printf("== HTTP ==\n");

    /* 1. Nothing published yet -> the stream says so instead of hanging.
     *
     * Note this request is also what registers interest: the publisher only
     * starts copying a stream once somebody has asked for it, so the first
     * request on any stream always sees 503 and the next one sees a frame.
     * Both streams must be asked for here, or the scene publish below would be
     * dropped as uninteresting. */
    resp = get(port, "/preview.bmp", &len);
    CHK(resp && strncmp(resp, "HTTP/1.1 503", 12) == 0,
        "empty preview should be 503, got '%s'", resp ? resp : "(null)");
    free(resp);
    resp = get(port, "/scene.bmp", &len);
    CHK(resp && strncmp(resp, "HTTP/1.1 503", 12) == 0,
        "empty scene should be 503, got '%s'", resp ? resp : "(null)");
    free(resp);
    printf("  OK    empty streams -> 503 (and this is how interest is registered)\n");

    /* 2. Publish while a client is interested, then read it back. */
    fill_pattern(g_prev,  PW * PH, 1);
    fill_pattern(g_full,  SW * SH, 1);
    pack_window(g_scene, g_full);
    publish_frame(4242, 3);

    resp = get(port, "/preview.bmp", &len);
    check_bmp(resp, "/preview.bmp", g_prev, PW, PH, 1);
    free(resp);

    resp = get(port, "/scene.bmp", &len);
    check_bmp(resp, "/scene.bmp (strided window)", g_scene, VW, VH, 1);
    free(resp);

    /* 3. /stats must carry the model's numbers and the framing. */
    resp = get(port, "/stats", &len);
    if (!resp) {
        CHK(0, "/stats: no response");
    } else {
        int before = fails;
        struct { const char *needle; const char *what; } want[] = {
            { "\"frame\":4242",          "frame number" },
            { "\"cls\":3",               "class" },
            { "\"cls_name\":\"c3\"",     "class name" },
            { "\"zoom\":400",            "digital zoom" },
            { "\"crop\":1.00",           "crop factor" },
            { "\"rotate\":0",            "rotation" },
            { "\"w\":320",               "published width" },
            { "\"h\":240",               "published height" },
            { "\"fmt\":\"MJPEG\"",       "pixel format" },
            { "\"jpeg\":2",              "jpeg error counter" },
            { "\"npu\":1",               "npu error counter" },
            { "\"names\":[",             "class name table" },
            { "\"ms\":{",                "timing block" },
            { "\"hist\":[",              "class histogram" },
        };
        for (i = 0; i < (int)(sizeof want / sizeof want[0]); ++i)
            CHK(strstr(resp, want[i].needle) != NULL, "/stats is missing %s (%s)",
                want[i].what, want[i].needle);
        if (strstr(resp, "votes") || strstr(resp, "smooth"))
            CHK(0, "/stats still reports a vote/smoothing field: %s", resp);
        {
            const char *p = strstr(resp, "\"names\":[");
            const char *q;
            int commas = 0;
            for (q = p; q && *q && *q != ']'; ++q) if (*q == ',') ++commas;
            CHK(p && commas == 17, "names table has %d separators, want 17", commas);
        }
        if (fails != before) {
            printf("  ---- /stats as received ----\n%s\n  ----------------------------\n", resp);
        } else {
            printf("  OK    /stats: class, framing, timings, counters, histogram\n");
        }
        free(resp);
    }

    /* 4. The page, and the trivial routes. */
    resp = get(port, "/", &len);
    CHK(resp && strncmp(resp, "HTTP/1.1 200", 12) == 0, "/ returned no page");
    if (resp && page)
        CHK(strstr(resp, "GestureFlow-NPU") != NULL, "page is not the supplied HTML");
    printf("  OK    /  %zu bytes%s\n", len, page ? " (supplied page)" : " (placeholder)");
    free(resp);

    resp = get(port, "/favicon.ico", &len);
    CHK(resp && strncmp(resp, "HTTP/1.1 204", 12) == 0, "favicon should be 204");
    free(resp);
    resp = get(port, "/nope", &len);
    CHK(resp && strncmp(resp, "HTTP/1.1 404", 12) == 0, "unknown path should be 404");
    free(resp);
    printf("  OK    204/404 routing\n");

    /* 5. The interest gate, deterministically. ------------------------------
     * The buffer currently holds pattern 1 (that is what step 2 verified).
     * Wait out the window, publish pattern 2, and read the streams again: they
     * must still show pattern 1, because nothing asked for a frame in between
     * so the publisher had no reason to copy.  If the gate were broken this is
     * where pattern 2 would appear. */
    printf("== interest gate ==\n");
    memcpy(p1_prev, g_prev, sizeof p1_prev);
    memcpy(p1_scene, g_scene, sizeof p1_scene);
    sleep(3);
    fill_pattern(g_prev,  PW * PH, 2);
    fill_pattern(g_full,  SW * SH, 2);
    pack_window(g_scene, g_full);
    publish_frame(5000, 1);

    resp = get(port, "/preview.bmp", &len);
    check_bmp(resp, "preview, after idle", p1_prev, PW, PH, 1);
    free(resp);
    resp = get(port, "/scene.bmp", &len);
    check_bmp(resp, "scene, after idle", p1_scene, VW, VH, 1);
    free(resp);

    /* And with interest re-established the very next publish must land. */
    publish_frame(5001, 2);
    resp = get(port, "/preview.bmp", &len);
    check_bmp(resp, "preview, gate re-opened", g_prev, PW, PH, 1);
    free(resp);

    /* 6. Timing, as supporting evidence.  The gate is closed after the sleep,
     *    so measure the idle case first. */
    printf("== cost of publishing ==\n");
    sleep(3);
    {
        static uint8_t scratch[PW * PH * 3];
        double idle, active, scene, base;
        long j;

        idle = time_publish(300000);
        base = time_memcpy(200000, scratch, g_prev, sizeof scratch);

        for (j = 0; j < 4; ++j) { resp = get(port, "/preview.bmp", &len); free(resp); }
        active = time_publish(4000);

        /* The scene stream is the expensive one (320x240x3 = 230 KB, capped at
         * 5 fps).  Time a single publish that actually includes it: refresh
         * interest, let the throttle window expire, then publish once. */
        scene = 0.0;
        for (j = 0; j < 5; ++j) {
            double t0, dt;
            resp = get(port, "/preview.bmp", &len); free(resp);
            resp = get(port, "/scene.bmp", &len);   free(resp);
            usleep(250000);
            t0 = now_s();
            publish_frame(j, 3);
            dt = (now_s() - t0) * 1.0e9;
            if (scene == 0.0 || dt < scene) scene = dt;
        }

        printf("  one memcpy of the 96x96 preview     : %8.1f ns   (yardstick)\n", base);
        printf("  publish, nobody interested          : %8.1f ns   = %.5f%% of a 27.3 ms frame\n",
               idle, idle / 27.3e6 * 100.0);
        printf("  publish, preview stream watched     : %8.1f ns   = %.5f%% of a frame\n",
               active, active / 27.3e6 * 100.0);
        printf("  publish that also copies the scene  : %8.1f ns   = %.5f%% of a frame (<=5/s)\n",
               scene, scene / 27.3e6 * 100.0);

        CHK(idle < 500.0, "idle publish costs %.1f ns -- the gate is not working", idle);
        CHK(idle < active / 5.0, "idle (%.1f ns) is not clearly cheaper than active (%.1f ns)",
            idle, active);
        CHK(active - idle < 5.0 * base,
            "watched publish costs %.1f ns over idle, i.e. %.1f memcpys",
            active - idle, base > 0.0 ? (active - idle) / base : 0.0);
    }

    gf_view_stop();
    printf("\n%s (%d failure%s)\n", fails ? "FAIL" : "PASS", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
