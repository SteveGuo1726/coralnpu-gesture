/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * Live HTTP viewer for the ZCU104 GestureFlow pipeline.  See gf_view.h for the
 * design rules; the short version is that the capture thread never touches a
 * socket and nothing is copied unless a client asked for it within the last
 * two seconds.
 *
 * Wire format is deliberately the dumbest thing that works:
 *   - BMP, uncompressed, because it needs no encoder at all.  The cost of the
 *     viewer must not appear in the pipeline's timing numbers, and a JPEG or
 *     PNG encoder would be 5-20 ms of CPU per frame.
 *   - The page polls <img src="/preview.bmp?t=...">  rather than using a
 *     multipart MJPEG stream, so the client decides the frame rate and a slow
 *     client cannot make the board produce more work than it asked for.
 *   - Content-Length is always set, and connections are kept alive, so the
 *     per-frame overhead is one request line and one header block.
 */
#define _GNU_SOURCE 1   /* strcasestr() on the request line */

#include "gf_view.h"
#include "gf_npu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <stdint.h>
#include <pthread.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#define GF_NCLASS            18

/* ------------------------------------------------------------- config ----- */
#define VIEW_REQ_TIMEOUT_S   2.0    /* stop copying this long after the last request */
#define VIEW_SCENE_MAX_FPS   5.0    /* the full frame is ~900 KB; cap it */
#define VIEW_MAX_REQ         2048
#define VIEW_MAX_PAGE        (1u << 20)

/* --------------------------------------------------------------- state ---- */
typedef struct {
    pthread_mutex_t lock;
    volatile int64_t last_req_us;   /* written by server threads, read by publisher.
                                     * An aligned 64-bit scalar load/store is
                                     * single-copy atomic on ARMv8-A, and the only
                                     * thing at stake is whether we do the copy. */
    double  last_pub;
    double  min_dt;                 /* 0 = no throttle */
    uint8_t *buf;
    int      w, h;
    int      have;
} gf_chan;

enum { CH_PREVIEW = 0, CH_SCENE, CH_NCH };

static gf_chan      g_ch[CH_NCH];
static int          g_run;
static int          g_listen_fd = -1;
static pthread_t    g_accept_tid;
static const char  *g_page_path;
static struct timespec g_t0;

static pthread_mutex_t g_stat_lock = PTHREAD_MUTEX_INITIALIZER;
static gf_view_frame   g_frame;
static int             g_hist_raw[GF_NCLASS];
static int             g_hist_smooth[GF_NCLASS];
static int             g_err[GF_VIEW_ERR_NCH];
static char            g_cam_fmt[24] = "?";
static int             g_cam_w, g_cam_h, g_rotate;

/* ---------------------------------------------------------------- time ---- */
static double mono_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

static int64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* ----------------------------------------------------------------- io ----- */
static int send_all(int fd, const void *p, size_t n)
{
    const uint8_t *q = (const uint8_t *)p;
    while (n > 0) {
        ssize_t r = send(fd, q, n, MSG_NOSIGNAL);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        q += r;
        n -= (size_t)r;
    }
    return 0;
}

/* Read one request header block.  Returns bytes read, 0 on orderly close,
 * -1 on error.  We only ever parse the request line, so the body (there is
 * none for GET) does not need draining. */
static int read_request(int fd, char *buf, size_t cap)
{
    size_t n = 0;
    while (n + 1 < cap) {
        ssize_t r = recv(fd, buf + n, cap - 1 - n, 0);
        if (r == 0) return n ? (int)n : 0;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        n += (size_t)r;
        buf[n] = '\0';
        if (strstr(buf, "\r\n\r\n") || strstr(buf, "\n\n")) break;
    }
    buf[cap - 1] = '\0';
    return (int)n;
}

static int send_head(int fd, const char *status, const char *ctype,
                     size_t len, int keep)
{
    char b[320];
    int n = snprintf(b, sizeof b,
                     "HTTP/1.1 %s\r\n"
                     "Content-Type: %s\r\n"
                     "Content-Length: %zu\r\n"
                     "Cache-Control: no-store, no-cache, must-revalidate\r\n"
                     "Access-Control-Allow-Origin: *\r\n"
                     "Connection: %s\r\n"
                     "\r\n",
                     status, ctype, len, keep ? "keep-alive" : "close");
    return send_all(fd, b, (size_t)n);
}

