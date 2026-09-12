/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * ZCU104 USB3 UVC camera -> GestureFlow NPU -> static gesture, live.
 *
 * Capture path:  V4L2 (uvcvideo) -> RGB -> area-average downscale to 96x96 ->
 *                raw uint8 into the NPU scratch buffer -> 21 tile launches ->
 *                class register.
 *
 * Two details that matter and are easy to get wrong:
 *
 *  1. The NPU's RGB loader recenters the input itself:
 *         rtl/gestureflow_hp0_rgb_loader.sv:  pixel_rgb = {~byte[7], byte[6:0]}
 *     which is XOR 0x80, i.e. q = u - 128 read as int8.  So this program must
 *     hand over RAW uint8 pixels and must NOT subtract 128.
 *
 *  2. The training pipeline used PIL's resize:
 *         Image.open(p).convert("RGB").resize((96,96), Image.BILINEAR)
 *     PIL's BILINEAR downscale is antialiased (the filter support is scaled by
 *     the decimation factor), not a naive 2-tap bilinear.  An area average (box
 *     filter) tracks it much more closely than point sampling, so that is what
 *     resize_rgb96() implements.  Nearest neighbour would alias badly on a
 *     640x480 -> 96x96 decimation.
 *
 * Build: see Makefile.  MJPEG support is optional (needs libjpeg); YUYV and
 * RGB24 work with no extra dependency.
 *
 * --rotate D turns the image D degrees clockwise before it is handed to the
 * NPU.  **The camera on this rig is currently mounted upright, so this stays
 * unset (D=0).**  It exists because the mount orientation has already changed
 * once -- it started upside down and needed 180 -- and it is a runtime switch
 * precisely so that changing it costs nothing but a command-line edit.
 *
 * When it *is* needed it has to apply to the input the model sees, not just to
 * a preview: the model was trained on upright gestures, and a flipped hand is a
 * different gesture as far as it is concerned.
 *
 * --view PORT starts a small HTTP server (gf_view.c) so the laptop browser can
 * watch the pipeline.  It is off by default and costs nothing when off.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <setjmp.h>
#include <linux/videodev2.h>

#include "gf_npu.h"
#include "gf_view.h"

/* Where 06_install_app.sh / the Yocto recipe put the viewer page. */
#define GF_VIEW_DEFAULT_PAGE "/usr/share/gf/view.html"

#ifdef GF_HAVE_JPEG
#include <jpeglib.h>
#endif

#define MAX_BUFFERS     4
#define OUT_W           96
#define OUT_H           96
#define OUT_RGB_BYTES   (OUT_W * OUT_H * 3)

/* Length of the majority-vote history.  -m is clamped to this; the array used
 * to be hard-coded to 32 with no clamp, so `-m 33` walked off the stack. */
#define MAX_VOTE_WINDOW 32

/* ------------------------------------------------------------------ util -- */
static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

static const char *fourcc_str(uint32_t f, char *buf)
{
    buf[0] = (char)( f        & 0xFF);
    buf[1] = (char)((f >> 8)  & 0xFF);
    buf[2] = (char)((f >> 16) & 0xFF);
    buf[3] = (char)((f >> 24) & 0xFF);
    buf[4] = '\0';
    return buf;
}

static void die(const char *what)
{
    fprintf(stderr, "gf_camera: %s: %s\n", what, strerror(errno));
    exit(1);
}

/* ------------------------------------------------------- resize (box) ----- */
/* Map an output cell to the source cell it must sample, for --rotate.
 *
 * `rot` is how far the camera is mounted off upright measured clockwise, so
 * the image needs turning by the same amount to come back upright.  Rotating
 * an image D degrees clockwise sends input (x,y) to output (h-1-y, x); invert
 * that to get the input cell that output (ox,oy) reads.  OUT_W == OUT_H == 96,
 * so the two bounds are interchangeable in these expressions. */