/* ---------------------------------------------------------------- BMP ----- */
static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;         p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* 24-bit BMP, bottom-up (positive biHeight) because that is what the spec
 * defines for BI_RGB and every decoder handles it.  Rows therefore go out in
 * reverse order, one write each -- 480 writes of 1920 bytes per full frame is
 * a rounding error next to the 900 KB itself, and it avoids a second full-size
 * buffer just to hold the flipped image. */
static size_t bmp_size(int w, int h)
{
    uint32_t stride = ((uint32_t)w * 3u + 3u) & ~3u;
    return 54u + (size_t)stride * (size_t)h;
}

static void bmp_header(uint8_t hd[54], int w, int h)
{
    uint32_t stride = ((uint32_t)w * 3u + 3u) & ~3u;
    uint32_t pix = stride * (uint32_t)h;
    memset(hd, 0, 54);
    hd[0] = 'B'; hd[1] = 'M';
    put32(hd +  2, 54u + pix);
    put32(hd + 10, 54u);
    put32(hd + 14, 40u);                 /* BITMAPINFOHEADER */
    put32(hd + 18, (uint32_t)w);
    put32(hd + 22, (uint32_t)h);         /* positive => rows bottom-up */
    put16(hd + 26, 1u);
    put16(hd + 28, 24u);
    put32(hd + 30, 0u);                  /* BI_RGB */
    put32(hd + 34, pix);
    put32(hd + 38, 2835u);               /* 72 dpi */
    put32(hd + 42, 2835u);
}

static const char *EXTRA_PAD = "\0\0\0";

static int send_bmp_body(int fd, const uint8_t *rgb, int w, int h)
{
    uint32_t stride = ((uint32_t)w * 3u + 3u) & ~3u;
    int row;
    for (row = h - 1; row >= 0; --row) {
        if (send_all(fd, rgb + (size_t)row * (size_t)w * 3, (size_t)w * 3) != 0) return -1;
        if (stride > (uint32_t)w * 3u) {
            if (send_all(fd, EXTRA_PAD, (size_t)(stride - (uint32_t)w * 3u)) != 0) return -1;
        }
    }
    return 0;
}

/* -------------------------------------------------------------- routing --- */
static void json_iarray(char *out, size_t cap, const int *v, int n)
{
    size_t o = 0;
    int i;
    if (cap == 0) return;
    out[0] = '\0';
    for (i = 0; i < n; ++i) {
        if (o + 8 >= cap) break;
        o += (size_t)snprintf(out + o, cap - o, "%s%d", i ? "," : "", v[i]);
    }
}

static void json_names(char *out, size_t cap)
{
    size_t o = 0;
    int i;
    out[0] = '\0';
    for (i = 0; i < GF_NCLASS; ++i) {
        if (o + 24 >= cap) break;
        o += (size_t)snprintf(out + o, cap - o, "%s\"%s\"",
                              i ? "," : "", gf_npu_class_name((uint32_t)i));
    }
}

static const char *cls_name(int c)
{
    return gf_npu_class_name((uint32_t)(c < 0 ? 0 : c));
}

static int serve_stats(int fd, int keep)
{
    char j[4096];
    char hr[160], hs[160], nm[320];
    gf_view_frame f;
    int errs[GF_VIEW_ERR_NCH];
    int hist_r[GF_NCLASS], hist_s[GF_NCLASS];
    char fmt[24];
    int w, h, rot, n;

    pthread_mutex_lock(&g_stat_lock);
    f = g_frame;
    memcpy(errs, g_err, sizeof errs);
    memcpy(hist_r, g_hist_raw, sizeof hist_r);
    memcpy(hist_s, g_hist_smooth, sizeof hist_s);
    snprintf(fmt, sizeof fmt, "%s", g_cam_fmt);
    w = g_cam_w; h = g_cam_h; rot = g_rotate;
    pthread_mutex_unlock(&g_stat_lock);

    json_iarray(hr, sizeof hr, hist_r, GF_NCLASS);
    json_iarray(hs, sizeof hs, hist_s, GF_NCLASS);
    json_names(nm, sizeof nm);

    n = snprintf(j, sizeof j,
        "{\"ok\":1,\"frame\":%ld,\"uptime\":%.1f,\"fps\":%.2f,"
        "\"raw\":%d,\"raw_name\":\"%s\",\"smooth\":%d,\"smooth_name\":\"%s\","
        "\"votes\":%d,\"window\":%d,\"rotate\":%d,"
        "\"cam\":{\"fmt\":\"%s\",\"w\":%d,\"h\":%d},"
        "\"ms\":{\"total\":%.2f,\"decode\":%.2f,\"resize\":%.2f,\"npu\":%.2f},"
        "\"hist_raw\":[%s],\"hist_smooth\":[%s],"
        "\"err\":{\"jpeg\":%d,\"npu\":%d},"
        "\"names\":[%s]}",
        f.frame, f.uptime_s, f.fps,
        f.raw_class, cls_name(f.raw_class),
        f.smooth_class, cls_name(f.smooth_class),
        f.votes, f.window, rot,
        fmt, w, h,
        f.ms_total, f.ms_decode, f.ms_resize, f.ms_npu,
        hr, hs,
        errs[GF_VIEW_ERR_JPEG], errs[GF_VIEW_ERR_NPU],
        nm);

    if (send_head(fd, "200 OK", "application/json", (size_t)n, keep) != 0) return -1;
    return send_all(fd, j, (size_t)n);
}