static void rot_cell(int ox, int oy, int rot, int *cx, int *cy)
{
    switch (rot) {
    case 90:  *cx = oy;               *cy = OUT_H - 1 - ox; break;
    case 180: *cx = OUT_W - 1 - ox;   *cy = OUT_H - 1 - oy; break;
    case 270: *cx = OUT_W - 1 - oy;   *cy = ox;             break;
    default:  *cx = ox;               *cy = oy;             break;
    }
}

/* Area-average downscale to 96x96.  Bounds are computed in 64-bit to avoid
 * overflow on large inputs (e.g. 1920x1080).
 *
 * Rotating inside the sampling loop is exact and free: the rotation is a
 * permutation of the 96x96 output grid, so each output cell still averages the
 * same source box it would have averaged, just assigned to a different place.
 * Rotating the *result* afterwards would be equivalent for 180 degrees and a
 * half-pixel approximation for 90/270. */
static void resize_rgb96(const uint8_t *src, int sw, int sh, uint8_t *dst, int rot)
{
    int oy, ox, c;
    if (sw < OUT_W || sh < OUT_H) {
        /* Upscaling is not needed for any sane camera; fall back to nearest so
         * the program still produces something instead of failing. */
        for (oy = 0; oy < OUT_H; ++oy) {
            for (ox = 0; ox < OUT_W; ++ox) {
                int cx, cy, sy, sx;
                rot_cell(ox, oy, rot, &cx, &cy);
                sy = (int)((int64_t)cy * sh / OUT_H);
                sx = (int)((int64_t)cx * sw / OUT_W);
                for (c = 0; c < 3; ++c)
                    dst[(oy * OUT_W + ox) * 3 + c] = src[((size_t)sy * sw + sx) * 3 + c];
            }
        }
        return;
    }
    for (oy = 0; oy < OUT_H; ++oy) {
        for (ox = 0; ox < OUT_W; ++ox) {
            int cx, cy, x0, x1, y0, y1, y, x;
            uint32_t acc[3] = {0U, 0U, 0U};
            uint32_t n = 0U;
            rot_cell(ox, oy, rot, &cx, &cy);
            y0 = (int)((int64_t)cy       * sh / OUT_H);
            y1 = (int)((int64_t)(cy + 1) * sh / OUT_H);
            if (y1 <= y0) y1 = y0 + 1;
            x0 = (int)((int64_t)cx       * sw / OUT_W);
            x1 = (int)((int64_t)(cx + 1) * sw / OUT_W);
            if (x1 <= x0) x1 = x0 + 1;
            for (y = y0; y < y1; ++y) {
                const uint8_t *row = src + (size_t)y * sw * 3;
                for (x = x0; x < x1; ++x) {
                    acc[0] += row[x * 3 + 0];
                    acc[1] += row[x * 3 + 1];
                    acc[2] += row[x * 3 + 2];
                    ++n;
                }
            }
            dst[(oy * OUT_W + ox) * 3 + 0] = (uint8_t)((acc[0] + n / 2U) / n);
            dst[(oy * OUT_W + ox) * 3 + 1] = (uint8_t)((acc[1] + n / 2U) / n);
            dst[(oy * OUT_W + ox) * 3 + 2] = (uint8_t)((acc[2] + n / 2U) / n);
        }
    }
}

/* ------------------------------------------------------------ conversions -- */
/* YUYV (V4L2_PIX_FMT_YUYV) 4:2:2 -> RGB24, BT.601 limited range.
 *   R = 1.164(Y-16) + 1.596(V-128)
 *   G = 1.164(Y-16) - 0.813(V-128) - 0.391(U-128)
 *   B = 1.164(Y-16) + 2.018(U-128)
 * The UVC camera is asked for YUYV only when MJPEG/RGB24 are unavailable; the
 * exact colour matrix matters far less than the geometry for a gesture model
 * that was trained on sRGB-ish data, but using BT.601 keeps it sane. */