static int serve_bmp(int fd, int which, int keep)
{
    gf_chan *c = &g_ch[which];
    uint8_t *tmp = NULL;
    int w = 0, h = 0;

    /* Register interest first: this is what tells the capture loop to keep
     * publishing.  If this request then fails, publishing simply stops again
     * after the timeout. */
    c->last_req_us = now_us();

    pthread_mutex_lock(&c->lock);
    if (c->have && c->buf) {
        w = c->w; h = c->h;
        tmp = (uint8_t *)malloc((size_t)w * (size_t)h * 3u);
        if (tmp) memcpy(tmp, c->buf, (size_t)w * (size_t)h * 3u);
    }
    pthread_mutex_unlock(&c->lock);

    if (!tmp) {
        static const char msg[] = "no frame yet\n";
        if (send_head(fd, "503 Service Unavailable", "text/plain",
                      sizeof msg - 1u, keep) != 0) return -1;
        return send_all(fd, msg, sizeof msg - 1u);
    }

    {
        uint8_t hd[54];
        int rc;
        bmp_header(hd, w, h);
        if (send_head(fd, "200 OK", "image/bmp", bmp_size(w, h), keep) != 0) {
            free(tmp);
            return -1;
        }
        rc = send_all(fd, hd, 54);
        if (rc == 0) rc = send_bmp_body(fd, tmp, w, h);
        free(tmp);
        return rc;
    }
}

static const char FALLBACK_PAGE[] =
"<!doctype html><meta charset=utf-8><title>GestureFlow-NPU</title>\n"
"<body style=\"font:14px/1.5 system-ui;background:#12161c;color:#dfe7ef;padding:24px\">\n"
"<h2>GestureFlow-NPU 监视器</h2>\n"
"<p>页面文件不可读，这里给出原始状态：</p>\n"
"<pre id=o>loading...</pre>\n"
"<script>fetch('/stats').then(r=>r.text()).then(t=>{document.getElementById('o').textContent=t});</script>\n";

static int serve_page(int fd, int keep)
{
    char *buf = NULL;
    size_t len = 0;

    if (g_page_path) {
        FILE *f = fopen(g_page_path, "rb");
        if (f) {
            long sz;
            fseek(f, 0, SEEK_END);
            sz = ftell(f);
            fseek(f, 0, SEEK_SET);
            if (sz > 0 && (unsigned long)sz < VIEW_MAX_PAGE) {
                buf = (char *)malloc((size_t)sz);
                if (buf) {
                    if (fread(buf, 1, (size_t)sz, f) == (size_t)sz) len = (size_t)sz;
                    else { free(buf); buf = NULL; }
                }
            }
            fclose(f);
        }
    }
    if (!buf) {
        buf = (char *)FALLBACK_PAGE;
        len = sizeof FALLBACK_PAGE - 1u;
    }

    if (send_head(fd, "200 OK", "text/html; charset=utf-8", len, keep) != 0) {
        if (buf != (char *)FALLBACK_PAGE) free(buf);
        return -1;
    }
    {
        int rc = send_all(fd, buf, len);
        if (buf != (char *)FALLBACK_PAGE) free(buf);
        return rc;
    }
}