static void yuyv_to_rgb(const uint8_t *src, int w, int h, uint8_t *dst)
{
    int y;
    for (y = 0; y < h; ++y) {
        const uint8_t *srow = src + (size_t)y * w * 2;
        uint8_t *drow = dst + (size_t)y * w * 3;
        int x;
        for (x = 0; x < w; x += 2) {
            int u = (int)srow[x * 2 + 1] - 128;
            int v = (int)srow[x * 2 + 3] - 128;
            int yy0 = (int)srow[x * 2 + 0];
            int yy1 = (int)srow[x * 2 + 2];
            int c0, c1, c2;
            int cl;
            for (cl = 0; cl < 2; ++cl) {
                int Y = (cl == 0 ? yy0 : yy1) - 16;
                if (Y < 0) Y = 0;
                c0 = (298 * Y + 409 * v + 128) >> 8;
                c1 = (298 * Y - 100 * v - 208 * u + 128) >> 8;
                c2 = (298 * Y + 516 * u + 128) >> 8;
                drow[(x + cl) * 3 + 0] = (uint8_t)(c0 < 0 ? 0 : (c0 > 255 ? 255 : c0));
                drow[(x + cl) * 3 + 1] = (uint8_t)(c1 < 0 ? 0 : (c1 > 255 ? 255 : c1));
                drow[(x + cl) * 3 + 2] = (uint8_t)(c2 < 0 ? 0 : (c2 > 255 ? 255 : c2));
            }
        }
    }
}

#ifdef GF_HAVE_JPEG
/* libjpeg's error handling is setjmp-based, and it is not optional.
 *
 * jpeglib.h is explicit: the caller must supply an error manager whose
 * error_exit longjmps back to a setjmp point that the caller established.
 * The default handler instead prints the message and calls exit().  So without
 * this, ONE bad frame kills the whole program -- and uvcvideo does hand us such
 * frames: after its own
 *
 *     uvcvideo 2-1:1.1: Non-zero status (-71) in video completion handler.
 *
 * an isochronous transfer can complete with bytesused == 0, libjpeg then raises
 * JERR_INPUT_EMPTY ("Empty input file"), and gf_camera exits mid-stream having
 * printed no frames at all.  That is what happened the first time a real scene
 * was pointed at the camera -- and it looks exactly like a hang or a crash
 * rather than a bad frame.
 *
 * The signatures are the pre-libjpeg-8 style on purpose; that is still what
 * jpeglib.h documents for application error managers.
 */
struct gf_jpeg_error {
    struct jpeg_error_mgr pub;
    jmp_buf               unwind;
};

static void gf_jpeg_error_exit(j_common_ptr cinfo)
{
    struct gf_jpeg_error *e = (struct gf_jpeg_error *)cinfo->err;
    char msg[JMSG_LENGTH_MAX];

    (*cinfo->err->format_message)(cinfo, msg);
    fprintf(stderr, "gf_camera: JPEG decode error: %s\n", msg);
    longjmp(e->unwind, 1);
}

/* Decode to RGB24, resizing the caller's buffer if the JPEG turns out to be a
 * different geometry than the one we asked the camera for.  A UVC driver is
 * allowed to hand back something else, and decoding past the end of a buffer
 * sized for the *requested* geometry would corrupt the heap -- which is exactly
 * what this used to do.  The destination size is therefore taken from the
 * JPEG's own header (jpeg_calc_output_dimensions), not from the request.
 *
 * Returns 0 on success, -1 on any bad frame (empty, truncated, unparseable).
 * Never exits. */
static int jpeg_to_rgb(const uint8_t *src, size_t len, int *out_w, int *out_h,
                       uint8_t **buf, size_t *cap)
{
    struct jpeg_decompress_struct cinfo;
    struct gf_jpeg_error err;
    size_t need;

    /* libjpeg cannot be handed a zero-length source. */
    if (len == 0U) {
        fprintf(stderr, "gf_camera: empty MJPEG frame, skipping\n");
        return -1;
    }

    memset(&cinfo, 0, sizeof cinfo);
    cinfo.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = gf_jpeg_error_exit;
    if (setjmp(err.unwind)) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, (unsigned char *)src, (unsigned long)len);
    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    cinfo.out_color_space = JCS_RGB;
    jpeg_calc_output_dimensions(&cinfo);

    *out_w = (int)cinfo.output_width;
    *out_h = (int)cinfo.output_height;
    need = (size_t)*out_w * (size_t)*out_h * 3U;

    if (need > *cap) {
        uint8_t *grown = realloc(*buf, need);
        if (!grown) {
            fprintf(stderr, "gf_camera: out of memory for a %dx%d decoded frame\n",
                    *out_w, *out_h);
            jpeg_destroy_decompress(&cinfo);
            return -1;
        }
        *buf = grown;
        *cap = need;
    }

    jpeg_start_decompress(&cinfo);
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = *buf + (size_t)cinfo.output_scanline * (size_t)(*out_w) * 3U;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return 0;
}
#endif

/* -------------------------------------------------------------- V4L2 side -- */
struct v4l2_state {
    int      fd;
    uint32_t pixfmt;
    int      width, height;
    void    *buf[MAX_BUFFERS];
    size_t   buflen[MAX_BUFFERS];
    uint32_t nbuf;
    int      streaming;
};

static void v4l2_cleanup(struct v4l2_state *st)
{
    uint32_t i;
    if (st->streaming) {
        enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        ioctl(st->fd, VIDIOC_STREAMOFF, &t);
        st->streaming = 0;
    }
    for (i = 0; i < st->nbuf; ++i)
        if (st->buf[i]) munmap(st->buf[i], st->buflen[i]);
    if (st->fd >= 0) close(st->fd);
    st->fd = -1;
}

static int v4l2_list_formats(int fd)
{
    struct v4l2_fmtdesc f;
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    printf("gf_camera: capture formats:\n");
    for (f.index = 0; ioctl(fd, VIDIOC_ENUM_FMT, &f) == 0; ++f.index) {
        struct v4l2_frmsizeenum s;
        char b[5];
        printf("  [%u] %s (%s)\n", f.index, fourcc_str(f.pixelformat, b),
               f.description);
        memset(&s, 0, sizeof s);
        s.pixel_format = f.pixelformat;
        for (s.index = 0; ioctl(fd, VIDIOC_ENUM_FRAMESIZES, &s) == 0; ++s.index) {
            if (s.type == V4L2_FRMSIZE_TYPE_DISCRETE)
                printf("        %ux%u\n", s.discrete.width, s.discrete.height);
            else
                printf("        %ux%u .. %ux%u (step %ux%u)\n",
                       s.stepwise.min_width, s.stepwise.min_height,
                       s.stepwise.max_width, s.stepwise.max_height,
                       s.stepwise.step_width, s.stepwise.step_height);
        }
    }
    return 0;
}

static int v4l2_try_format(int fd, uint32_t want, int w, int h,
                           struct v4l2_format *out)
{
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width       = (uint32_t)w;
    fmt.fmt.pix.height      = (uint32_t)h;
    fmt.fmt.pix.pixelformat = want;
    fmt.fmt.pix.field       = V4L2_FIELD_NONE;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) != 0) return -1;
    if (fmt.fmt.pix.pixelformat != want) return -1;   /* driver picked something else */
    *out = fmt;
    return 0;
}