/* Returns 0 to keep the connection, -1 to close it. */
static int handle_request(int fd, char *req)
{
    char method[8], path[512];
    char *q;
    int keep = 1;
    int rc;

    method[0] = '\0';
    path[0] = '\0';
    if (sscanf(req, "%7s %511s", method, path) != 2) return -1;
    if (strcasecmp(method, "GET") != 0 && strcasecmp(method, "HEAD") != 0) {
        static const char m[] = "only GET\n";
        send_head(fd, "405 Method Not Allowed", "text/plain", sizeof m - 1u, 0);
        send_all(fd, m, sizeof m - 1u);
        return -1;
    }

    /* Strip the cache-busting query string the page appends. */
    q = strchr(path, '?');
    if (q) *q = '\0';

    if (strcasestr(req, "connection: close")) keep = 0;

    if      (!strcmp(path, "/") || !strcmp(path, "/index.html")) rc = serve_page(fd, keep);
    else if (!strcmp(path, "/stats"))                            rc = serve_stats(fd, keep);
    else if (!strcmp(path, "/preview.bmp"))                      rc = serve_bmp(fd, CH_PREVIEW, keep);
    else if (!strcmp(path, "/scene.bmp"))                        rc = serve_bmp(fd, CH_SCENE, keep);
    else if (!strcmp(path, "/favicon.ico"))
        rc = send_head(fd, "204 No Content", "image/x-icon", 0, keep);
    else {
        static const char nf[] = "not found\n";
        rc = send_head(fd, "404 Not Found", "text/plain", sizeof nf - 1u, keep);
        if (rc == 0) rc = send_all(fd, nf, sizeof nf - 1u);
    }

    if (rc != 0) return -1;
    /* Honour "Connection: close" by actually closing: announcing it in the
     * header and then waiting for another request would leave the peer (and a
     * thread here) hanging until the socket timeout. */
    return keep ? 0 : -1;
}

static void *conn_main(void *arg)
{
    int fd = (int)(intptr_t)arg;
    struct timeval tv;
    int one = 1;

    tv.tv_sec = 5; tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    for (;;) {
        char req[VIEW_MAX_REQ];
        int n = read_request(fd, req, sizeof req);
        if (n <= 0) break;
        if (handle_request(fd, req) != 0) break;
    }
    close(fd);
    return NULL;
}

static void *accept_main(void *arg)
{
    (void)arg;
    while (g_run) {
        struct sockaddr_in sa;
        socklen_t sl = sizeof sa;
        int fd = accept(g_listen_fd, (struct sockaddr *)&sa, &sl);
        if (fd < 0) {
            if (errno == EINTR) continue;
            if (!g_run) break;
            usleep(20000);
            continue;
        }
        {
            pthread_t th;
            if (pthread_create(&th, NULL, conn_main, (void *)(intptr_t)fd) != 0) {
                close(fd);
            } else {
                pthread_detach(th);
            }
        }
    }
    return NULL;
}

/* --------------------------------------------------------------- public --- */
void gf_view_set_camera(const char *fmt, int w, int h, int rotate_deg)
{
    pthread_mutex_lock(&g_stat_lock);
    snprintf(g_cam_fmt, sizeof g_cam_fmt, "%s", fmt ? fmt : "?");
    g_cam_w = w;
    g_cam_h = h;
    g_rotate = rotate_deg;
    pthread_mutex_unlock(&g_stat_lock);
}

void gf_view_count_error(int which)
{
    if (which < 0 || which >= GF_VIEW_ERR_NCH) return;
    pthread_mutex_lock(&g_stat_lock);
    ++g_err[which];
    pthread_mutex_unlock(&g_stat_lock);
}

int gf_view_parse_rotate(const char *s)
{
    int v;
    if (!s || !*s) return -1;
    if (sscanf(s, "%d", &v) != 1) return -1;
    if (v == 0 || v == 90 || v == 180 || v == 270) return v;
    return -1;
}

static void publish_chan(gf_chan *c, const uint8_t *src, int w, int h, double t)
{
    if (!src || w <= 0 || h <= 0) return;

    /* The whole point: with nobody asking, this costs one 64-bit load and two
     * comparisons.  Doing nothing here is what keeps the benchmark honest. */
    if (t - (double)c->last_req_us / 1.0e6 > VIEW_REQ_TIMEOUT_S) return;
    if (c->min_dt > 0.0 && t - c->last_pub < c->min_dt) return;

    pthread_mutex_lock(&c->lock);
    if (c->w != w || c->h != h) {
        uint8_t *nb = (uint8_t *)realloc(c->buf, (size_t)w * (size_t)h * 3u);
        if (!nb) {
            pthread_mutex_unlock(&c->lock);
            return;
        }
        c->buf = nb;
        c->w = w;
        c->h = h;
    }
    memcpy(c->buf, src, (size_t)w * (size_t)h * 3u);
    c->have = 1;
    c->last_pub = t;
    pthread_mutex_unlock(&c->lock);
}