static int v4l2_setup(struct v4l2_state *st, const char *dev, int want_w, int want_h)
{
    struct v4l2_format fmt;
    struct v4l2_requestbuffers req;
    struct v4l2_capability cap;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    uint32_t i;

    memset(&fmt, 0, sizeof fmt);   /* reported on the failure path below */
    memset(st, 0, sizeof *st);
    st->fd = -1;

    st->fd = open(dev, O_RDWR);
    if (st->fd < 0) die(dev);

    if (ioctl(st->fd, VIDIOC_QUERYCAP, &cap) != 0) die("VIDIOC_QUERYCAP");
    printf("gf_camera: %s driver=%s card=%s bus=%s\n", dev,
           cap.driver, cap.card, cap.bus_info);
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
        fprintf(stderr, "gf_camera: %s is not a capture device\n", dev);
        return -1;
    }

    /* Preference order: MJPEG (small frames, best frame rate) > YUYV > RGB24.
     * Trying YUYV first would work but wastes USB bandwidth; RGB24 is rarely
     * offered by UVC cameras. */
    {
        struct { uint32_t f; const char *n; int optional; } prefs[] = {
#ifdef GF_HAVE_JPEG
            { V4L2_PIX_FMT_MJPEG, "MJPEG", 0 },
            { V4L2_PIX_FMT_JPEG,  "JPEG",  0 },
#else
            { V4L2_PIX_FMT_MJPEG, "MJPEG", 1 },   /* will be skipped */
#endif
            { V4L2_PIX_FMT_YUYV,  "YUYV",  0 },
            { V4L2_PIX_FMT_RGB24, "RGB24", 0 },
        };
        size_t k;
        int ok = 0;
        for (k = 0; k < sizeof prefs / sizeof prefs[0]; ++k) {
#ifdef GF_HAVE_JPEG
            (void)prefs[k].optional;
#else
            if (prefs[k].optional) continue;
#endif
            if (v4l2_try_format(st->fd, prefs[k].f, want_w, want_h, &fmt) == 0) {
                st->pixfmt = fmt.fmt.pix.pixelformat;
                st->width  = (int)fmt.fmt.pix.width;
                st->height = (int)fmt.fmt.pix.height;
                printf("gf_camera: using %s %dx%d (bytesperline %u, sizeimage %u)\n",
                       prefs[k].n, st->width, st->height,
                       fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);
                ok = 1;
                break;
            }
        }
        if (!ok) {
            char b[5];
            fprintf(stderr, "gf_camera: no usable format at %dx%d. Got:\n", want_w, want_h);
            fourcc_str(fmt.fmt.pix.pixelformat, b);
            fprintf(stderr, "  driver reports %s %ux%u\n", b,
                    fmt.fmt.pix.width, fmt.fmt.pix.height);
            v4l2_list_formats(st->fd);
            return -1;
        }
    }

    memset(&req, 0, sizeof req);
    req.count  = MAX_BUFFERS;
    req.type   = type;
    req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(st->fd, VIDIOC_REQBUFS, &req) != 0) die("VIDIOC_REQBUFS");
    if (req.count < 2) {
        fprintf(stderr, "gf_camera: only %u buffers available\n", req.count);
        return -1;
    }
    /* The driver may hand back more than we asked for; st->buf[] is MAX_BUFFERS. */
    st->nbuf = req.count > MAX_BUFFERS ? MAX_BUFFERS : req.count;

    for (i = 0; i < st->nbuf; ++i) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof buf);
        buf.type = type;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (ioctl(st->fd, VIDIOC_QUERYBUF, &buf) != 0) die("VIDIOC_QUERYBUF");
        st->buflen[i] = buf.length;
        st->buf[i] = mmap(NULL, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                          st->fd, buf.m.offset);
        if (st->buf[i] == MAP_FAILED) die("mmap capture buffer");
    }
    for (i = 0; i < st->nbuf; ++i) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof buf);
        buf.type = type;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (ioctl(st->fd, VIDIOC_QBUF, &buf) != 0) die("VIDIOC_QBUF");
    }
    if (ioctl(st->fd, VIDIOC_STREAMON, &type) != 0) die("VIDIOC_STREAMON");
    st->streaming = 1;
    printf("gf_camera: streaming, %u buffers\n", st->nbuf);
    return 0;
}

/* Dequeue one frame.  Returns the buffer index (>= 0) on success, -1 on EAGAIN.
 *
 * The caller MUST hand the buffer back with v4l2_release() once it has finished
 * reading it -- NOT before.  Recycling it here would put it straight back in the
 * driver's fill queue, so the camera could overwrite the frame while we are
 * still converting it (a torn frame => a random misclassification).  With four
 * buffers that is unlikely but not impossible, and it is free to get right. */
static int v4l2_grab(struct v4l2_state *st, const uint8_t **data, size_t *len)
{
    struct v4l2_buffer buf;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

    memset(&buf, 0, sizeof buf);
    buf.type = type;
    buf.memory = V4L2_MEMORY_MMAP;
    if (ioctl(st->fd, VIDIOC_DQBUF, &buf) != 0) {
        if (errno == EAGAIN) return -1;
        die("VIDIOC_DQBUF");
    }
    *data = (const uint8_t *)st->buf[buf.index];
    *len  = buf.bytesused;
    return (int)buf.index;
}

static void v4l2_release(struct v4l2_state *st, int index)
{
    struct v4l2_buffer buf;
    memset(&buf, 0, sizeof buf);
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = (uint32_t)index;
    if (ioctl(st->fd, VIDIOC_QBUF, &buf) != 0) die("VIDIOC_QBUF(recycle)");
}

/* ------------------------------------------------------------------ main -- */
static void write_ppm(const char *path, const uint8_t *rgb, int w, int h)
{
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb, 1, (size_t)w * h * 3, f);
    fclose(f);
    printf("gf_camera: wrote %s (%dx%d)\n", path, w, h);
}

static void usage(const char *argv0)
{
    printf("usage: %s [options]\n"
           "  -d DEV        video device (default /dev/video0)\n"
           "  -s WxH        capture size to request (default 640x480)\n"
           "  -n N          stop after N frames (0 = forever, default 0)\n"
           "  -m N          majority-vote smoothing window in frames (default 5)\n"
           "  --rotate D    rotate the image D degrees clockwise before the NPU\n"
           "                (0/90/180/270; the ZCU104 rig needs 180)\n"
           "  --view PORT   serve a live HTTP viewer on PORT (default: off).\n"
           "                Nothing is copied unless a browser is actually\n"
           "                asking, so this does not affect the timings.\n"
           "  --view-page P HTML page the viewer serves (default %s)\n"
           "  --list        list capture formats and exit\n"
           "  --selftest    run the NPU reference selftest and exit\n"
           "  --save-ppm P  save the resized 96x96 RGB that is fed to the NPU\n"
           "                (with -n N this is the last frame, i.e. after the\n"
           "                 camera's auto-exposure has settled; otherwise frame 3)\n",
           argv0, GF_VIEW_DEFAULT_PAGE);
}

static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int s) { (void)s; g_stop = 1; }