void gf_view_publish(const gf_view_frame *f,
                     const uint8_t *rgb96,
                     const uint8_t *scene, int scene_w, int scene_h)
{
    double t;
    int i;

    if (g_listen_fd < 0) return;         /* viewer not running */

    pthread_mutex_lock(&g_stat_lock);
    g_frame = *f;
    if (f->raw_class >= 0 && f->raw_class < GF_NCLASS)       ++g_hist_raw[f->raw_class];
    if (f->smooth_class >= 0 && f->smooth_class < GF_NCLASS) ++g_hist_smooth[f->smooth_class];
    pthread_mutex_unlock(&g_stat_lock);

    t = mono_now();
    publish_chan(&g_ch[CH_PREVIEW], rgb96, 96, 96, t);
    if (scene) publish_chan(&g_ch[CH_SCENE], scene, scene_w, scene_h, t);

    (void)i;
}

static void print_urls(int port)
{
    struct ifaddrs *ifa, *p;
    int printed = 0;

    if (getifaddrs(&ifa) != 0) return;
    for (p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        {
            char ip[INET_ADDRSTRLEN];
            struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
            if (ntohl(sin->sin_addr.s_addr) == INADDR_LOOPBACK) continue;
            if (!inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof ip)) continue;
            if (!printed) {
                printf("gf_camera: viewer ready -- open this in the laptop browser:\n");
                printed = 1;
            }
            printf("gf_camera:    http://%s:%d/\n", ip, port);
        }
    }
    freeifaddrs(ifa);
    if (!printed) {
        printf("gf_camera: viewer listening on port %d, but eth0 has no IPv4 address yet.\n"
               "            Run 'ip link set eth0 up; udhcpc -i eth0' on the board.\n", port);
    }
}

int gf_view_start(int port, const char *page_path)
{
    struct sockaddr_in sa;
    int one = 1;

    if (g_listen_fd >= 0) return 0;

    g_page_path = page_path;
    clock_gettime(CLOCK_MONOTONIC, &g_t0);

    g_ch[CH_PREVIEW].min_dt = 0.0;
    g_ch[CH_SCENE].min_dt    = 1.0 / VIEW_SCENE_MAX_FPS;
    {
        int i;
        for (i = 0; i < CH_NCH; ++i) pthread_mutex_init(&g_ch[i].lock, NULL);
    }

    /* A dead client must not be able to take the whole process down. */
    signal(SIGPIPE, SIG_IGN);

    g_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_listen_fd < 0) {
        fprintf(stderr, "gf_camera: viewer: socket: %s\n", strerror(errno));
        return -1;
    }
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons((uint16_t)port);
    if (bind(g_listen_fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        fprintf(stderr, "gf_camera: viewer: bind port %d: %s\n", port, strerror(errno));
        close(g_listen_fd);
        g_listen_fd = -1;
        return -1;
    }
    if (listen(g_listen_fd, 8) != 0) {
        fprintf(stderr, "gf_camera: viewer: listen: %s\n", strerror(errno));
        close(g_listen_fd);
        g_listen_fd = -1;
        return -1;
    }

    g_run = 1;
    if (pthread_create(&g_accept_tid, NULL, accept_main, NULL) != 0) {
        fprintf(stderr, "gf_camera: viewer: pthread_create: %s\n", strerror(errno));
        g_run = 0;
        close(g_listen_fd);
        g_listen_fd = -1;
        return -1;
    }

    printf("gf_camera: viewer started on port %d (page: %s)\n",
           port, g_page_path ? g_page_path : "<built-in placeholder>");
    print_urls(port);
    return 0;
}

void gf_view_stop(void)
{
    if (g_listen_fd < 0) return;
    g_run = 0;
    shutdown(g_listen_fd, SHUT_RDWR);
    close(g_listen_fd);
    g_listen_fd = -1;
    pthread_join(g_accept_tid, NULL);
}