int main(int argc, char **argv)
{
    const char *dev = "/dev/video0";
    const char *save_ppm = NULL;
    const char *view_page = GF_VIEW_DEFAULT_PAGE;
    int want_w = 640, want_h = 480;
    int max_frames = 0;
    int smooth = 5;
    int rotate = 0;
    int view_port = 0;
    int do_list = 0, do_selftest = 0;
    int i;

    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--list"))      { do_list = 1; }
        else if (!strcmp(argv[i], "--selftest")) { do_selftest = 1; }
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dev = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &want_w, &want_h) != 2) { usage(argv[0]); return 2; }
        }
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) max_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-m") && i + 1 < argc) smooth = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--save-ppm") && i + 1 < argc) save_ppm = argv[++i];
        else if (!strcmp(argv[i], "--view-page") && i + 1 < argc) view_page = argv[++i];
        else if (!strcmp(argv[i], "--view") && i + 1 < argc) view_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rotate") && i + 1 < argc) {
            rotate = gf_view_parse_rotate(argv[++i]);
            if (rotate < 0) {
                fprintf(stderr, "gf_camera: --rotate takes 0, 90, 180 or 270\n");
                return 2;
            }
        }
        else { usage(argv[0]); return 2; }
    }
    if (smooth < 1) smooth = 1;
    if (smooth > MAX_VOTE_WINDOW) smooth = MAX_VOTE_WINDOW;
    if (view_port < 0 || view_port > 65535) { usage(argv[0]); return 2; }

    /* The NPU must be up before anything else: if the PL is not configured or
     * its clock is gated, GF_MAGIC will not read back and we want to know that
     * before touching the camera. */
    if (gf_npu_open() != 0) return 1;
    if (gf_npu_load_weights() != 0) return 1;

    if (do_selftest) {
        int rc = gf_npu_selftest(NULL);
        gf_npu_close();
        return rc == 0 ? 0 : 1;
    }

    if (do_list) {
        int fd = open(dev, O_RDWR);
        if (fd < 0) die(dev);
        v4l2_list_formats(fd);
        close(fd);
        gf_npu_close();
        return 0;
    }

    {
        struct v4l2_state st;
        uint8_t *rgb_frame = NULL;
        size_t   rgb_cap = 0U;
        uint8_t  rgb96[OUT_RGB_BYTES];
        uint32_t cls = 0U;
        int history[MAX_VOTE_WINDOW];
        int hist_n = 0;
        long frame_no = 0;
        double t_prev = 0.0;
        double t_boot = now_s();

        if (v4l2_setup(&st, dev, want_w, want_h) != 0) {
            gf_npu_close();
            return 1;
        }
        /* Sized for the negotiated YUYV/RGB24 geometry.  The MJPEG path grows
         * this on demand if the decoded frame is larger. */
        rgb_cap = (size_t)st.width * (size_t)st.height * 3U;
        if (rgb_cap == 0U) { fprintf(stderr, "gf_camera: zero-sized format\n"); return 1; }
        rgb_frame = malloc(rgb_cap);
        if (!rgb_frame) die("malloc");

        if (rotate)
            printf("gf_camera: rotating the NPU input %d degrees clockwise\n", rotate);

        /* The viewer is a convenience, never a requirement: if the port is
         * taken or the box has no free socket, say so and carry on. */
        if (view_port > 0) {
            char fb[5];
            gf_view_set_camera(fourcc_str(st.pixfmt, fb), st.width, st.height, rotate);
            printf("gf_camera: --view %d requested (page %s)\n", view_port, view_page);
            if (gf_view_start(view_port, view_page) != 0) {
                fprintf(stderr, "gf_camera: viewer disabled; the pipeline is unaffected\n");
                view_port = 0;
            }
        }

        signal(SIGINT, on_sigint);

        printf("gf_camera: running ('Ctrl-C' to stop)\n");
        while (!g_stop) {
            const uint8_t *payload = NULL;
            size_t plen = 0;
            int cw = st.width, ch = st.height;
            int bidx, ok = 1;
            double t0, t1, t_dec = 0.0, t_res = 0.0, t_npu = 0.0, fps = 0.0;

            bidx = v4l2_grab(&st, &payload, &plen);
            if (bidx < 0) continue;

            t0 = now_s();

            switch (st.pixfmt) {
            case V4L2_PIX_FMT_YUYV:
                yuyv_to_rgb(payload, st.width, st.height, rgb_frame);
                break;
            case V4L2_PIX_FMT_RGB24:
                memcpy(rgb_frame, payload,
                       (size_t)st.width * st.height * 3 < plen
                           ? (size_t)st.width * st.height * 3 : plen);
                break;
#ifdef GF_HAVE_JPEG
            case V4L2_PIX_FMT_MJPEG:
            case V4L2_PIX_FMT_JPEG:
                if (jpeg_to_rgb(payload, plen, &cw, &ch, &rgb_frame, &rgb_cap) != 0) {
                    fprintf(stderr, "gf_camera: JPEG decode failed, skipping frame\n");
                    gf_view_count_error(GF_VIEW_ERR_JPEG);
                    ok = 0;
                }
                break;
#endif
            default:
                fprintf(stderr, "gf_camera: unhandled pixel format, skipping\n");
                ok = 0;
                break;
            }

            /* Everything above read only `payload`; the frame is copied, so the
             * driver may have its buffer back now. */
            v4l2_release(&st, bidx);
            t_dec = now_s();
            if (!ok) continue;

            resize_rgb96(rgb_frame, cw, ch, rgb96, rotate);
            t_res = now_s();

            if (gf_npu_run_frame(rgb96, &cls, NULL) != 0) {
                fprintf(stderr, "gf_camera: NPU run failed on frame %ld\n", frame_no);
                gf_view_count_error(GF_VIEW_ERR_NPU);
                break;
            }
            t_npu = now_s();

            /* Majority vote over a short window: a single-frame flip is noise
             * the user should not see. */
            if (hist_n < smooth) {
                history[hist_n++] = (int)cls;
            } else {
                memmove(history, history + 1, sizeof(int) * (size_t)(smooth - 1));
                history[smooth - 1] = (int)cls;
            }
            {
                int best = (int)cls, best_count = 0, k, j;
                for (k = 0; k < hist_n; ++k) {
                    int cnt = 0;
                    for (j = 0; j < hist_n; ++j) if (history[j] == history[k]) ++cnt;
                    if (cnt > best_count) { best_count = cnt; best = history[k]; }
                }
                t1 = now_s();
                if (t_prev > 0.0) fps = 1.0 / (t1 - t_prev);
                /* Save a *settled* frame.  With -n N that is the last one: by then
                 * the camera's auto-exposure and auto-white-balance have long
                 * converged.  Saving frame 3 unconditionally (the old behaviour)
                 * captured a near-black image while AEC was still ramping, which
                 * then looked like "the camera sees nothing / everything is
                 * classified as dislike".  Without -n there is no last frame, so
                 * fall back to frame 3. */
                if (save_ppm && frame_no == (max_frames > 0 ? max_frames - 1 : 3))
                    write_ppm(save_ppm, rgb96, OUT_W, OUT_H);
                printf("frame %6ld  %-16s (raw %-16s)  %d/%d votes  %6.2f fps  %5.1f ms\n",
                       frame_no, gf_npu_class_name((uint32_t)best),
                       gf_npu_class_name(cls), best_count, hist_n, fps,
                       (t1 - t0) * 1000.0);
                fflush(stdout);

                /* Hand the frame to the viewer.  This is a no-op costing two
                 * comparisons unless a browser asked for something recently,
                 * and the actual socket writes happen on the viewer's own
                 * thread -- so nothing here can slow the loop down. */
                if (view_port > 0) {
                    gf_view_frame nf;
                    nf.frame        = frame_no;
                    nf.uptime_s     = t1 - t_boot;
                    nf.fps          = fps;
                    nf.raw_class    = (int)cls;
                    nf.smooth_class = best;
                    nf.votes        = best_count;
                    nf.window       = hist_n;
                    nf.ms_total     = (t1 - t0) * 1000.0;
                    nf.ms_decode    = (t_dec - t0) * 1000.0;
                    nf.ms_resize    = (t_res - t_dec) * 1000.0;
                    nf.ms_npu       = (t_npu - t_res) * 1000.0;
                    /* rgb_frame/cw/ch are exactly what the model was shown, so
                     * the page can show the *input*, not a re-decoded guess. */
                    gf_view_publish(&nf, rgb96, rgb_frame, cw, ch);
                }
            }
            t_prev = t1;

            ++frame_no;
            if (max_frames > 0 && frame_no >= max_frames) break;
        }

        if (view_port > 0) gf_view_stop();
        v4l2_cleanup(&st);
        free(rgb_frame);
        gf_npu_close();
        printf("gf_camera: %ld frames processed\n", frame_no);
    }
    return 0;
}
